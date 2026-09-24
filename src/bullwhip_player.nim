## Bullwhip player: a policy is a prompt, a Jev choice policy, or scripted.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default Beer Game strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server.
##
## PLAYER_SCRIPTED=basestock (or 1) registers the seat as the built-in
## base-stock baseline instead; PLAYER_SCRIPTED=mirror as the pass-through
## baseline. The server plays those deterministically, no LLM.
## PLAYER_JEV=1 asks the server to rank legal orders with Jev System One.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <bullwhip-image> --name my-bullwhip \
##     --run /bin/bullwhip-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
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
  let jev = getEnv("PLAYER_JEV") == "1"
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0 and not jev:
    prompt = DefaultPrompt

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted,
      "jev": jev}

  echo "bullwhip player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "bullwhip player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "bullwhip player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "bullwhip player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " (", payload{"role"}.getStr(), ")"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "final":
        echo "bullwhip player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "bullwhip player: ignoring bad frame: ", error.msg
  socket.close()
