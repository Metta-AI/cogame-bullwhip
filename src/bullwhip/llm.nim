## Server-side decision making for Bullwhip. Prompt policies ask Claude for
## an order and message; Jev policies rank legal order quantities with
## System One. Scripted policies use deterministic baselines.
##
## Decisions within a week are simultaneous by rule, so the four requests
## go out as ONE parallel batch (curly.makeRequests); invalid replies are
## retried as a smaller batch with a hint, and anything still failing falls
## back to the scripted baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## A seat with no usable model transport falls back to the always-legal
## scripted baseline immediately, so offline certification completes. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## The private notebook a seat may carry between weeks.
  MaxNotesLen* = 600

type
  ScriptKind* = enum
    skNone = "none"
    skBasestock = "basestock"
    skMirror = "mirror"

  Decision* = object
    order*: int
    say*: string
    notes*: string      ## "" when the reply carried none
    scripted*: bool

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string         ## direct-Anthropic transport only; Bedrock
                          ## picks from bedrockModels instead
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable
    jevEndpoint: string
    jevKey: string
    jevModel: string
    jevTrajectoryId: string

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"basestock" play the
  ## base-stock bot, "mirror" the pass-through bot, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "basestock", "base-stock": skBasestock
  of "mirror", "passthrough", "pass-through": skMirror
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "bullwhip llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. The config "model" field is NOT
  ## consulted here: it applies to the direct-Anthropic transport
  ## only, and the haiku-first ordering below is a shared-capacity
  ## decision that trumps per-game preference.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "bullwhip llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  let captureUrl = getEnv("METTA_CAPTURE_URL").strip()
  let typesafeKey = getEnv("TYPESAFE_API_KEY").strip()
  if bedrockEndpoint.len > 0:
    result.jevEndpoint = bedrockEndpoint.strip(chars = {'/'}, leading = false)
    result.jevModel = "typesafe/jev-1.13"
  elif captureUrl.len > 0:
    result.jevEndpoint = captureUrl.strip(chars = {'/'}, leading = false)
    result.jevKey = getEnv("METTA_CAPTURE_KEY").strip()
    if result.jevKey.len == 0:
      raise newException(BullwhipError, "METTA_CAPTURE_KEY is required")
    result.jevModel = "typesafe/jev-1.13"
    result.jevTrajectoryId = "bullwhip-jev-" & $config.seed
  elif typesafeKey.len > 0:
    result.jevEndpoint = getEnv("TYPESAFE_BASE_URL",
      "https://api.typesafe.ai").strip(chars = {'/'}, leading = false)
    result.jevKey = typesafeKey
    result.jevModel = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "bullwhip llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "bullwhip llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    if result.jevEndpoint.len > 0:
      result.curl = newCurly()
    echo "bullwhip llm: no Claude credentials; prompt seats use scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

const
  ForecastSmoothing = 0.1
  CoverWeeks = 3.0   ## desired inventory and supply line, in weeks of demand
  InventoryGain = 0.1 ## share of the inventory gap closed per week
  SupplyGain = 1.0    ## share of the supply-line gap closed per week
  InitialOnOrder = 2 * BaseDemand  ## the primed shipping pipeline

proc forecast*(sim: Sim, stage: int): float =
  ## Exponentially smoothed incoming orders over the stage's whole
  ## history, from a BaseDemand prior. Stateless so a fallback decision
  ## for an LLM seat is as good as a scripted seat's. Slow on purpose:
  ## a chain of four fast forecasters was measured to amplify a single
  ## demand step into orders of 150+ (tmp/tune.nim); at 0.1 the peak is
  ## ~60 and the chain cost about a quarter of that.
  result = BaseDemand.float
  for record in sim.history:
    result = ForecastSmoothing * record.stages[stage].incoming.float +
      (1.0 - ForecastSmoothing) * result

proc onOrder*(sim: Sim, stage: int): int =
  ## Everything ordered and not yet arrived — the shipping pipeline AND
  ## whatever the supplier still owes. Counting only the visible pipeline
  ## (the human mistake Sterman documents) is where the bullwhip comes
  ## from.
  result = InitialOnOrder
  for index, record in sim.history:
    if record.orders[stage] >= 0:
      result += record.orders[stage]
    if index > 0:
      result -= record.stages[stage].received

proc basestockOrder*(sim: Sim, stage: int): int =
  ## Sterman's anchor-and-adjust: forecast, close a little of the
  ## inventory gap, and close the whole supply-line gap.
  let state = sim.stages[stage]
  let demand = forecast(sim, stage)
  let desiredInventory = CoverWeeks * demand
  let desiredSupply = CoverWeeks * demand
  let order = demand +
    InventoryGain * (desiredInventory - state.inventory.float +
      state.backlog.float) +
    SupplyGain * (desiredSupply - onOrder(sim, stage).float)
  max(0, min(MaxOrder, int(round(order))))

