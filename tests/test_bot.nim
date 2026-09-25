## The scripted baselines must play whole episodes without ever proposing
## an illegal order — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## The base-stock bot must also actually absorb the demand step, or it is
## no partner worth beating.

import std/[json, monotimes, strutils, times, unicode, unittest]
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

  test "model replies parse":
    check parseDecision(parseJson("""{"order": 7}""")).order == 7
    check parseDecision(parseJson("""{"order": "12"}""")).order == 12
    check parseDecision(parseJson("""{"order": 6.6}""")).order == 7
    check parseDecision(parseJson("""{"order": " 9 "}""")).order == 9
    let full = parseDecision(parseJson(
      """{"order": 5, "say": "demand looks like 8", "notes": "on order 13"}"""))
    check full.order == 5
    check full.say == "demand looks like 8"
    check full.notes == "on order 13"
    expect BullwhipError:
      discard parseDecision(parseJson("""{"order": -1}"""))
    expect BullwhipError:
      discard parseDecision(parseJson("""{"order": 501}"""))
    expect BullwhipError:
      discard parseDecision(parseJson("""{"order": "lots"}"""))
    expect BullwhipError:
      discard parseDecision(parseJson("""{"notes": "no order"}"""))
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
    let text = sim.userPrompt(retailer, "operator says hi")
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
