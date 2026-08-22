import std/[json, sets, unicode, unittest]
import bullwhip/sim

proc fixtureConfig(weeks = 36, seed = 0, talk = true): GameConfig =
  result = defaultGameConfig()
  result.weeks = weeks
  result.seed = seed
  result.talk = talk
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc orderAll(sim: var Sim, orders: array[Stages, int], say = "") =
  ## Every seat orders `orders[stage]` for its stage; the week resolves.
  for seat in sim.pendingSeats():
    sim.applyOrder(seat, orders[sim.roleOf[seat]], say, "", true)

suite "setup":
  test "roles are a seeded permutation of the four stages":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var seen = initHashSet[int]()
      for seat in 0 ..< Seats:
        seen.incl(sim.roleOf[seat])
        check sim.seatOf[sim.roleOf[seat]] == seat
      check seen.len == Stages
    ## Different seeds really do move the factory around.
    var factories = initHashSet[int]()
    for seed in 0 ..< 20:
      factories.incl(initSim(fixtureConfig(seed = seed)).seatOf[3])
    check factories.len > 1

  test "demand is flat then steps up once":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(weeks = 36, seed = seed))
      check sim.demand.len == 37
      var shift = -1
      for week, level in sim.demand:
        if level != BaseDemand:
          if shift < 0:
            shift = week
          check level == sim.demand[shift]
        else:
          check shift < 0
      check shift in 4 .. 8
      check sim.demand[shift] in 7 .. 12

  test "the table opens at week 0 with the classic initial state":
    let sim = initSim(fixtureConfig())
    check sim.week == 0
    check sim.weeksPlayed == 0
    check sim.phase == phOrders
    check sim.pendingSeats() == @[0, 1, 2, 3]
    for stage in 0 ..< Stages:
      check sim.stages[stage].inventory == 12
      check sim.stages[stage].backlog == 0
      check sim.stages[stage].shipPipe == [4, 4]
      check sim.stages[stage].costTotal == 6.0
    check sim.events.len == 2
    check sim.events[0].kind == evStart
    check sim.events[1].kind == evWeek
    check sim.events[1].demand == 4
    check sim.history.len == 1

  test "seed determinism":
    let a = initSim(fixtureConfig(seed = 77))
    let b = initSim(fixtureConfig(seed = 77))
    let c = initSim(fixtureConfig(seed = 78))
    check a.roleOf == b.roleOf
    check a.demand == b.demand
    check a.names == b.names
    check a.demand != c.demand or a.roleOf != c.roleOf

