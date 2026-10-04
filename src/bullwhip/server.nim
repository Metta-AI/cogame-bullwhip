## Bullwhip game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player observation/action protocol
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol bullwhip.player.v3: one frozen prompt/scripted registration,
## or external control with canonical private decision/messages and opaque IDs.
## Model starts precede HTTP response facts; actions bind complete joined bytes
## to the ordinary order parser. Stop carries an engine-issued nonce; external
## owners wait for matching evidence_received before exiting. Unresolved joins
## produce a private truncated episode without public results or replay.

import
  std/[base64, json, locks, math, monotimes, options, os, sets, strutils, sysrand, tables, times, unicode],
  bitworld/[runtime, decision_trajectory, artifact_runtime, native_stop],
  mummy,
  mummy/routers,
  llm,
  sim,
  view

export view

const
  MaxPromptLen = 4000
  ReplayVersion = 1

type
  PendingDecision = object
    id, seat: string
    observation: JsonNode
    decision: Decision
    terminal: bool
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    external: seq[bool]
    ready: seq[bool]
    awaiting: seq[bool]
    actions: seq[JsonNode]
    externalAttempts: seq[seq[DecisionAttempt]]
    nativeAttempts: seq[seq[DecisionAttempt]]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    stopping: bool
    finished: bool
    records: seq[PendingDecision]
    currentObservations: seq[JsonNode]
    currentWeek: int
    decisionCounter: int
    phaseDeadline: MonoTime
    issuedSeats: Table[string, int]
    issuedAt: Table[string, MonoTime]
    issuedObservations, issuedPrompts: Table[string, JsonNode]
    latestDecisions: Table[int, string]
    startedAttempts, completedAttempts: Table[string, JsonNode]
    externalRejections: seq[int]
    externalFallback: seq[bool]
    stopId: string
    stopIssuedAt, acknowledgementDeadline: MonoTime
    stoppedSlots: HashSet[int]
    trajectory: DecisionTrajectory

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc publicEventJson*(event: GameEvent): JsonNode =
  ## Notebooks belong to private decisions, including when saved in engine events.
  var publicEvent = event
  if publicEvent.kind == evOrder: publicEvent.text = ""
  publicEvent.eventToJson()

proc publicTableJson*(sim: Sim): JsonNode =
  result = sim.tableStateJson()
  for seat in result["seats"]: seat.delete("notes")

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(publicEventJson(event))
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.publicTableJson()
  result["type"] = %"state"
  result["game"] = %"bullwhip"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## The chain has hidden information (other stages' numbers, the demand
  ## script, pipeline contents), so a player sees only its own stage's
  ## numbers, the week counter, and whether the episode is done.
  let stage = gs.sim.roleOf[slot]
  var seat = stageJson(gs.sim.stages[stage])
  seat["role"] = %RoleNames[stage]
  seat["score"] = %gs.sim.score(slot)
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "seat": seat,
    "week": gs.sim.week,
    "weeks": gs.config.weeks,
    "weeksPlayed": gs.sim.weeksPlayed,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get
  ## the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string,
    cleanupDeadline: MonoTime) =
  if uri.len == 0: return
  let httpMethod = case getEnv(methodEnv, "PUT").toUpperAscii()
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(ValueError, "unsupported artifact method")
  writeCogameArtifact(uri, data, contentType, methodEnv, cleanupDeadline, httpMethod)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(publicEventJson(event))
  $ %*{
    "protocol": "bullwhip.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "weeks": gs.config.weeks,
      "seed": gs.config.seed,
      "talk": gs.config.talk,
      "sampled": true
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.publicTableJson())

