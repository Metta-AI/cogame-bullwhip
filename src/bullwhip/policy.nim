## Bullwhip base-stock player policy over redacted seat observations.

import std/[json, math]

const MaxOrder = 500

const DefaultOperatorPrompt* = """
Run a base-stock policy and never panic. Each week estimate demand as a
smoothed average of your incoming orders (weight the last few weeks most).
Keep a written tally in your notes of everything you have ordered in the
last three weeks that has not yet arrived - that is your supply line - and
SUBTRACT it before deciding: order = forecast + (target inventory of about
three weeks of demand - inventory + backlog)/2 + (three weeks of demand -
supply line)/2, never below zero. When a backlog appears, do not order the
whole backlog again; most of it is already on its way. When demand steps
up, raise your forecast gradually, not to the first big number you see.
If you can talk, tell your neighbours your honest forecast and what you
have on order, and believe a neighbour's stated forecast only if it matches
what they then actually order.
"""


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
