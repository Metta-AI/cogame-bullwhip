## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:bullwhip-train-bridge tools/train_bridge.nim

import std/[json, os]
import bullwhip/[llm, sim]

const OperatorPrompt = "Minimize your own inventory and backlog costs using only your stage history."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: Sim, id, seat: int): JsonNode =
  let stage = game.roleOf[seat]
  let state = game.stages[stage]
  %*{
    "kind": "decision", "game": "bullwhip", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.week,
    "semantic_view": {
      "seat": seat, "role": game.roleName(seat), "week": game.week,
      "weeks": game.config.weeks, "inventory": state.inventory,
      "backlog": state.backlog, "incoming": state.incoming,
      "received": state.received, "shipped": state.shipped,
      "ship_pipe": state.shipPipe, "last_order": state.lastOrder,
      "cost_week": state.costWeek, "cost_total": state.costTotal
    },
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": userPrompt(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["order"],
      "properties": {"order": {"type": "integer", "minimum": 0,
        "maximum": MaxOrder}}},
    "typed_question": newJNull()
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
  if args.len != 1:
    quit("usage: bullwhip-train-bridge MANIFEST", 1)
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
      seat = game.pendingSeats()[0]
      response = game.decision(id, seat)
    of "encode":
      doAssert not game.done
      response = game.encoding(id, seat)
    of "teacher":
      doAssert not game.done
      let teacher = game.scriptedAction(seat, skBasestock)
      response = %*{"response": $(%*{"order": teacher.order})}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let parsed = parseDecision(action)
      game.applyOrder(seat, parsed.order, parsed.say, parsed.notes, false)
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
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
