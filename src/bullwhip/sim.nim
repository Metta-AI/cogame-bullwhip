## Pure game rules for Bullwhip (the MIT Beer Game). No IO, no networking,
## no LLM — the server, the tests, and the wasm replay viewer all drive this
## same module.
##
## A `Sim` is one whole episode: the seeded seat→stage assignment and the
## hidden demand script, the four stage states, the live week's orders and
## messages, each seat's private notes, and the append-only event log.
## Everything random is drawn from the seed at `initSim`, so a replay
## re-derives the episode from the recorded order events alone.

import std/[json, random, strutils, unicode], types

export types

const
  Stages* = 4
  Seats* = 4
  ShipDelay* = 2
  MaxOrder* = 500
  HoldCost* = 0.5
  BacklogCost* = 1.0
  InitialInventory* = 12
  BaseDemand* = 4
  MinWeeks* = 4
  MaxWeeks* = 60
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 120_000
  MaxSayLen* = 120
  RoleNames* = ["Retailer", "Wholesaler", "Distributor", "Factory"]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  Phase* = enum
    phOrders = "orders"   ## the observed week is waiting for orders
    phDone = "done"

  WeekRecord* = object
    stages*: array[Stages, StageState]
    orders*: array[Stages, int]   ## by stage; -1 until placed

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous table aliases per seat
    roleOf*: array[Seats, int]     ## seat -> stage
    seatOf*: array[Stages, int]    ## stage -> seat
    demand*: seq[int]              ## the hidden script, weeks 0..weeks
    week*: int                     ## the observed week
    stages*: array[Stages, StageState]
    orders*: array[Stages, int]    ## live week, by stage; -1 = unplaced
    says*: array[Stages, string]   ## live week, by stage
    heard*: array[Stages, string]  ## last week's says, by stage
    notes*: seq[string]            ## latest private notes per seat
    history*: seq[WeekRecord]      ## one record per observed week
    weeksPlayed*: int              ## weeks whose orders have resolved
    phase*: Phase
    done*: bool
    reason*: string                ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the week count into the episode's limits. Idempotent: a config
  ## that already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.weeks = max(min(config.weeks, MaxWeeks), MinWeeks)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.weeks, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, week: -1, seat: -1, stage: -1, order: -1, demand: -1)

proc drawDemand(rng: var Rand, weeks: int): seq[int] =
  ## Flat at BaseDemand, then one step up that holds for the rest of the
  ## episode. The script covers weeks 0..weeks (the resolved final week
  ## too).
  let shiftWeek = 4 + rng.rand(4)      # 4..8
  let shiftLevel = 7 + rng.rand(5)     # 7..12
  for week in 0 .. weeks:
    result.add(if week < shiftWeek: BaseDemand else: shiftLevel)

proc initialStage(): StageState =
  StageState(
    inventory: InitialInventory,
    backlog: 0,
    received: BaseDemand,
    incoming: BaseDemand,
    shipped: BaseDemand,
    shipPipe: [BaseDemand, BaseDemand],
    costWeek: HoldCost * InitialInventory.float,
    costTotal: HoldCost * InitialInventory.float,
    lastOrder: -1
  )

proc logWeek(sim: var Sim) =
  var event = blankEvent(evWeek)
  event.week = sim.week
  event.demand = sim.demand[sim.week]
  for stage in 0 ..< Stages:
    event.stages.add(sim.stages[stage])
  sim.addEvent(event)

proc openWeek(sim: var Sim) =
  ## The observed week becomes live: orders unplaced, last week's messages
  ## move into `heard`.
  sim.orders = [-1, -1, -1, -1]
  sim.heard = sim.says
  sim.says = ["", "", "", ""]
  var record: WeekRecord
  record.stages = sim.stages
  record.orders = [-1, -1, -1, -1]
  sim.history.add(record)
  sim.phase = phOrders
  sim.logWeek()

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(BullwhipError,
      "bullwhip needs exactly " & $Seats & " players")
  if config.weeks < MinWeeks:
    raise newException(BullwhipError,
      "weeks must be at least " & $MinWeeks)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides: roles, then demand.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var roles = @[0, 1, 2, 3]
  rng.shuffle(roles)
  for seat in 0 ..< Seats:
    result.roleOf[seat] = roles[seat]
    result.seatOf[roles[seat]] = seat
  result.demand = rng.drawDemand(config.weeks)
  for stage in 0 ..< Stages:
    result.stages[stage] = initialStage()
  result.notes = newSeq[string](Seats)
  result.week = 0
  result.addEvent(blankEvent(evStart))
  result.openWeek()

# ---- Queries ----------------------------------------------------------------

proc roleName*(sim: Sim, seat: int): string =
  RoleNames[sim.roleOf[seat]]

proc pendingSeats*(sim: Sim): seq[int] =
  ## The seats whose order for the observed week is still due, in seat
  ## order. Empty once the episode is over.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if sim.orders[sim.roleOf[seat]] < 0:
      result.add(seat)

