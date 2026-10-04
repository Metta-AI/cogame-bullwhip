## Claude-backed decision making for Bullwhip. Each seat's policy is just a
## prompt: the game server composes the seat's view (role, history table,
## this week's numbers, the neighbours' messages, notes) plus that seat's
## prompt and asks Claude what it orders (and says).
##
## Simultaneous native requests share one absolute phase deadline. Provider
## credentials and direct provider transports are not part of this runtime.

import
  std/[base64, json, math, monotimes, options, os, parsejson, parseutils, sets, streams, strutils, tables, unicode],
  bitworld/[decision_trajectory, native_http, native_stop],
  native_batch,
  sim,
  view,
  policy

const
  AnthropicVersion = "2023-06-01"

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

  LlmClient* = ref object
    sidecarEndpoint: string
    model: string
    maxOutputTokens: int
    temperature: float
    disabled*: bool

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"basestock" play the
  ## base-stock bot, "mirror" the pass-through bot, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "basestock", "base-stock": skBasestock
  of "mirror", "passthrough", "pass-through": skMirror
  else: skNone

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    sidecarEndpoint: getEnv("COWORLD_LLM_ENDPOINT").strip().strip(chars = {'/'}, leading = false),
    maxOutputTokens: config.maxOutputTokens,
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "1")))
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(BullwhipError, "COWORLD_LLM_TEMPERATURE must be finite and in [0, 1]")
  if result.model.len == 0 or result.maxOutputTokens <= 0:
    raise newException(BullwhipError, "native model and positive token budget are required")
  result.disabled = result.sidecarEndpoint.len == 0

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

# ---- Native transport -------------------------------------------------------

  if retry:
    result.add("\nYour previous reply was invalid. Respond with ONLY " &
      "the requested JSON object, with \"order\" a whole number 0.." &
      $MaxOrder & ".")

proc requestFor(client: LlmClient, system, user: string, slot: int): NativeRequest =
  if slot notin 0 ..< Seats:
    raise newException(BullwhipError, "native seat is outside the game")
  result.headers["content-type"] = "application/json"
  result.headers["anthropic-version"] = AnthropicVersion
  result.headers["X-Coworld-Player-Slot"] = $slot
  result.url = client.sidecarEndpoint & "/v1/messages"
  result.body = $(%*{"model": client.model, "max_tokens": client.maxOutputTokens,
    "temperature": client.temperature, "system": system,
    "messages": [{"role": "user", "content": user}]})