proc mirrorOrder*(sim: Sim, stage: int): int =
  max(0, min(MaxOrder, sim.stages[stage].incoming))

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`. Always legal; never talks or notes.
  result.scripted = true
  let stage = sim.roleOf[seat]
  case kind
  of skMirror: result.order = mirrorOrder(sim, stage)
  else: result.order = basestockOrder(sim, stage)

# ---- Prompt building --------------------------------------------------------

proc seatName(sim: Sim, seat: int): string =
  sim.names[seat]

proc stageName(sim: Sim, stage: int): string =
  ## "Gizmo (Wholesaler)".
  sim.seatName(sim.seatOf[stage]) & " (" & RoleNames[stage] & ")"

proc money(value: float): string =
  formatFloat(value, ffDecimal, 1)

proc historyTable(sim: Sim, stage: int): string =
  ## Every observed week of this stage, oldest first.
  var lines: seq[string]
  lines.add("week | incoming order | arrived | shipped | inventory | " &
    "backlog | week cost | YOUR ORDER")
  for index, record in sim.history:
    let s = record.stages[stage]
    let order =
      if record.orders[stage] >= 0: $record.orders[stage]
      elif index == sim.history.high: "(this week: decide now)"
      else: "-"
    lines.add($index & " | " & $s.incoming & " | " & $s.received & " | " &
      $s.shipped & " | " & $s.inventory & " | " & $s.backlog & " | " &
      money(s.costWeek) & " | " & order)
  lines.join("\n")

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.seatName(seat)
  let stage = sim.roleOf[seat]
  let downstream =
    if stage == 0: "the CUSTOMERS (their demand is your incoming order)"
    else: sim.stageName(stage - 1)
  let upstream =
    if stage == Stages - 1: "your own PRODUCTION LINE (an order is a " &
      "production request; it lands in your inventory 2 weeks later)"
    else: sim.stageName(stage + 1)
  "You are " & me & ", the " & RoleNames[stage].toUpperAscii() &
    " in a four-stage beer supply chain: Retailer <- Wholesaler <- " &
    "Distributor <- Factory. Each stage is run by a different cog." &
    """

Rules:
- Every week you receive an order from downstream, ship what you can from
  inventory (unfilled units become BACKLOG, owed until shipped), then place
  ONE order upstream.
- Delays: an order you place is seen upstream NEXT week; a shipment takes 2
  weeks to reach you after it is shipped. So what you order this week
  arrives in 3 weeks at the earliest, later if your supplier is backlogged.
- Costs, charged every week: $0.5 per unit of inventory you hold and
  $1.0 per unit of backlog. Your SCORE is minus your total cost. Lower
  cost wins. Nothing else scores.
- You see only your own numbers. You never see other stages' inventories,
  the demand the customers actually have, or what is in the pipeline
  except by remembering what you ordered.
- Customer demand is hidden and roughly steady, but it may change level
  during the game. Over-ordering into a backlog creates a wave that comes
  back as your own excess inventory weeks later (the bullwhip effect).
""" & "- Downstream of you: " & downstream & ". Upstream of you: " &
    upstream & "." &
    (if sim.config.talk: "\n- You may SAY one short message (max " &
      $MaxSayLen & " chars) each week; only your two neighbours read it, " &
      "next week. It is not binding and may or may not be honest."
     else: "") &
    """

- Your notes are private to you and fed back to you every week. Use them
  to keep track of what you have on order and what you believe demand is.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after
the object. Your reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc heardBlock(sim: Sim, stage: int): string =
  if not sim.config.talk:
    return ""
  var lines: seq[string]
  for other in neighbours(stage):
    if sim.heard[other].len > 0:
      lines.add(sim.stageName(other) & " said: \"" & sim.heard[other] & "\"")
  result = "MESSAGES FROM YOUR NEIGHBOURS LAST WEEK:\n" &
    (if lines.len > 0: lines.join("\n") else: "(none)") & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let stage = sim.roleOf[seat]
  let state = sim.stages[stage]
  result.add("Week " & $sim.week & " of " & $sim.config.weeks &
    ". You are the " & RoleNames[stage].toUpperAscii() & ".\n\n")
  result.add("THIS WEEK: incoming order " & $state.incoming &
    ", arrived " & $state.received & ", shipped " & $state.shipped &
    ", inventory " & $state.inventory & ", backlog " & $state.backlog &
    ", cost so far $" & money(state.costTotal) & ".\n\n")
  result.add("YOUR HISTORY:\n" & sim.historyTable(stage) & "\n\n")
  result.add(sim.heardBlock(stage))
  result.add("YOUR NOTES FROM EARLIER WEEKS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"order\": 8" &
    (if sim.config.talk: ", \"say\": \"…\"" else: "") &
    ", \"notes\": \"…\"} — order is a whole number of units, 0 to " &
    $MaxOrder & (if sim.config.talk: "; say at most " & $MaxSayLen &
      " characters (or \"\")" else: "") &
    "; notes at most " & $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model
    ## sent instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(BullwhipError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a BullwhipError describing why
  ## there is none. Auth failures disable the client; model-access and
  ## throttle failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(BullwhipError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(BullwhipError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(BullwhipError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(BullwhipError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(BullwhipError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(BullwhipError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(BullwhipError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a rune boundary with the cut marked.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc parseDecision*(payload: JsonNode): Decision =
  ## "order" is an integer, a numeric string, or a float (rounded).
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen)
    .replace("\n", " ")
  let node = payload{"order"}
  if node.isNil:
    raise newException(BullwhipError, "no order in response")
  var order = -1
  case node.kind
  of JInt:
    order = node.getInt()
  of JFloat:
    order = int(round(node.getFloat()))
  of JString:
    let text = node.getStr().strip()
    try:
      order = int(round(parseFloat(text)))
    except ValueError:
      raise newException(BullwhipError, "order is not a number: " & text)
  else:
    raise newException(BullwhipError, "order must be a number: " & $node)
  if order < 0 or order > MaxOrder:
    raise newException(BullwhipError,
      "order must be 0.." & $MaxOrder & ": " & $order)
  result.order = order

proc jevCriteria*(sim: Sim, seat: int): JsonNode =
  ## System One chooses among legal order quantities near the base-stock
  ## estimate, plus the current incoming demand and the no-order option.
  result = newJObject()
  let stage = sim.roleOf[seat]
  let base = scriptedAction(sim, seat, skBasestock).order
  for proposal in [0, sim.stages[stage].incoming, base - 8, base - 4,
      base - 2, base, base + 2, base + 4, base + 8]:
    let order = max(0, min(MaxOrder, proposal))
    result[$order] = %("Order " & $order & " units upstream this week")

proc jevDecision*(payload, criteria: JsonNode): Decision =
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  let reported = answer["choice"].getStr()
  if answer["type"].getStr() != "choice" or
      not criteria.hasKey(reported) or probabilities.len != criteria.len:
    raise newException(BullwhipError, "Jev returned the wrong choice set")
  let confidence = answer["confidence"].getFloat()
  if confidence < 0 or confidence > 1:
    raise newException(BullwhipError, "Jev confidence is outside [0, 1]")
  var total = 0.0
  var best = -1.0
  var choice = ""
  for name, probability in probabilities.pairs:
    if not criteria.hasKey(name):
      raise newException(BullwhipError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(BullwhipError, "Jev probability is outside [0, 1]")
    total += value
    if value > best:
      best = value
      choice = name
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(BullwhipError, "Jev probabilities do not sum to one")
  result.order = parseInt(choice)
  echo "bullwhip jev: order ", choice, " reported ", reported,
    " confidence ", confidence, " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  jev: seq[bool]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the scripted baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or (client.disabled and not jev[seat]) or
        (jev[seat] and client.jevEndpoint.len == 0):
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skBasestock else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if client.disabled:
      var enabled: seq[int]
      for index in open:
        if jev[seats[index]]:
          enabled.add(index)
        else:
          result[index] = scriptedAction(sim, seats[index], skBasestock)
      open = enabled
    if open.len == 0:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      if jev[seat]:
        var headers: HttpHeaders
        headers["content-type"] = "application/json"
        if client.jevKey.len > 0:
          headers["authorization"] = "Bearer " & client.jevKey
        else:
          headers["x-coworld-player-slot"] = $seat
        if client.jevTrajectoryId.len > 0:
          headers["x-metta-trajectory-id"] =
            client.jevTrajectoryId & "-" & $seat
        let body = %*{
          "model": client.jevModel,
          "state": sim.systemPrompt(seat) & "\n\n" &
            sim.userPrompt(seat, prompts[seat]),
          "questions": {"decision": {
            "type": "choice",
            "instructions": "Choose the order that minimizes your holding and backlog costs across the remaining weeks. Account for the delayed supply line and the other stages' orders.",
            "criteria": sim.jevCriteria(seat)
          }}
        }
        batch.post(client.jevEndpoint & "/v1/systemone", headers, $body,
          $index)
      else:
        var user = sim.userPrompt(seat, prompts[seat])
        if attempt > 0:
          user.add("\nYour previous reply was invalid. Respond with ONLY " &
            "the requested JSON object, with \"order\" a whole number 0.." &
            $MaxOrder & ".")
        let request = client.requestFor(systemPrompt(sim, seat), user)
        batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        var decision: Decision
        if jev[seat]:
          let response = responses[position].response
          let error = responses[position].error
          if error.len > 0 or response.code < 200 or response.code >= 300:
            raise newException(BullwhipError, "Jev transport failed: " &
              error & " HTTP " & $response.code)
          decision = jevDecision(parseJson(response.body),
            sim.jevCriteria(seat))
        else:
          let text = client.textOf(responses[position].response,
            responses[position].error, batch[position].url)
          decision = parseDecision(extractJsonObject(text))
        ## Reject illegal replies here so the retry carries the hint.
        var probe = sim
        probe.applyOrder(seat, decision.order, decision.say, decision.notes,
          false)
        result[index] = decision
      except CatchableError as error:
        echo "bullwhip llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "bullwhip llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skBasestock)
