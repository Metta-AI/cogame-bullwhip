## The scripted baselines must play whole episodes without ever proposing
## an illegal order — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## The base-stock bot must also actually absorb the demand step, or it is
## no partner worth beating.

import std/[json, monotimes, os, strutils, times, unicode, unittest]
import bullwhip/[llm, server, sim]

proc fixture(seed: int, weeks = 36): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.weeks = weeks
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.pendingSeats():
      let decision = scriptedAction(result, seat, kinds[seat])
      ## The bot's order must be legal as-is: applyOrder raises on
      ## anything else and would fail this test.
      result.applyOrder(seat, decision.order, decision.say, decision.notes,
        true)
      check decision.say.len == 0
      check decision.notes.len == 0

suite "scripted baselines":
  test "four base-stock seats play full episodes legally and fast":
    for seed in [1, 7, 42, 1234]:
      let config = fixture(seed)
      let started = getMonoTime()
      let sim = playScripted(config,
        [skBasestock, skBasestock, skBasestock, skBasestock])
      let elapsed = (getMonoTime() - started).inMilliseconds
      check sim.done
      check sim.reason == "complete"
      check sim.weeksPlayed == config.weeks
      var orders = 0
      var biggest = 0
      for event in sim.events:
        if event.kind == evOrder:
          inc orders
          biggest = max(biggest, event.order)
      check orders == config.weeks * Seats
      check biggest <= 100
      let results = sim.resultsJson()
      echo "seed ", seed, ": demand ", sim.demand[^1], " chain cost ",
        results["chainCost"].getFloat(), " biggest order ", biggest, ", ",
        elapsed, " ms"
      check elapsed < 2000

  test "base-stock absorbs the step: the chain is healthy by the end":
    for seed in [1, 7, 42, 1234]:
      let sim = playScripted(fixture(seed),
        [skBasestock, skBasestock, skBasestock, skBasestock])
      for stage in 0 ..< Stages:
        let state = sim.stages[stage]
        check state.backlog <= 10
        ## And it is not sitting on a mountain either.
        check state.inventory <= 6 * sim.demand[^1]

  test "mirror seats pass the demand through unchanged":
    let sim = playScripted(fixture(7, weeks = 20),
      [skMirror, skMirror, skMirror, skMirror])
    check sim.done
    for record in sim.history[0 ..< ^1]:
      for stage in 0 ..< Stages:
        check record.orders[stage] == record.stages[stage].incoming

  test "mixed chains complete":
    let sim = playScripted(fixture(3, weeks = 24),
      [skMirror, skBasestock, skMirror, skBasestock])
    check sim.done
    check sim.weeksPlayed == 24

  test "decideAll falls back to scripted with no credentials":
    var credentials: seq[(string, string)]
    for key in ["COWORLD_LLM_ENDPOINT", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI"]:
      credentials.add((key, getEnv(key)))
      putEnv(key, "")
    defer:
      for (key, value) in credentials: putEnv(key, value)
    let config = fixture(3, weeks = 8)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    let decisions = client.decideAll(sim, seats,
      @["be bold", "", "", ""], @[skNone, skNone, skMirror, skNone])
    check decisions.len == Seats
    for index, seat in seats:
      let kind = if seat == 2: skMirror else: skBasestock
      check decisions[index].order == scriptedAction(sim, seat, kind).order
      sim.applyOrder(seat, decisions[index].order, "", "", true)
    check sim.week == 1

  test "model replies parse through the canonical typed validator":
    let observation = observationJson(initSim(fixture(7)), 0)
    for (text, expected) in [("{\"order\":7}", 7), ("{\"order\":\"12\"}", 12),
        ("{\"order\":6.6}", 7), ("{\"order\":\" 9 \"}", 9)]:
      let proposal = parseProposal(text, observation)
      check proposal.kind == pkAccepted
      check proposal.decision.order == expected
    let full = parseProposal("{\"order\":5,\"say\":\"demand looks like 8\",\"notes\":\"on order 13\"}", observation)
    check full.kind == pkAccepted
    check full.decision.say == "demand looks like 8"
    check full.decision.notes == "on order 13"
    for text in ["{\"order\":-1}", "{\"order\":501}", "{\"order\":\"lots\"}",
        "{\"notes\":\"no order\"}", "no JSON", "{not valid}", "{\"order\":\"Inf\"}"]:
      check parseProposal(text, observation).kind == pkRejected
    var long = ""
    for index in 0 ..< 700:
      long.add("é")
    check cleanText(long, MaxNotesLen).runeLen == MaxNotesLen
    check cleanText(long, MaxSayLen).runeLen == MaxSayLen
    check parseScriptKind("1") == skBasestock
    check parseScriptKind("basestock") == skBasestock
    check parseScriptKind("mirror") == skMirror
    check parseScriptKind("") == skNone

  test "prompts carry the seat's own table and nothing hidden":
    var sim = initSim(fixture(7, weeks = 8))
    for seat in sim.pendingSeats():
      sim.applyOrder(seat, 4, "hello from " & $seat, "", true)
    let retailer = sim.seatOf[0]
    let text = userPrompt(observationJson(sim, retailer), "operator says hi")
    check "You are the RETAILER" in text
    check "operator says hi" in text
    check "hello from " & $sim.seatOf[1] in text
    check ("hello from " & $sim.seatOf[2]) notin text
    check "YOUR HISTORY" in text

  test "external policies receive only their seat's history and messages":
    var sim = initSim(fixture(7, weeks = 8))
    for seat in sim.pendingSeats():
      sim.applyOrder(seat, 4, "hello from " & $seat,
        "private note " & $seat, true)
    let retailer = sim.seatOf[0]
    let observation = observationJson(sim, retailer)
    check observation["role"].getStr() == "Retailer"
    check observation["history"].len > 0
    check observation["notes"].getStr() == "private note " & $retailer
    check observation["heard"].len == 1
    check observation["heard"][0]["message"].getStr() ==
      "hello from " & $sim.seatOf[1]
    check not observation.hasKey("demand")
    check not observation.hasKey("stages")
    check observation["legal"]["orderMax"].getInt() == MaxOrder

  test "hidden demand and other stages cannot change teacher or model inputs":
    for seat in 0 ..< Seats:
      var game = initSim(fixture(71, weeks = 8))
      let observation = observationJson(game, seat)
      let system = systemPrompt(observation)
      let user = userPrompt(observation, "private operator")
      let teacher = scriptedAction(game, seat, skBasestock)
      let ownStage = game.roleOf[seat]
      for stage in 0 ..< Stages:
        if stage != ownStage:
          game.stages[stage].inventory += 900
          game.stages[stage].backlog += 700
          game.history[0].stages[stage].incoming += 600
          game.notes[game.seatOf[stage]] = "other private notes"
      for index in 1 ..< game.demand.len: game.demand[index] += 500
      let changed = observationJson(game, seat)
      check changed == observation
      check systemPrompt(changed) == system
      check userPrompt(changed, "private operator") == user
      check scriptedAction(game, seat, skBasestock) == teacher

  test "public events redact notebooks while historical events remain readable":
    var game = initSim(fixture(17, weeks = 8))
    let seat = game.pendingSeats()[0]
    game.applyOrder(seat, 4, "public neighbour message", "private notebook", false)
    let event = game.events[^1]
    check event.kind == evOrder
    check event.eventToJson()["text"].getStr() == "private notebook"
    let public = publicEventJson(event)
    check not public.hasKey("text")
    check public["say"].getStr() == "public neighbour message"
    check eventFromJson(event.eventToJson()).text == "private notebook"

  test "public live and reconstructed tables redact all private notebooks":
    var sim = initSim(fixture(7))
    sim.notes[0] = "private-notebook-sentinel"
    let public = publicTableJson(sim)
    check "private-notebook-sentinel" notin $public
    for seat in public["seats"]: check not seat.hasKey("notes")
    check observationJson(sim, 0)["notes"].getStr() == "private-notebook-sentinel"
