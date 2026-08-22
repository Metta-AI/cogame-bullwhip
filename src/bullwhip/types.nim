import std/[json, strutils]

type
  BullwhipError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    weeks*: int           ## weeks of orders in the episode
    talk*: bool           ## seats may send a short message to their neighbours
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  StageState* = object
    ## One supply-chain stage as observed at the start of a week.
    inventory*: int
    backlog*: int
    received*: int    ## the shipment that arrived this week
    incoming*: int    ## the order received this week (retailer: customer demand)
    shipped*: int     ## what went downstream this week
    shipPipe*: array[2, int] ## in transit to this stage; [0] arrives next week
    costWeek*: float
    costTotal*: float
    lastOrder*: int   ## the order placed last week (-1 before the first)

  EventKind* = enum
    evStart = "start"
    evWeek = "week"
    evOrder = "order"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    week*: int           ## week/order: the observed week; end: weeks played; start: -1
    seat*: int           ## order: the ordering seat; -1 otherwise
    stage*: int          ## order: the seat's stage; -1 otherwise
    order*: int          ## order: units ordered; -1 otherwise
    say*: string         ## order: message to the neighbours ("" when silent)
    scripted*: bool      ## order: decided by the scripted baseline
    text*: string        ## order: the seat's notes after the reply; end: reason
    demand*: int         ## week: customer demand this week; -1 otherwise
    stages*: seq[StageState] ## week: the four stage states, by stage

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    weeks: 36,
    talk: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 60
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(BullwhipError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("weeks"):
    config.weeks = node["weeks"].getInt()
  if node.hasKey("talk"):
    config.talk = node["talk"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.weeks < 4:
    raise newException(BullwhipError, "weeks must be at least 4")
