## Claude-backed decision making for Bullwhip. Each seat's policy is just a
## prompt: the game server composes the seat's view (role, history table,
## this week's numbers, the neighbours' messages, notes) plus that seat's
## prompt and asks Claude what it orders (and says).
##
## Decisions within a week are simultaneous by rule, so the four requests
## go out as ONE parallel batch (curly.makeRequests); invalid replies are
## retried as a smaller batch with a hint, and anything still failing falls
## back to the scripted baseline.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT            - hosted sidecar
##   Bedrock bearer token            - local play
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, options, os, parsejson, parseutils, streams, strutils, unicode],
  bitworld/[runtime, decision_trajectory],
  curly,
  sim,
  view,
  policy

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

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
    attempts*: seq[DecisionAttempt]
    selectedAttemptId*: Option[string]

  ProposalKind* = enum
    pkAccepted, pkRejected

  Proposal* = object
    case kind*: ProposalKind
    of pkAccepted:
      decision*: Decision
    of pkRejected:
      reason*: string

  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    sidecarEndpoint: string
    bedrockEndpoint: string ## local Bedrock transport
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string         ## direct-Anthropic transport only; Bedrock
                          ## picks from bedrockModels instead
    maxOutputTokens: int
    timeoutSeconds: int
    temperature: float
    disabled*: bool   ## true once credentials are known-unavailable

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
    timeoutSeconds: config.llmTimeoutSeconds,
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "1"))
  )
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(BullwhipError, "COWORLD_LLM_TEMPERATURE must be finite and in [0, 1]")
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
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
    echo "bullwhip llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc scriptedAction*(observation: JsonNode, kind: ScriptKind): Decision =
  ## Intentional teacher and engine fallback both consume the private view.
  result.scripted = true
  result.order = if kind == skMirror: observation["seat"]["incoming"].getInt()
    else: baseStockOrder(observation)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  scriptedAction(observationJson(sim, seat), kind)

# ---- Prompt building --------------------------------------------------------

proc stageName(view: JsonNode, stage: int): string =
  view["chain"][stage].getStr() & " (" & RoleNames[stage] & ")"

proc money(value: float): string =
  formatFloat(value, ffDecimal, 1)

proc historyTable(view: JsonNode): string =
  var lines: seq[string]
  lines.add("week | incoming order | arrived | shipped | inventory | " &
    "backlog | week cost | YOUR ORDER")
  let history = view["history"]
  for index in 0 ..< history.len:
    let state = history[index]
    let order =
      if state["order"].getInt() >= 0: $state["order"].getInt()
      elif index == history.len - 1: "(this week: decide now)"
      else: "-"
    lines.add($index & " | " & $state["incoming"].getInt() & " | " &
      $state["received"].getInt() & " | " & $state["shipped"].getInt() & " | " &
      $state["inventory"].getInt() & " | " & $state["backlog"].getInt() & " | " &
      money(state["costWeek"].getFloat()) & " | " & order)
  lines.join("\n")