suite "resolution":
  test "a steady chain ordering 4 stays at 12 / 0 and costs 6 a week":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 3))
    ## Seed 3's shift week is whatever it is; run only through week 3,
    ## which every seed keeps flat.
    for week in 0 ..< 3:
      sim.orderAll([4, 4, 4, 4])
      check sim.week == week + 1
      for stage in 0 ..< Stages:
        check sim.stages[stage].inventory == 12
        check sim.stages[stage].backlog == 0
        check sim.stages[stage].received == 4
        check sim.stages[stage].incoming == 4
        check sim.stages[stage].shipped == 4
        check sim.stages[stage].costWeek == 6.0
        check sim.stages[stage].costTotal == 6.0 * float(week + 2)
        check sim.stages[stage].lastOrder == 4

  test "hand-computed step: a retailer surge propagates with the delays":
    var sim = initSim(fixtureConfig(weeks = 12, seed = 3))
    ## Week 0: retailer orders 10, everyone else 4.
    sim.orderAll([10, 4, 4, 4])
    ## Week 1 (demand still 4): retailer unchanged; the wholesaler sees the
    ## 10 next week, not yet.
    check sim.stages[0].inventory == 12
    check sim.stages[1].incoming == 10
    check sim.stages[1].shipped == 10
    check sim.stages[1].inventory == 12 + 4 - 10
    check sim.stages[1].backlog == 0
    check sim.stages[1].costWeek == 3.0
    ## The wholesaler's 10 is now in the retailer's pipe, two weeks out.
    check sim.stages[0].shipPipe == [4, 10]
    check sim.stages[2].incoming == 4
    sim.orderAll([4, 4, 4, 4])
    check sim.stages[0].shipPipe == [10, 4]
    check sim.stages[0].received == 4
    sim.orderAll([4, 4, 4, 4])
    check sim.stages[0].received == 10
    check sim.stages[0].inventory == 12 + 10 - 4

  test "backlog accrues, is owed, and costs 1 per unit":
    var sim = initSim(fixtureConfig(weeks = 12, seed = 3))
    ## Wholesaler orders 0 for two weeks: the retailer will be starved
    ## later, but first the distributor sees incoming 0.
    sim.orderAll([40, 4, 4, 4])
    ## Week 1: wholesaler incoming 40 > 12 + 4 = 16 on hand.
    check sim.stages[1].shipped == 16
    check sim.stages[1].backlog == 24
    check sim.stages[1].inventory == 0
    check sim.stages[1].costWeek == 24.0
    sim.orderAll([4, 4, 4, 4])
    ## Week 2: 4 arrive, 4 new + 24 owed = 28 due, ship 4, backlog 24.
    check sim.stages[1].received == 4
    check sim.stages[1].shipped == 4
    check sim.stages[1].backlog == 24

  test "the factory's order is its own production, two weeks out":
    var sim = initSim(fixtureConfig(weeks = 12, seed = 3))
    sim.orderAll([4, 4, 4, 9])
    check sim.stages[3].shipPipe == [4, 9]
    sim.orderAll([4, 4, 4, 4])
    check sim.stages[3].shipPipe == [9, 4]
    sim.orderAll([4, 4, 4, 4])
    check sim.stages[3].received == 9

  test "the demand shift reaches the retailer as incoming":
    let probe = initSim(fixtureConfig(weeks = 36, seed = 7))
    var shift = 0
    while probe.demand[shift] == BaseDemand:
      inc shift
    var sim = initSim(fixtureConfig(weeks = 36, seed = 7))
    for week in 0 ..< shift:
      sim.orderAll([4, 4, 4, 4])
    check sim.week == shift
    check sim.stages[0].incoming == probe.demand[shift]
    check sim.stages[0].incoming > BaseDemand

suite "orders":
  test "illegal orders raise and change nothing":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    expect BullwhipError:
      sim.applyOrder(0, -1, "", "", false)
    expect BullwhipError:
      sim.applyOrder(0, MaxOrder + 1, "", "", false)
    expect BullwhipError:
      sim.applyOrder(9, 4, "", "", false)
    sim.applyOrder(0, 4, "", "", false)
    expect BullwhipError:
      sim.applyOrder(0, 4, "", "", false)
    check sim.pendingSeats() == @[1, 2, 3]
    check sim.week == 0

  test "says are capped, stripped, and silenced when talk is off":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    var long = ""
    for index in 0 ..< 200:
      long.add("é")
    sim.applyOrder(0, 4, "  hello  ", "", false)
    sim.applyOrder(1, 4, long, "", false)
    check sim.says[sim.roleOf[0]] == "hello"
    check sim.says[sim.roleOf[1]].runeLen == MaxSayLen
    check sim.says[sim.roleOf[1]].validateUtf8() == -1
    ## The event log (and so the replay JSON) stays valid UTF-8.
    for event in sim.events:
      check event.say.validateUtf8() == -1
    var quiet = initSim(fixtureConfig(weeks = 8, seed = 1, talk = false))
    quiet.applyOrder(0, 4, "hello", "", false)
    check quiet.says[quiet.roleOf[0]] == ""

  test "says reach the neighbours next week; notes persist":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    let retailer = sim.seatOf[0]
    for seat in 0 ..< Seats:
      sim.applyOrder(seat, 4, (if seat == retailer: "demand is 4" else: ""),
        (if seat == retailer: "note A" else: ""), false)
    check sim.week == 1
    check sim.heard[0] == "demand is 4"
    check sim.heard[1] == ""
    check sim.notes[retailer] == "note A"
    let state = sim.tableStateJson()
    let wholesaler = sim.seatOf[1]
    check state["seats"][wholesaler]["heard"].len == 1
    check state["seats"][wholesaler]["heard"][0]["say"].getStr() ==
      "demand is 4"
    ## The distributor is not a neighbour of the retailer.
    check state["seats"][sim.seatOf[2]]["heard"].len == 0
    for seat in 0 ..< Seats:
      sim.applyOrder(seat, 4, "", "", false)
    check sim.notes[retailer] == "note A"
    check sim.heard[0] == ""