proc retainExternalAttempt(gs: var GameState, seat: int, id: string,
    evidence: JsonNode, completed: bool) =
  if not gs.issuedSeats.hasKey(id) or gs.issuedSeats[id] != seat:
    raise newException(BullwhipError, "attempt does not belong to authenticated issued seat")
  let attempt = readAttemptEvidence(evidence)
  if attempt.attemptId != id & "-model" or attempt.origin != aoModel:
    raise newException(BullwhipError, "external attempt must identify its issued model call")
  let prompt = gs.issuedPrompts[id]
  if attempt.prompt != prompt or attempt.request.kind != JObject or
      attempt.request["system"] != prompt[0]["content"] or
      attempt.request["messages"] != %*[prompt[1]]:
    raise newException(BullwhipError, "model call rewrites the exact private prompt")
  if not gs.startedAttempts.hasKey(id):
    if completed:
      raise newException(BullwhipError, "completed model evidence lacks pre-request start")
    if attempt.response.kind != JNull or attempt.rawResponse.kind != JNull or
        attempt.platformCallId.isSome or attempt.providerRequestId.isSome or
        attempt.responseHeaders.isSome or attempt.responseHeadersB64.isSome or
        attempt.responseBodyB64.isSome or attempt.responseComplete.isSome or
        attempt.responseReaderJoined.isSome or attempt.httpStatus.isSome or
        attempt.latencyMs.isSome or attempt.inputTokens.isSome or attempt.outputTokens.isSome or
        attempt.promptTokenIds.isSome or attempt.sampledTokenIds.isSome or
        attempt.behaviorLogprobs.isSome or attempt.stopReason.isSome or attempt.rejectionReason.isSome or
        attempt.modelIdentity.isSome or attempt.tokenizerIdentity.isSome or attempt.chatTemplateSha256.isSome:
      raise newException(BullwhipError, "first model start must precede observed response facts")
  else:
    let before = gs.startedAttempts[id]
    if (before["latency_ms"].kind != JNull or before["response_reader_joined"] == %true) and evidence != before:
      raise newException(BullwhipError, "finished native attempt evidence is immutable")
    for key in ["prompt", "request", "decoder", "policy"]:
      if evidence[key] != before[key]:
        raise newException(BullwhipError, "started model request evidence is immutable")
    for key in ["response_body_b64", "response_headers_b64"]:
      if before[key].kind != JNull:
        if evidence[key].kind != JString or
            not decode(evidence[key].getStr()).startsWith(decode(before[key].getStr())):
          raise newException(BullwhipError, "received native bytes cannot be rewritten")
    if before["response_complete"] == %true and
        (evidence["response_complete"] != %true or evidence["response_body_b64"] != before["response_body_b64"] or
          evidence["response_headers_b64"] != before["response_headers_b64"]):
      raise newException(BullwhipError, "complete native response cannot be rewritten")
    for key in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
        "model_identity", "tokenizer_identity", "chat_template_sha256"]:
      if before[key].kind != JNull and evidence[key] != before[key]:
        raise newException(BullwhipError, "received native identity cannot be rewritten")
  if gs.completedAttempts.hasKey(id) and evidence != gs.completedAttempts[id]:
    raise newException(BullwhipError, "completed native evidence is immutable")
  gs.startedAttempts[id] = copy(evidence)
  if completed: gs.completedAttempts[id] = copy(evidence)
  if gs.awaiting[seat] and gs.latestDecisions[seat] == id:
    var updated = false
    for existing in gs.externalAttempts[seat].mitems:
      if existing.attemptId == attempt.attemptId:
        let parsed = existing.parsedAction
        let accepted = existing.accepted
        let rejection = existing.rejectionReason
        existing = attempt
        existing.parsedAction = parsed
        existing.accepted = accepted
        existing.rejectionReason = rejection
        updated = true
    if not updated: gs.externalAttempts[seat].add(attempt)

