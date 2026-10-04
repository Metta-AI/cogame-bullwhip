## CPU fixture probe for owned parallel HTTP requests; no training authority.
import std/[base64, json, monotimes, options, os, strutils, times]
import bitworld/[native_http, native_stop]
import bullwhip/native_batch

when isMainModule:
  installNativeStopHandlers()
  let args = commandLineParams()
  doAssert args.len == 3
  let start = getMonoTime()
  let deadline = start + initDuration(milliseconds = parseInt(args[2]))
  var requests: seq[NativeRequest]
  for seat in 0 ..< 4:
    var headers: HttpHeaders
    headers["content-type"] = "application/json"
    headers["X-Coworld-Player-Slot"] = $seat
    requests.add(NativeRequest(url: args[1], headers: headers,
      body: $(%*{"seat": seat})))
  let responses = performNativeBatch(requests, deadline)
  var rows = newJArray()
  for received in responses:
    let response = received.response
    rows.add(%*{"kind": $response.kind, "status": response.httpStatus,
      "body_b64": encode(response.bodyBytes),
      "headers_b64": encode(response.headerBytes),
      "complete": response.transferComplete,
      "reader_joined": response.responseReaderJoined,
      "received_elapsed_ms": (received.receivedAt - start).inMilliseconds})
  writeFile(args[0], $(%*{"responses": rows,
    "elapsed_ms": (getMonoTime() - start).inMilliseconds,
    "interrupted": interruptionRequested()}))