suite "scoring and endings":
  test "score is minus cost and the episode completes after `weeks`":
    var sim = initSim(fixtureConfig(weeks = 6, seed = 5))
    for week in 0 ..< 6:
      check not sim.done
      sim.orderAll([4, 4, 4, 4])
    check sim.done
    check sim.reason == "complete"
    check sim.weeksPlayed == 6
    check sim.week == 6
    check sim.history.len == 7
    check sim.events[^1].kind == evEnd
    check sim.events[^2].kind == evWeek
    check sim.events[^2].week == 6
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      check results["scores"][seat].getFloat() ==
        -results["costs"][seat].getFloat()
      check results["costs"][seat].getFloat() > 0.0
      check results["roles"][seat].getStr() == sim.roleName(seat)
    check results["weeks"].getInt() == 6
    check results["reason"].getStr() == "complete"
    expect BullwhipError:
      sim.applyOrder(0, 4, "", "", false)

  test "endEarly settles between weeks with the weeks played":
    var sim = initSim(fixtureConfig(weeks = 10, seed = 5))
    sim.orderAll([4, 4, 4, 4])
    sim.orderAll([4, 4, 4, 4])
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.weeksPlayed == 2
    check sim.pendingSeats().len == 0
    check sim.resultsJson()["reason"].getStr() == "deadline"
    sim.endEarly()
    check sim.events[^1].kind == evEnd
    check sim.events[^2].kind == evWeek

suite "viewer state":
  test "demand is revealed only through the current week":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 7))
    check sim.tableStateJson()["demand"].len == 1
    sim.orderAll([4, 4, 4, 4])
    let state = sim.tableStateJson()
    check state["demand"].len == 2
    check state["week"].getInt() == 1
    check state["orders"].len == Stages
    for stage in 0 ..< Stages:
      check state["orders"][stage].len == 1
      check state["orders"][stage][0].getInt() == 4
    check state["seats"].len == Seats
    for seat in 0 ..< Seats:
      check state["seats"][seat]["stage"].getInt() == sim.roleOf[seat]
      check state["seats"][seat]["pending"].getBool()
      check state["seats"][seat]["order"].kind == JNull
    check state["stageSeat"][0].getInt() == sim.seatOf[0]

suite "replay":
  test "events round-trip through JSON":
    var sim = initSim(fixtureConfig(weeks = 6, seed = 9))
    sim.orderAll([5, 4, 6, 4], say = "hi")
    for event in sim.events:
      let back = eventFromJson(eventToJson(event))
      check back.kind == event.kind
      check back.week == event.week
      check back.seat == event.seat
      check back.stage == event.stage
      check back.order == event.order
      check back.say == event.say
      check back.text == event.text
      check back.demand == event.demand
      check back.stages.len == event.stages.len
      for index in 0 ..< event.stages.len:
        check back.stages[index].inventory == event.stages[index].inventory
        check back.stages[index].shipPipe == event.stages[index].shipPipe
        check back.stages[index].costTotal == event.stages[index].costTotal

  test "a recorded episode re-derives frame by frame":
    let config = fixtureConfig(weeks = 8, seed = 11)
    var live = initSim(config)
    var week = 0
    while not live.done:
      live.orderAll([4 + week, 4, 6, 3 + week mod 2], say = "w" & $week)
      inc week
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].done
    check frames[^1].reason == "complete"
    ## A recorded deadline stop is honoured.
    var short = initSim(config)
    short.orderAll([4, 4, 4, 4])
    short.endEarly()
    let shortFrames = replayMatch(config, short.events)
    check shortFrames[^1].done
    check shortFrames[^1].reason == "deadline"
    check shortFrames[^1].weeksPlayed == 1

  test "a tampered week event is rejected":
    let config = fixtureConfig(weeks = 6, seed = 11)
    var live = initSim(config)
    live.orderAll([4, 4, 4, 4])
    var events = live.events
    events[^1].stages[0].inventory += 1
    expect BullwhipError:
      discard replayMatch(config, events)
