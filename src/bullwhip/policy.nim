## Bullwhip player policies consume a redacted observation and return an
## action. Model calls and prompts live here, outside the game simulation.

import std/[json, math, os, strutils]
import curly

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

proc chooseOrder*(observation: JsonNode): int =
  let seat = observation["seat"]
  let base = baseStockOrder(observation)
  var criteria = newJObject()
  for proposal in [0, seat["incoming"].getInt(), base - 8,
      base - 4, base - 2, base, base + 2, base + 4, base + 8]:
    let order = max(0, min(MaxOrder, proposal))
    criteria[$order] = %("Order " & $order & " units upstream this week")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let directKey = getEnv("TYPESAFE_API_KEY").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = "typesafe/jev-1.13"
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = directKey
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Jev player has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{
    "model": model,
    "state": "You are the " & observation["role"].getStr() &
      " in Bullwhip. Minimize your own inventory and backlog costs across " &
      "the remaining weeks. Shipments take two weeks and orders take a " &
      "week to reach your supplier. Your seat observation is:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose an order that accounts for demand, inventory, backlog, and orders still in transit.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  result = parseInt(selected)
  echo "bullwhip Jev player: order ", result,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