proc cost*(sim: Sim, seat: int): float =
  sim.stages[sim.roleOf[seat]].costTotal

proc score*(sim: Sim, seat: int): float =
  -sim.cost(seat)

proc neighbours*(stage: int): seq[int] =
  ## Downstream then upstream stage, whichever exist.
  if stage > 0: result.add(stage - 1)
  if stage < Stages - 1: result.add(stage + 1)

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.week = sim.weeksPlayed
  event.text = reason
  sim.addEvent(event)

proc resolveWeek(sim: var Sim) =
  ## All four orders are in: the chain advances one week.
  let orders = sim.orders
  var next = sim.stages
  ## 1. Shipping pipelines shift.
  for stage in 0 ..< Stages:
    next[stage].received = next[stage].shipPipe[0]
    next[stage].shipPipe[0] = next[stage].shipPipe[1]
    next[stage].shipPipe[1] = 0
  ## 2. Factory production enters its own pipeline.
  next[Stages - 1].shipPipe[1] = orders[Stages - 1]
  for stage in 0 ..< Stages:
    ## 3. Arrivals.
    next[stage].inventory += next[stage].received
    ## 4. Incoming order (one-week order delay).
    next[stage].incoming =
      if stage == 0: sim.demand[sim.week + 1] else: orders[stage - 1]
    ## 5. Fill.
    let due = next[stage].backlog + next[stage].incoming
    let shipped = min(next[stage].inventory, due)
    next[stage].inventory -= shipped
    next[stage].backlog = due - shipped
    next[stage].shipped = shipped
    ## 6. Ship downstream.
    if stage > 0:
      next[stage - 1].shipPipe[1] = shipped
    ## 7. Cost.
    next[stage].costWeek = HoldCost * next[stage].inventory.float +
      BacklogCost * next[stage].backlog.float
    next[stage].costTotal += next[stage].costWeek
    next[stage].lastOrder = orders[stage]
  sim.stages = next
  inc sim.weeksPlayed
  inc sim.week
  if sim.weeksPlayed >= sim.config.weeks:
    ## The final resolved week is observed (its cost counts) but takes no
    ## orders.
    var record: WeekRecord
    record.stages = sim.stages
    record.orders = [-1, -1, -1, -1]
    sim.history.add(record)
    sim.orders = [-1, -1, -1, -1]
    sim.heard = sim.says
    sim.says = ["", "", "", ""]
    sim.logWeek()
    sim.settle("complete")
  else:
    sim.openWeek()

