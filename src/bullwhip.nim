## Bullwhip entrypoint: reads the Coworld runtime contract and starts either
## a live episode server or a replay viewer server.

import
  std/[json, sysrand],
  bitworld/runtime,
  bullwhip/server,
  bullwhip/sim

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(BullwhipError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  let runtimeConfig = readRuntimeConfig()

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    var config = defaultGameConfig()
    config.update(runtimeConfig.config)
    if not seedPinned(runtimeConfig.config):
      ## An unpinned seed is randomized so the role assignment, the demand
      ## script, and the aliases are not precomputable.
      config.seed = randomSeed()
      echo "bullwhip: seed not pinned; randomized"
    ## Fit the cap AFTER the seed is settled, so a pinned seed reproduces
    ## the episode exactly.
    config = sampleEpisode(config)
    echo "bullwhip: seats=", config.players.len,
      " weeks=", config.weeks,
      " talk=", config.talk
    runGameServer(config, runtimeConfig)
