## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:bullwhip-train-bridge tools/train_bridge.nim

import std/[json, os]
import bullwhip/[llm, policy, sim, view]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

var languageMode = false
var operatorPrompt = DefaultOperatorPrompt
var rejectedAttempts = 0

proc decision(game: Sim, id, seat: int, retry = false): JsonNode =
  let stage = game.roleOf[seat]
  let state = game.stages[stage]
  result = %*{
    "kind": "decision", "game": "bullwhip", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.week,
    "semantic_view": observationJson(game, seat),
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(observationJson(game, seat))},
      {"role": "user", "content": userPrompt(observationJson(game, seat), operatorPrompt, retry)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["order"],
      "properties": {"order": {"type": "integer", "minimum": 0,
        "maximum": MaxOrder}}},
    "typed_question": newJNull(),
    "inference_mode": (if languageMode: %"text_action" else: newJNull())
  }

proc encoding(game: Sim, id, seat: int): JsonNode =
  let stage = game.roleOf[seat]
  var values = newJArray()
  for role in 0 ..< Stages:
    values.add(%(if stage == role: 1 else: 0))
  values.add(%game.week)
  values.add(%game.config.weeks)
  for index in 0 ..< MaxWeeks:
    if index < game.history.len:
      let state = game.history[index].stages[stage]
      for value in [state.incoming, state.received, state.shipped,
          state.inventory, state.backlog, state.shipPipe[0],
          state.shipPipe[1], state.lastOrder,
          game.history[index].orders[stage]]:
        values.add(%value)
      values.add(%state.costWeek)
      values.add(%state.costTotal)
    else:
      for unused in 0 ..< 11:
        values.add(%0)
  var actions = newJArray()
  for order in 0 .. MaxOrder:
    actions.add(%*{"order": order})
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 3:
    quit("usage: bullwhip-train-bridge MANIFEST [--language [OPERATOR_PROMPT]]", 1)
  if args.len >= 2:
    doAssert args[1] == "--language"
    languageMode = true
  if args.len == 3: operatorPrompt = args[2]
  let manifest = parseFile(args[0])
  let variantConfig = manifest["variants"][0]["game_config"]
  var game: Sim
  var id = 0
  var seat = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      id = 0
      rejectedAttempts = 0
      seat = game.pendingSeats()[0]
      response = game.decision(id, seat)
    of "encode":
      doAssert not game.done
      response = game.encoding(id, seat)
    of "teacher":
      doAssert not game.done
      let teacher = scriptedAction(observationJson(game, seat), skBasestock)
      response = %*{"response": $(if languageMode: decisionJson(teacher) else: %*{"order": teacher.order})}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let view = observationJson(game, seat)
      let proposal = parseProposal(request["response"].getStr(), view)
      var parsed: Decision
      var consumed = false
      if proposal.kind == pkRejected:
        inc rejectedAttempts
        if rejectedAttempts == 1:
          response = %*{"kind": "rejected", "reason": proposal.reason,
            "observation": game.decision(id, seat, retry = true)}
          stdout.writeLine($response)
          stdout.flushFile()
          continue
        parsed = scriptedAction(view, skBasestock)
        consumed = true
      else: parsed = proposal.decision
      let action = if languageMode: decisionJson(parsed) else: %*{"order": parsed.order}
      game.applyOrder(seat, parsed.order, parsed.say, parsed.notes, consumed)
      rejectedAttempts = 0
      inc id
      var observation: JsonNode
      if game.done:
        let outcome = game.resultsJson()
        var scores = newJObject()
        for slot in 0 ..< Seats:
          scores[$slot] = outcome["scores"][slot]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        seat = game.pendingSeats()[0]
        observation = game.decision(id, seat)
      response = %*{"kind": (if consumed: "consumed_rejection" else: "accepted"), "action": action,
        "observation": observation}
      if consumed: response["reason"] = %proposal.reason
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