proc issueExternalDecision(gs: var GameState, seat: int, retry: bool) =
  inc gs.decisionCounter
  let id = "bullwhip-" & $gs.currentWeek & "-" & $seat & "-" & $gs.decisionCounter
  let observation = gs.currentObservations[seat]
  let messages = %*[{"role": "system", "content": systemPrompt(observation)},
    {"role": "user", "content": userPrompt(observation, gs.prompts[seat], retry)}]
  gs.issuedSeats[id] = seat
  gs.issuedAt[id] = getMonoTime()
  gs.issuedObservations[id] = copy(observation)
  gs.issuedPrompts[id] = messages
  gs.latestDecisions[seat] = id
  let decision = %*{"type": "decision", "protocol": "bullwhip.player.v3",
    "decision_id": id, "observation": observation, "messages": messages,
    "transport": {"budget_ms": max(0'i64, (gs.phaseDeadline - getMonoTime()).inMilliseconds),
      "cleanup_budget_ms": 5000}}
  if gs.playerSockets.hasKey(seat):
    if retry:
      gs.playerSockets[seat].send($(%*{"type": "rejected", "decision_id": id,
        "reason": "order proposal rejected", "observation": decision}))
    else: gs.playerSockets[seat].send($decision)

proc waitUntil(deadline: MonoTime) =
  while getMonoTime() < deadline and not interruptionRequested(): sleep(10)

proc finishEpisode(runtimeConfig: RuntimeConfig, failed = false) =
  ## All game-owned inference workers have returned and joined before entry.
  let cleanupDeadline = getMonoTime() + initDuration(seconds = 5)
  var results: JsonNode
  var replayData: string
  var targets: seq[int]
  var interrupted = failed or interruptionRequested()
  withLock stateLock:
    if state.finished: return
    state.stopping = true
    for byte in urandom(16): state.stopId.add(toHex(byte, 2).toLowerAscii())
    state.stopIssuedAt = getMonoTime()
    state.acknowledgementDeadline = min(cleanupDeadline, state.stopIssuedAt + initDuration(seconds = 3))
    for slot, external in state.external:
      if external:
        targets.add(slot)
        if state.playerSockets.hasKey(slot):
          state.playerSockets[slot].send($(%*{"type": "stop", "stop_id": state.stopId,
            "decision_id": (if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()),
            "cleanup_budget_ms": max(0'i64, (state.acknowledgementDeadline - getMonoTime()).inMilliseconds)}))
  while getMonoTime() < state.acknowledgementDeadline:
    var joined = true
    withLock stateLock:
      for slot in targets: joined = joined and slot in state.stoppedSlots
    if joined: break
    sleep(10)
  withLock stateLock:
    if state.finished: return
    state.stopping = true
    for slot in targets:
      if slot notin state.stoppedSlots: interrupted = true
    state.finished = true
    results = state.sim.resultsJson()
    if results["reason"].getStr() != "complete": interrupted = true
    replayData = state.replayPayload(results)
    if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
      var represented = initHashSet[string]()
      for record in state.records:
        var attempts = record.decision.attempts
        for attempt in attempts.mitems:
          represented.incl(attempt.attemptId)
          for _, evidence in state.startedAttempts:
            if evidence["attempt_id"] == %attempt.attemptId:
              let parsed = attempt.parsedAction
              let accepted = attempt.accepted
              let rejection = attempt.rejectionReason
              attempt = readAttemptEvidence(evidence)
              attempt.parsedAction = parsed
              attempt.accepted = accepted
              attempt.rejectionReason = rejection
        state.trajectory.recordDecision(record.id, record.seat,
          record.observation, attempts,
          record.decision.selectedAttemptId, decisionJson(record.decision),
          (if record.decision.selectedAttemptId.isSome: asAccepted else: asFallback),
          terminal = record.terminal, fallbackOrigin = (if record.decision.selectedAttemptId.isSome:
            none(string) else: some("engine-basestock")))
      for seat, attempts in state.nativeAttempts:
        var missing: seq[DecisionAttempt]
        for attempt in attempts:
          if attempt.attemptId notin represented:
            var unapplied = attempt
            unapplied.accepted = false
            unapplied.rejectionReason = some("native attempt never reached an applied engine action")
            missing.add(unapplied)
        if missing.len > 0:
          state.trajectory.recordDecision($state.currentWeek & "-" & $seat,
            $seat, state.currentObservations[seat], missing, none(string),
            newJNull(), asMissing, terminal = true)
      for id, evidence in state.startedAttempts:
        var attempt = readAttemptEvidence(evidence)
        if attempt.attemptId notin represented:
          attempt.rejectionReason = some("issued native attempt never reached an applied engine action")
          state.trajectory.recordDecision(id, $state.issuedSeats[id],
            state.issuedObservations[id], @[attempt], none(string), newJNull(),
            asMissing, terminal = true)
      var outcomes = newJObject()
      for slot in 0 ..< Seats: outcomes[$slot] = results["scores"][slot]
      var privateOutcome = copy(results)
      var cleanup = newJObject()
      for slot in targets:
        cleanup[$slot] = %(if slot in state.stoppedSlots: "joined" else: "unresolved")
      privateOutcome["player_cleanup"] = cleanup
      state.trajectory.finish((if failed: esFailed elif interrupted: esTruncated else: esCompleted),
        privateOutcome, if interrupted: newJNull() else: outcomes)
    if not interrupted:
      var aliasNames = newJArray()
      for name in state.sim.names: aliasNames.add(%name)
      var final = %*{"type": "final", "done": true,
        "scores": results["scores"], "costs": results["costs"],
        "roles": results["roles"], "names": aliasNames,
        "weeks": results["weeks"], "reason": results["reason"]}
      for slot, socket in state.playerSockets:
        final["slot"] = %slot
        socket.send($final)
      state.broadcastLocked()
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    let httpMethod = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()
      of "PUT": ahPut
      of "POST": ahPost
      else: raise newException(ValueError, "unsupported artifact method")
    writeTrajectoryArtifact(state.trajectory, getEnv(CogameSaveTrajectoryUriEnv), cleanupDeadline, httpMethod)
  if interrupted: return
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD", cleanupDeadline)
  writeArtifact(runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD", cleanupDeadline)
  waitUntil(min(cleanupDeadline, getMonoTime() + initDuration(milliseconds = 500)))

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = getMonoTime()
    var episodeDeadline = gameStart + initDuration(seconds = config.episodeTimeoutSeconds)
    var finalizationStarted = false
    defer:
      let wasInterrupted = interruptionRequested()
      requestNativeStop()
      if not finalizationStarted:
        finalizationStarted = true
        finishEpisode(runtimeConfig, failed = not wasInterrupted)
      gameServer.close()
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS").strip()
    let timeoutSeconds = if hostedTimeout.len > 0: parseFloat(hostedTimeout)
      else: config.episodeTimeoutSeconds.float
    if timeoutSeconds <= 0 or classify(timeoutSeconds) in {fcNan, fcInf, fcNegInf}:
      raise newException(BullwhipError, "episode timeout must be finite and positive")
    if config.llmTimeoutSeconds <= 0:
      raise newException(BullwhipError, "decision budget must be positive")
    episodeDeadline = gameStart + initDuration(nanoseconds = int64(timeoutSeconds * 1_000_000_000))
    let deadline = min(episodeDeadline, gameStart + initDuration(
      nanoseconds = int64(config.playerConnectTimeoutSeconds * 1_000_000_000)))

    while getMonoTime() < deadline and not interruptionRequested():
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
        for seat in 0 ..< config.tokens.len:
          if not state.ready[seat]: allConnected = false
      if allConnected:
        break
      waitUntil(min(deadline, getMonoTime() + initDuration(milliseconds = 200)))

    withLock stateLock:
      state.started = true
      echo "bullwhip: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    let playDeadline = gameStart + initDuration(
      nanoseconds = int64(timeoutSeconds * PlayBudgetFraction * 1_000_000_000))

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var external: seq[bool]
      var scripted: seq[ScriptKind]
      withLock stateLock:
        if state.sim.done or interruptionRequested():
          break
        if getMonoTime() >= playDeadline:
          ## The platform kills an episode that outruns its timeout and
          ## keeps nothing at all, so give up weeks rather than the whole
          ## result: stop here, between weeks.
          echo "bullwhip: episode deadline reached after ",
            state.sim.weeksPlayed, "/", config.weeks,
            " weeks; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        prompts = state.prompts
        external = state.external
        scripted = state.scripted
        echo "bullwhip: week ", state.sim.week, " of ", config.weeks,
          " at ", (getMonoTime() - gameStart).inSeconds, "s"

      let phaseDeadline = min(playDeadline, getMonoTime() + initDuration(seconds = config.llmTimeoutSeconds))
      var observations: seq[JsonNode]
      for seat in seats: observations.add(observationJson(simCopy, seat))

      ## Every external policy receives the same seat observation and returns
      ## an action. Model choice, scripted logic, and prompts belong to that
      ## policy, while the game validates every returned action.
      withLock stateLock:
        state.currentWeek = simCopy.week
        state.phaseDeadline = phaseDeadline
        for index, seat in seats: state.currentObservations[seat] = observations[index]
        for seat in seats:
          state.nativeAttempts[seat] = @[]
          if external[seat]:
            state.awaiting[seat] = true
            state.actions[seat] = nil
            state.externalAttempts[seat] = @[]
            state.externalRejections[seat] = 0
            state.externalFallback[seat] = false
            state.issueExternalDecision(seat, retry = false)

      for seat in seats:
        if external[seat]:
          scripted[seat] = skBasestock

      ## Game-owned native requests (one parallel batch for the week) run
      ## outside the lock on a snapshot; only this thread mutates the sim,
      ## so the snapshot cannot go stale.
      proc beforeCall(slot: int, attempt: DecisionAttempt) {.gcsafe.} =
        {.gcsafe.}:
          withLock stateLock: state.nativeAttempts[slot].add(attempt)
      var decisions = client.decideAll(simCopy, seats, prompts, scripted,
        phaseDeadline, beforeCall)
      withLock stateLock:
        for index, seat in seats:
          if not external[seat]: state.nativeAttempts[seat] = decisions[index].attempts

      while getMonoTime() < phaseDeadline and not interruptionRequested():
        var waiting = false
        withLock stateLock:
          for seat in seats:
            if external[seat] and state.actions[seat].isNil:
              waiting = true
        if not waiting:
          break
        waitUntil(min(phaseDeadline, getMonoTime() + initDuration(milliseconds = 20)))

      if interruptionRequested(): break
      withLock stateLock:
        for index, seat in seats:
          if external[seat]:
            state.awaiting[seat] = false
            if not state.actions[seat].isNil:
              let proposal = parseProposal($state.actions[seat], observationJson(simCopy, seat))
              doAssert proposal.kind == pkAccepted
              decisions[index] = proposal.decision
              decisions[index].attempts = state.externalAttempts[seat]
              decisions[index].selectedAttemptId = if state.externalFallback[seat]: none(string)
                else: some(state.externalAttempts[seat][^1].attemptId)
            else:
              echo "bullwhip: seat ", seat,
                " missed action deadline; using base-stock fallback"
              decisions[index].attempts = state.externalAttempts[seat]

      withLock stateLock:
        for index, seat in seats:
          if interruptionRequested(): break
          var decision = decisions[index]
          echo "bullwhip: week ", state.sim.week, " ", state.sim.names[seat],
            " (", state.sim.roleName(seat), ") orders ", decision.order,
            (if decision.say.len > 0: " says \"" & decision.say & "\""
             else: ""),
            " at ", (getMonoTime() - gameStart).inSeconds, "s"
          try:
            state.sim.applyOrder(seat, decision.order, decision.say,
              decision.notes, decision.scripted)
          except BullwhipError as error:
            if decision.selectedAttemptId.isSome:
              decision.attempts[^1].accepted = false
              decision.attempts[^1].rejectionReason = some(error.msg)
            echo "bullwhip: reply rejected; using scripted fallback"
            let fallback = scriptedAction(state.sim, seat, skBasestock)
            state.sim.applyOrder(seat, fallback.order, "", "", true)
            decision.order = fallback.order
            decision.say = ""
            decision.notes = ""
            decision.selectedAttemptId = none(string)
          state.records.add(PendingDecision(id: $simCopy.week & "-" & $seat,
            seat: $seat, observation: observations[index], decision: decision,
            terminal: state.sim.done))
        state.broadcastLocked()

      ## Pace between weeks so spectators can read the chain.
      if config.turnDelayMs > 0:
        waitUntil(min(playDeadline, getMonoTime() + initDuration(milliseconds = config.turnDelayMs)))

    ## Let the last week land before the final frame.
    if config.turnDelayMs > 0:
      waitUntil(min(playDeadline, getMonoTime() + initDuration(milliseconds = config.turnDelayMs)))
    finalizationStarted = true
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    withLock stateLock:
      if slot < 0 or slot >= state.config.tokens.len or state.config.tokens[slot] != token:
        request.respond(401)
        return
      if state.started or state.stopping or state.finished or state.playerSockets.hasKey(slot):
        request.respond(409)
        return
      let websocket = request.upgradeToWebSocket()
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      websocket.send($ %*{"type": "welcome", "protocol": "bullwhip.player.v3",
        "slot": slot, "name": state.sim.names[slot],
        "role": state.sim.roleName(slot), "weeks": state.config.weeks})

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      let receivedAt = getMonoTime()
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "register":
          if payload["control"].getStr() != "external":
            raise newException(BullwhipError, "unknown player control")
          withLock stateLock:
            if state.started or state.stopping or state.finished or state.ready[slot]:
              raise newException(BullwhipError, "player registration is frozen")
            let prompt = payload["prompt"].getStr()
            if prompt.runeLen > MaxPromptLen:
              raise newException(BullwhipError, "external operator prompt exceeds rune budget")
            state.prompts[slot] = prompt
            state.external[slot] = true
            state.ready[slot] = true
          echo "bullwhip: slot ", slot, " registered external action control"
        elif payload["type"].getStr() in ["attempt_started", "action"]:
          let id = payload["decision_id"].getStr()
          withLock stateLock:
            if state.finished: return
            if not state.external[slot] or not state.issuedSeats.hasKey(id) or
                state.issuedSeats[id] != slot or receivedAt < state.issuedAt[id]:
              raise newException(BullwhipError, "decision does not belong to authenticated issued seat")
            if payload["type"].getStr() == "attempt_started":
              state.retainExternalAttempt(slot, id, payload["training_attempt"], completed = false)
              return
            let evidence = payload["training_attempt"]
            let source = payload["source"].getStr()
            if source notin ["llm", "unknown", "fallback"]:
              raise newException(BullwhipError, "unknown external action source")
            if evidence.kind != JNull and source != "unknown":
              state.retainExternalAttempt(slot, id, evidence, completed = true)
            elif source == "llm":
              raise newException(BullwhipError, "model action requires native evidence")
            if state.stopping or interruptionRequested() or not state.awaiting[slot] or
                state.latestDecisions[slot] != id or not state.actions[slot].isNil or receivedAt > state.phaseDeadline:
              return
            var attempt = if evidence.kind == JNull:
              newDecisionAttempt(id & "-external", "external-bullwhip", aoUnknown)
              else: readAttemptEvidence(evidence)
            if source == "unknown": attempt.origin = aoUnknown
            if evidence.kind == JNull:
              attempt.prompt = copy(state.issuedPrompts[id])
              attempt.response = copy(payload["action"])
            let transportRejection = attempt.rejectionReason
            attempt.rejectionReason = some("external order proposal not applied")
            let observation = state.currentObservations[slot]
            var proposal = if source == "fallback": Proposal(kind: pkRejected, reason: "player fallback")
              else: parseProposal($payload["action"], observation)
            if source == "llm":
              if attempt.response.kind != JString or attempt.rawResponse.kind != JString or
                  attempt.responseComplete != some(true) or attempt.responseReaderJoined != some(true) or
                  attempt.httpStatus != some(200) or attempt.model.isNone or transportRejection.isSome:
                raise newException(BullwhipError, "model action requires its complete successful native response")
              let served = parseJson(attempt.rawResponse.getStr())
              var text = ""
              if served.kind != JObject or served["content"].kind != JArray or served["model"] != %attempt.model.get():
                raise newException(BullwhipError, "selected model differs from received native body")
              for blockNode in served["content"]:
                if blockNode.kind != JObject or blockNode["type"].kind != JString:
                  raise newException(BullwhipError, "native content block violates completion schema")
                if blockNode["type"].getStr() == "text":
                  if blockNode["text"].kind != JString:
                    raise newException(BullwhipError, "native text content must be text")
                  text.add(blockNode["text"].getStr())
              if %text != attempt.response:
                raise newException(BullwhipError, "selected response differs from received native body")
              let sampled = parseProposal(attempt.response.getStr(), observation)
              if sampled.kind == pkAccepted: attempt.parsedAction = decisionJson(sampled.decision)
              if sampled.kind != pkAccepted or proposal.kind != pkAccepted or
                  attempt.parsedAction != decisionJson(proposal.decision):
                proposal = Proposal(kind: pkRejected, reason: "model response differs from player action")
            var chosen: Decision
            var retry = false
            if proposal.kind == pkAccepted:
              chosen = proposal.decision
              var probe = state.sim
              probe.applyOrder(slot, chosen.order, chosen.say, chosen.notes, false)
              if source != "llm": attempt.parsedAction = decisionJson(chosen)
              attempt.accepted = true
              attempt.rejectionReason = none(string)
            else:
              inc state.externalRejections[slot]
              attempt.rejectionReason = some(proposal.reason)
              retry = state.externalRejections[slot] == 1 and source != "fallback"
              if not retry:
                chosen = scriptedAction(observation, skBasestock)
                state.externalFallback[slot] = true
                websocket.send($(%*{"type": "consumed_rejection", "decision_id": id,
                  "reason": proposal.reason, "action": decisionJson(chosen)}))
            var stored = false
            for existing in state.externalAttempts[slot].mitems:
              if existing.attemptId == attempt.attemptId:
                existing = attempt
                stored = true
            if not stored: state.externalAttempts[slot].add(attempt)
            if retry:
              state.issueExternalDecision(slot, retry = true)
              return
            state.actions[slot] = decisionJson(chosen)
        elif payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let scripted =
            if node.isNil: skNone
            elif node.kind == JBool: (if node.getBool(): skBasestock
              else: skNone)
            else: parseScriptKind(node.getStr())
          withLock stateLock:
            if state.started or state.stopping or state.finished or state.ready[slot]:
              raise newException(BullwhipError, "player registration is frozen")
            state.prompts[slot] = prompt
            state.ready[slot] = true
            state.scripted[slot] = scripted
          echo "bullwhip: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted != skNone: ", scripted " & $scripted else: ""), ")"
        elif payload["type"].getStr() == "stopped":
          withLock stateLock:
            if state.finished: return
            if not state.external[slot] or payload["worker_status"].getStr() notin ["joined", "no_active_call"] or
                payload["attempts"].kind != JArray:
              raise newException(BullwhipError, "stop must carry its authenticated worker status and attempts")
            let id = payload["decision_id"]
            if id.kind == JString:
              if not state.issuedSeats.hasKey(id.getStr()) or state.issuedSeats[id.getStr()] != slot or
                  receivedAt < state.issuedAt[id.getStr()]:
                raise newException(BullwhipError, "stop evidence does not belong to authenticated issued seat")
              for evidence in payload["attempts"]:
                state.retainExternalAttempt(slot, id.getStr(), evidence, completed = false)
            elif id.kind != JNull or payload["attempts"].len != 0:
              raise newException(BullwhipError, "stop without issued decision cannot assert model attempts")
            if state.playerSockets.hasKey(slot) and state.playerSockets[slot] == websocket:
              websocket.send($(%*{"type": "evidence_received", "decision_id": id, "stop_id": payload["stop_id"]}))
            let latest = if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()
            if not state.stopping or id != latest or receivedAt < state.stopIssuedAt or
                receivedAt > state.acknowledgementDeadline or payload["stop_id"] != %state.stopId:
              raise newException(BullwhipError, "stop acknowledgement differs from issued cleanup window")
            for evidence in payload["attempts"]:
              if readAttemptEvidence(evidence).responseReaderJoined != some(true):
                raise newException(BullwhipError, "stop retains an unjoined native reader")
            for issued, known in state.startedAttempts:
              if state.issuedSeats[issued] == slot and readAttemptEvidence(known).responseReaderJoined != some(true):
                raise newException(BullwhipError, "stop omitted an unjoined issued native reader")
            state.stoppedSlots.incl(slot)
      except CatchableError:
        echo "bullwhip: ignoring bad private player frame"
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          # Retain the authenticated socket binding until episode seal: final
          # transport evidence may be queued behind this close event.
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.weeks = payload["config"]{"weeks"}.getInt(36)
  result.seed = payload["config"]{"seed"}.getInt(0)
  result.talk = payload["config"]{"talk"}.getBool(true)
  ## The replay carries the episode's fitted cap; never re-fit it. Roles
  ## and the demand script are re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var publicEvents = newJArray()
  for event in events: publicEvents.add(publicEventJson(event))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("bullwhip.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": publicEvents,
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  echo "bullwhip: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  installNativeStopHandlers()
  if config.tokens.len != config.players.len:
    raise newException(BullwhipError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.external = newSeq[bool](config.players.len)
  state.ready = newSeq[bool](config.players.len)
  state.awaiting = newSeq[bool](config.players.len)
  state.actions = newSeq[JsonNode](config.players.len)
  state.externalAttempts = newSeq[seq[DecisionAttempt]](config.players.len)
  state.nativeAttempts = newSeq[seq[DecisionAttempt]](config.players.len)
  state.currentObservations = newSeq[JsonNode](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  state.externalRejections = newSeq[int](config.players.len)
  state.externalFallback = newSeq[bool](config.players.len)
  runtimeConfigGlobal = runtimeConfig
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    state.trajectory = newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
      "bullwhip-" & $config.seed, "bullwhip", getEnv("COWORLD_GAME_VERSION"),
      getEnv("COWORLD_SOURCE_REVISION"))

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  var ownerCreated = false
  echo "bullwhip: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host,
      onReady = proc(server: Server) {.gcsafe.} =
        {.gcsafe.}:
          createThread(gameThread, runGame, runtimeConfig)
          ownerCreated = true)
  finally:
    let wasInterrupted = interruptionRequested()
    requestNativeStop()
    if ownerCreated: joinThread(gameThread)
    else: finishEpisode(runtimeConfig, failed = not wasInterrupted)