proc systemPrompt*(view: JsonNode): string =
  let me = view["name"].getStr()
  let stage = view["stage"].getInt()
  let downstream =
    if stage == 0: "the CUSTOMERS (their demand is your incoming order)"
    else: view.stageName(stage - 1)
  let upstream =
    if stage == Stages - 1: "your own PRODUCTION LINE (an order is a " &
      "production request; it lands in your inventory 2 weeks later)"
    else: view.stageName(stage + 1)
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
    (if view["talk"].getBool(): "\n- You may SAY one short message (max " &
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

proc heardBlock(view: JsonNode): string =
  if not view["talk"].getBool(): return ""
  var lines: seq[string]
  for heard in view["heard"]:
    lines.add(view.stageName(heard["stage"].getInt()) & " said: \"" &
      heard["message"].getStr() & "\"")
  result = "MESSAGES FROM YOUR NEIGHBOURS LAST WEEK:\n" &
    (if lines.len > 0: lines.join("\n") else: "(none)") & "\n\n"

proc userPrompt*(view: JsonNode, prompt: string, retry = false): string =
  let stage = view["stage"].getInt()
  let state = view["seat"]
  result.add("Week " & $view["week"].getInt() & " of " & $view["weeks"].getInt() &
    ". You are the " & RoleNames[stage].toUpperAscii() & ".\n\n")
  result.add("THIS WEEK: incoming order " & $state["incoming"].getInt() &
    ", arrived " & $state["received"].getInt() & ", shipped " & $state["shipped"].getInt() &
    ", inventory " & $state["inventory"].getInt() & ", backlog " & $state["backlog"].getInt() &
    ", cost so far $" & money(state["costTotal"].getFloat()) & ".\n\n")
  result.add("YOUR HISTORY:\n" & view.historyTable() & "\n\n")
  result.add(view.heardBlock())
  result.add("YOUR NOTES FROM EARLIER WEEKS:\n" &
    (if view["notes"].getStr().len > 0: view["notes"].getStr() else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"order\": 8" &
    (if view["talk"].getBool(): ", \"say\": \"…\"" else: "") &
    ", \"notes\": \"…\"} — order is a whole number of units, 0 to " &
    $MaxOrder & (if view["talk"].getBool(): "; say at most " & $MaxSayLen &
      " characters (or \"\")" else: "") &
    "; notes at most " & $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

  if retry:
    result.add("\nYour previous reply was invalid. Respond with ONLY " &
      "the requested JSON object, with \"order\" a whole number 0.." &
      $MaxOrder & ".")

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": client.temperature,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
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

proc decisionJson*(decision: Decision): JsonNode =
  %*{"order": decision.order, "say": decision.say, "notes": decision.notes}

proc parseProposal*(text: string, observation: JsonNode): Proposal =
  ## Domain validation returns a typed result; unexpected failures still crash.
  let first = text.find('{')
  let last = text.rfind('}')
  if first < 0 or last <= first:
    return Proposal(kind: pkRejected, reason: "no JSON object in response")
  let body = text[first .. last]
  var parser: JsonParser
  parser.open(newStringStream(body), "player response")
  defer: parser.close()
  while true:
    parser.next()
    if parser.kind == jsonError:
      return Proposal(kind: pkRejected, reason: parser.errorMsg())
    if parser.kind == jsonEof: break
  let payload = parseJson(body)
  if payload.kind != JObject or not payload.hasKey("order"):
    return Proposal(kind: pkRejected, reason: "no order in response")
  let node = payload["order"]
  var number: float
  case node.kind
  of JInt: number = float(node.getBiggestInt())
  of JFloat: number = node.getFloat()
  of JString:
    let value = node.getStr().strip()
    if parseutils.parseFloat(value, number) != value.len or value.len == 0:
      return Proposal(kind: pkRejected, reason: "order is not a number")
  else:
    return Proposal(kind: pkRejected, reason: "order must be a number")
  if number.classify in {fcNan, fcInf, fcNegInf} or round(number) < 0 or round(number) > MaxOrder.float:
    return Proposal(kind: pkRejected, reason: "order outside allowed bounds")
  var decision = Decision(order: int(round(number)),
    notes: cleanText(payload{"notes"}.getStr(), MaxNotesLen),
    say: cleanText(payload{"say"}.getStr(), MaxSayLen).replace("\n", " "))
  if not observation["talk"].getBool(): decision.say = ""
  Proposal(kind: pkAccepted, decision: decision)

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the scripted baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skBasestock else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    var started: seq[DecisionAttempt]
    for index in open:
      let seat = seats[index]
      let observation = observationJson(sim, seat)
      let user = userPrompt(observation, prompts[seat], retry = attempt > 0)
      let request = client.requestFor(systemPrompt(observation), user, seat)
      var evidence = newDecisionAttempt($sim.week & "-" & $seat & "-" & $attempt,
        "prompt", aoModel)
      evidence.prompt = %*[{"role": "system", "content": systemPrompt(observation)},
        {"role": "user", "content": user}]
      evidence.request = parseJson(request.body)
      evidence.model = some(if client.transport == ltBedrock:
        client.bedrockModels[client.bedrockModel] else: client.model)
      evidence.decoder = %*{"temperature": client.temperature, "max_tokens": client.maxOutputTokens}
      started.add(evidence)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      var evidence = started[position]
      let response = responses[position].response
      evidence.rawResponse = %response.body
      if response.headers.contains("X-Softmax-Llm-Call-Id"):
        evidence.platformCallId = some(response.headers["X-Softmax-Llm-Call-Id"])
      for header in ["X-Coworld-Checkpoint-Sha256", "X-Coworld-Tokenizer-Sha256",
          "X-Coworld-Chat-Template-Sha256"]:
        if response.headers.contains(header):
          case header
          of "X-Coworld-Checkpoint-Sha256": evidence.modelIdentity = some(response.headers[header])
          of "X-Coworld-Tokenizer-Sha256": evidence.tokenizerIdentity = some(response.headers[header])
          else: evidence.chatTemplateSha256 = some(response.headers[header])
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        evidence.response = %text
        let payload = parseJson(response.body)
        if payload.hasKey("model"): evidence.model = some(payload["model"].getStr())
        evidence.stopReason = some(payload["stop_reason"].getStr())
        if payload.hasKey("usage"):
          evidence.inputTokens = some(payload["usage"]["input_tokens"].getInt())
          evidence.outputTokens = some(payload["usage"]["output_tokens"].getInt())
        if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
          let sampling = payload["sampling_evidence"]
          var promptIds, sampledIds: seq[int]
          var probabilities: seq[float]
          for token in sampling["prompt_token_ids"]: promptIds.add(token.getInt())
          for token in sampling["completion_token_ids"]: sampledIds.add(token.getInt())
          evidence.promptTokenIds = some(promptIds)
          evidence.sampledTokenIds = some(sampledIds)
          if sampling["behavior_log_probs"].kind != JNull:
            for probability in sampling["behavior_log_probs"]: probabilities.add(probability.getFloat())
            evidence.behaviorLogprobs = some(probabilities)
          evidence.stopReason = some(sampling["stop_reason"].getStr())
          evidence.decoder["sampling_evidence"] = copy(sampling)
        let proposal = parseProposal(text, observationJson(sim, seat))
        if proposal.kind == pkRejected:
          raise newException(BullwhipError, proposal.reason)
        var decision = proposal.decision
        ## Reject illegal replies here so the retry carries the hint.
        var probe = sim
        probe.applyOrder(seat, decision.order, decision.say, decision.notes,
          false)
        evidence.accepted = true
        evidence.parsedAction = decisionJson(decision)
        decision.attempts = result[index].attempts & @[evidence]
        decision.selectedAttemptId = some(evidence.attemptId)
        result[index] = decision
      except CatchableError as error:
        evidence.rejectionReason = some(error.msg)
        result[index].attempts.add(evidence)
        echo "bullwhip llm: seat ", seat, " attempt ", attempt, " failed"
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "bullwhip llm: seat ", seat, " falling back to scripted decision"
    let attempts = result[index].attempts
    result[index] = scriptedAction(sim, seat, skBasestock)
    result[index].attempts = attempts