proc textOf(client: LlmClient, response: NativeHttpResponse,
    evidence: var DecisionAttempt): string =
  evidence.latencyMs = response.latencyMs
  evidence.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    evidence.responseBodyB64 = some(encode(response.bodyBytes))
    evidence.responseHeadersB64 = some(encode(response.headerBytes))
    evidence.responseComplete = some(response.transferComplete)
    evidence.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      evidence.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(BullwhipError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(BullwhipError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(BullwhipError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    evidence.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(BullwhipError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      evidence.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call":
        let identity = responseHeaders[header]
        if identity.len != 36:
          raise newException(BullwhipError, "received platform call identity is not a UUID")
        for index, character in identity:
          if index in [8, 13, 18, 23]:
            if character != '-':
              raise newException(BullwhipError, "received platform call identity is not a UUID")
          elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            raise newException(BullwhipError, "received platform call identity is not a UUID")
        evidence.platformCallId = some(identity)
      of "model": evidence.modelIdentity = some(responseHeaders[header])
      of "tokenizer": evidence.tokenizerIdentity = some(responseHeaders[header])
      else: evidence.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(BullwhipError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(BullwhipError, "native inference auth failed (" & $status & ")")
  if status == 429:
    raise newException(BullwhipError, "native inference throttled (429)")
  if status < 200 or status >= 300:
    raise newException(BullwhipError, "native inference error " & $status)
  let payload = parseJson(response.bodyBytes)
  if payload.kind != JObject or payload["model"].kind != JString or
      payload["content"].kind != JArray:
    raise newException(BullwhipError, "native response violates the completion schema")
  evidence.model = some(payload["model"].getStr())
  case payload["stop_reason"].kind
  of JString: evidence.stopReason = some(payload["stop_reason"].getStr())
  of JNull: discard
  else: raise newException(BullwhipError, "native stop reason must be text or null")
  if payload.hasKey("usage") and payload["usage"].kind != JNull:
    let usage = payload["usage"]
    if usage.kind != JObject or usage["input_tokens"].kind != JInt or
        usage["output_tokens"].kind != JInt or usage["input_tokens"].getInt() < 0 or
        usage["output_tokens"].getInt() < 0:
      raise newException(BullwhipError, "native usage must contain nonnegative integer counts")
    evidence.inputTokens = some(usage["input_tokens"].getInt())
    evidence.outputTokens = some(usage["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    if sampling.kind != JObject or sampling["prompt_token_ids"].kind != JArray or
        sampling["completion_token_ids"].kind != JArray or sampling["stop_reason"].kind != JString:
      raise newException(BullwhipError, "native sampling evidence violates the token schema")
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(BullwhipError, "native prompt token IDs must be nonnegative integers")
      promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(BullwhipError, "native sampled token IDs must be nonnegative integers")
      sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      if sampling["behavior_log_probs"].kind != JArray:
        raise newException(BullwhipError, "native draw probabilities must be an array or null")
      for probability in sampling["behavior_log_probs"]:
        if probability.kind notin {JInt, JFloat} or
            classify(probability.getFloat()) in {fcNan, fcInf, fcNegInf} or probability.getFloat() > 0:
          raise newException(BullwhipError, "native draw probabilities must be finite nonpositive numbers")
        probabilities.add(probability.getFloat())
      if probabilities.len != sampledIds.len:
        raise newException(BullwhipError, "native draw probabilities must match sampled token IDs")
    evidence.promptTokenIds = some(promptIds)
    evidence.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      evidence.behaviorLogprobs = some(probabilities)
    evidence.stopReason = some(sampling["stop_reason"].getStr())
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(BullwhipError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
      raise newException(BullwhipError, "native content block violates the completion schema")
    if contentBlock["type"].getStr() == "text":
      if contentBlock["text"].kind != JString:
        raise newException(BullwhipError, "native text content must be text")
      result.add(contentBlock["text"].getStr())
  evidence.response = %result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(BullwhipError, "native reply ended before a JSON action")

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

proc decideAll*(client: LlmClient, sim: Sim, seats: seq[int],
    prompts: seq[string], scripted: seq[ScriptKind], deadline: MonoTime,
    beforeCall: proc(slot: int, attempt: DecisionAttempt) {.closure, gcsafe.}): seq[Decision] =
  ## Every seat starts before any response is awaited. Repairs use remaining time.
  result = newSeq[Decision](seats.len)
  var open: seq[int]
  for index, seat in seats:
    if scripted[seat] != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if scripted[seat] == skNone: skBasestock else: scripted[seat]))
    else: open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled or interruptionRequested() or getMonoTime() >= deadline:
      break
    var batch: seq[NativeRequest]
    var started: seq[DecisionAttempt]
    for index in open:
      let seat = seats[index]
      let observation = observationJson(sim, seat)
      let system = systemPrompt(observation)
      let user = userPrompt(observation, prompts[seat], retry = attempt > 0)
      let request = client.requestFor(system, user, seat)
      var evidence = newDecisionAttempt($sim.week & "-" & $seat & "-" & $attempt,
        "prompt", aoModel)
      evidence.prompt = %*[{"role": "system", "content": system},
        {"role": "user", "content": user}]
      evidence.request = parseJson(request.body)
      evidence.model = some(client.model)
      evidence.decoder = %*{"temperature": client.temperature, "max_tokens": client.maxOutputTokens}
      beforeCall(seat, evidence)
      started.add(evidence)
      batch.add(request)
    let responses = performNativeBatch(batch, deadline)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      var evidence = started[position]
      try:
        let text = client.textOf(responses[position].response, evidence)
        let proposal = parseProposal(text, observationJson(sim, seat))
        if proposal.kind == pkRejected:
          raise newException(BullwhipError, proposal.reason)
        var decision = proposal.decision
        evidence.parsedAction = decisionJson(decision)
        if interruptionRequested() or responses[position].receivedAt >= deadline:
          raise newException(BullwhipError, "native receipt outside the decision window")
        var probe = sim
        probe.applyOrder(seat, decision.order, decision.say, decision.notes, false)
        evidence.accepted = true
        decision.attempts = result[index].attempts & @[evidence]
        decision.selectedAttemptId = some(evidence.attemptId)
        result[index] = decision
      except CatchableError as error:
        evidence.rejectionReason = some(error.msg)
        result[index].attempts.add(evidence)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let attempts = result[index].attempts
    result[index] = scriptedAction(sim, seats[index], skBasestock)
    result[index].attempts = attempts
