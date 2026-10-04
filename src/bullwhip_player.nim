## Bullwhip reference player delivers one frozen prompt or scripted registration.
## The game owns all native model requests and source-scripted order decisions.

import
  std/[json, math, monotimes, os, strutils, times],
  bitworld/[native_stop, native_websocket],
  bullwhip/policy

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultOperatorPrompt
  let scriptedEnv = getEnv("PLAYER_SCRIPTED").strip()
  ## Scripted registrations select the game-owned private-view policy.
  let scripted =
    if scriptedEnv.len == 0 or scriptedEnv.toLowerAscii() in
        ["0", "false", "no"]:
      ""
    elif scriptedEnv.toLowerAscii() in ["1", "true", "yes"]:
      "basestock"
    else:
      scriptedEnv.toLowerAscii()

  let timeout = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "1200"))
  if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
    quit("player timeout must be finite and positive", 1)
  let started = getMonoTime()
  let deadline = started + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
  let connection = connectNativeWebSocket(url,
    min(deadline, started + initDuration(seconds = 30)), 16 * 1024 * 1024)
  case connection.kind
  of wsInterrupted, wsDeadline: quit(0)
  of wsReady: discard
  else: quit("player connection failed", 1)
  let socket = connection.socket
  var registered = false
  try:
    while true:
      let received = receiveNativeText(socket, deadline)
      case received.kind
      of wsClosed, wsInterrupted, wsDeadline: break
      of wsMessage: discard
      else: raise newException(ValueError, "player transport failed")
      let payload = parseJson(received.data)
      if payload.kind != JObject or not payload.hasKey("type") or payload["type"].kind != JString:
        raise newException(ValueError, "invalid player protocol packet")
      case payload["type"].getStr()
      of "welcome":
        if registered: raise newException(ValueError, "duplicate player welcome")
        let registration = $ %*{"type": "prompt", "prompt": prompt,
          "scripted": (if scripted.len > 0: %scripted else: %false)}
        let sent = sendNativeText(socket, registration, deadline)
        case sent.kind
        of wsInterrupted, wsDeadline: break
        of wsReady: registered = true
        else: raise newException(ValueError, "player registration failed")
      of "state": discard
      of "final": break
      else: raise newException(ValueError, "unexpected player protocol packet")
  finally:
    closeNativeWebSocket(socket)