proc applyOrder*(sim: var Sim, seat, order: int, say, notes: string,
    scripted: bool) =
  ## `seat` places its order for the observed week. Raises BullwhipError
  ## on anything illegal; the game server falls back to the scripted
  ## baseline on a rejection. The fourth order resolves the week.
  if sim.done:
    raise newException(BullwhipError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(BullwhipError, "bad seat: " & $seat)
  let stage = sim.roleOf[seat]
  if sim.orders[stage] >= 0:
    raise newException(BullwhipError,
      sim.names[seat] & " has already ordered this week")
  if order < 0 or order > MaxOrder:
    raise newException(BullwhipError,
      "an order is 0.." & $MaxOrder & " units")
  var message = say.strip()
  if not sim.config.talk:
    message = ""
  ## Cut on a rune boundary: a byte slice through a multi-byte character
  ## would leave invalid UTF-8 in the replay and break its JSON.
  if message.runeLen > MaxSayLen:
    message = message.runeSubStr(0, MaxSayLen)
  sim.orders[stage] = order
  sim.says[stage] = message
  sim.history[^1].orders[stage] = order
  if notes.len > 0:
    sim.notes[seat] = notes
  var event = blankEvent(evOrder)
  event.week = sim.week
  event.seat = seat
  event.stage = stage
  event.order = order
  event.say = message
  event.scripted = scripted
  event.text = sim.notes[seat]
  sim.addEvent(event)
  if sim.pendingSeats().len == 0:
    sim.resolveWeek()

proc endEarly*(sim: var Sim) =
  ## Stop now, between weeks. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest episode
  ## always beats a long one that never lands. Scores use the weeks
  ## actually played.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scoresNode = newJArray()
  var costsNode = newJArray()
  var rolesNode = newJArray()
  var chain = 0.0
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scoresNode.add(%sim.score(seat))
    costsNode.add(%sim.cost(seat))
    rolesNode.add(%sim.roleName(seat))
    chain += sim.cost(seat)
  %*{
    "names": names,
    "scores": scoresNode,
    "costs": costsNode,
    "roles": rolesNode,
    "weeks": sim.weeksPlayed,
    "maxWeeks": sim.config.weeks,
    "chainCost": chain,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc stageJson*(stage: StageState): JsonNode =
  %*{
    "inventory": stage.inventory,
    "backlog": stage.backlog,
    "received": stage.received,
    "incoming": stage.incoming,
    "shipped": stage.shipped,
    "shipPipe": [stage.shipPipe[0], stage.shipPipe[1]],
    "costWeek": stage.costWeek,
    "costTotal": stage.costTotal,
    "lastOrder": stage.lastOrder
  }

proc stageFromJson*(node: JsonNode): StageState =
  result = StageState(
    inventory: node{"inventory"}.getInt(),
    backlog: node{"backlog"}.getInt(),
    received: node{"received"}.getInt(),
    incoming: node{"incoming"}.getInt(),
    shipped: node{"shipped"}.getInt(),
    costWeek: node{"costWeek"}.getFloat(),
    costTotal: node{"costTotal"}.getFloat(),
    lastOrder: node{"lastOrder"}.getInt(-1)
  )
  if node.hasKey("shipPipe") and node["shipPipe"].len == 2:
    result.shipPipe = [node["shipPipe"][0].getInt(), node["shipPipe"][1].getInt()]

proc tableStateJson*(sim: Sim): JsonNode =
  let pending = sim.pendingSeats()
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let stage = sim.roleOf[seat]
    let state = sim.stages[stage]
    var heard = newJArray()
    for other in neighbours(stage):
      if sim.heard[other].len > 0:
        heard.add(%*{"stage": other, "say": sim.heard[other]})
    var node = stageJson(state)
    node["name"] = %sim.names[seat]
    node["stage"] = %stage
    node["role"] = %RoleNames[stage]
    node["score"] = %sim.score(seat)
    node["cost"] = %state.costTotal
    node["order"] = (if sim.orders[stage] >= 0: %sim.orders[stage]
      else: newJNull())
    node["say"] = %sim.says[stage]
    node["heard"] = heard
    node["notes"] = %sim.notes[seat]
    node["pending"] = %(seat in pending)
    seats.add(node)
  var stageSeat = newJArray()
  for stage in 0 ..< Stages:
    stageSeat.add(%sim.seatOf[stage])
  ## Demand is revealed to spectators week by week, never ahead.
  var demand = newJArray()
  for week in 0 .. min(sim.week, sim.demand.high):
    demand.add(%sim.demand[week])
  var orders = newJArray()
  for stage in 0 ..< Stages:
    var series = newJArray()
    for record in sim.history:
      if record.orders[stage] >= 0:
        series.add(%record.orders[stage])
    orders.add(series)
  %*{
    "seats": seats,
    "stageSeat": stageSeat,
    "week": sim.week,
    "weeks": sim.config.weeks,
    "weeksPlayed": sim.weeksPlayed,
    "demand": demand,
    "orders": orders,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc sameStages(a, b: seq[StageState]): bool =
  if a.len != b.len:
    return false
  for index in 0 ..< a.len:
    if a[index].inventory != b[index].inventory or
        a[index].backlog != b[index].backlog or
        a[index].received != b[index].received or
        a[index].incoming != b[index].incoming or
        a[index].shipped != b[index].shipped or
        a[index].shipPipe != b[index].shipPipe:
      return false
  true

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the order events through the rules (roles and demand come from the
  ## seed). frames[i] = state after events[0..<i]; the replayed sim's own
  ## event log mirrors the prefix so the feed lines up.
  var sim = initSim(config)
  ## initSim already logged the start and the first week event; the
  ## recorded log opens with those same two.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evWeek:
      ## Derived by the rules; only checked. The frame it produces is the
      ## same sim the last order already advanced.
      if event.week != sim.week or event.demand != sim.demand[sim.week] or
          not sameStages(event.stages, @(sim.stages)):
        raise newException(BullwhipError,
          "week " & $event.week & " does not match the seeded re-derivation")
      ## The live log wrote this week event when it opened the week; the
      ## replayed sim did too (inside the last applyOrder / initSim), so
      ## nothing is appended here.
      if sim.events.len == 0 or sim.events[^1].kind != evWeek:
        sim.events.add(event)
    of evOrder:
      sim.applyOrder(event.seat, event.order, event.say, event.text,
        event.scripted)
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the orders alone.
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.week >= 0:
    result["week"] = %event.week
  case event.kind
  of evStart:
    discard
  of evWeek:
    result["demand"] = %event.demand
    var stages = newJArray()
    for stage in event.stages:
      stages.add(stageJson(stage))
    result["stages"] = stages
  of evOrder:
    result["seat"] = %event.seat
    result["stage"] = %event.stage
    result["order"] = %event.order
    if event.say.len > 0:
      result["say"] = %event.say
    result["scripted"] = %event.scripted
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    week: node{"week"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    stage: node{"stage"}.getInt(-1),
    order: node{"order"}.getInt(-1),
    say: node{"say"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    demand: node{"demand"}.getInt(-1)
  )
  if node.hasKey("stages"):
    for stage in node["stages"]:
      result.stages.add(stageFromJson(stage))
