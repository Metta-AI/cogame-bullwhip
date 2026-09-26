## Bullwhip player: prompt or scripted decisions from seat observations.
##
## Connects to the game and acts on each redacted seat observation. The
## operator prompt and scripted logic stay inside this policy.
##
## PLAYER_SCRIPTED=basestock (or 1) chooses the base-stock baseline;
## PLAYER_SCRIPTED=mirror orders the incoming quantity.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <bullwhip-image> --name my-bullwhip \
##     --run /bin/bullwhip-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  bullwhip/policy,
  whisky

const DefaultPrompt = """
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

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt

  proc register(): string =
    if scripted.len > 0:
      $ %*{"type": "register", "control": "external"}
    else:
      $ %*{"type": "prompt", "prompt": prompt, "scripted": ""}

  echo "bullwhip player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(register())
  echo "bullwhip player: registered (", prompt.len, " prompt chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "bullwhip player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    let payload = parseJson(message.data)
    if scripted.len > 0 and payload{"type"}.getStr() == "observation":
      let observation = payload["observation"]
      let order =
        if scripted == "mirror": observation["seat"]["incoming"].getInt()
        else: baseStockOrder(observation)
      let action = %*{"order": order, "say": "", "notes": ""}
      socket.send($ %*{"type": "action", "week": payload["week"],
        "action": action})
      continue
    try:
      case payload{"type"}.getStr()
      of "welcome":
        echo "bullwhip player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " (", payload{"role"}.getStr(), ")"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(register())
      of "final":
        echo "bullwhip player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "bullwhip player: ignoring bad frame: ", error.msg
  socket.close()
