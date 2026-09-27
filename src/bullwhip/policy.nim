## Bullwhip base-stock player policy over redacted seat observations.

import std/[json, math]

const MaxOrder = 500

proc baseStockOrder*(observation: JsonNode): int =
  let history = observation["history"]
  let seat = observation["seat"]
  var forecast = 4.0
  var onOrder = 8
  for index in 0 ..< history.len:
    let week = history[index]
    forecast = 0.1 * week["incoming"].getInt().float +
      0.9 * forecast
    let order = week["order"].getInt()
    if order >= 0:
      onOrder += order
    if index > 0:
      onOrder -= week["received"].getInt()
  result = max(0, min(MaxOrder, int(round(forecast +
    0.1 * (3.0 * forecast - seat["inventory"].getInt().float +
      seat["backlog"].getInt().float) +
    3.0 * forecast - onOrder.float))))
