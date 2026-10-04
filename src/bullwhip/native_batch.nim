## Simultaneous native requests with byte ownership across worker threads.
## The game owns prompts, parsing, retries and action acceptance.

import std/[base64, json, monotimes, options, strutils]
import bitworld/native_http

type
  NativeRequest* = object
    url*: string
    headers*: HttpHeaders
    body*: string
  NativeResult* = object
    response*: NativeHttpResponse
    receivedAt*: MonoTime
  NativeJob = object
    requestBytes, responseBytes: pointer
    requestLen, responseLen: int
    deadline, receivedAt: MonoTime

proc runRequest(job: ptr NativeJob) {.thread.} =
  var bytes = newString(job.requestLen)
  if bytes.len > 0: copyMem(bytes[0].addr, job.requestBytes, bytes.len)
  let request = parseJson(bytes)
  var headers: HttpHeaders
  for pair in request["headers"]:
    headers.add((pair[0].getStr(), pair[1].getStr()))
  let response = performNativePost(request["url"].getStr(), headers,
    request["body"].getStr(), job.deadline)
  job.receivedAt = getMonoTime()
  let wire = $(%*{
    "kind": $response.kind,
    "status": response.httpStatus,
    "headers_b64": encode(response.headerBytes),
    "body_b64": encode(response.bodyBytes),
    "complete": response.transferComplete,
    "reader_joined": response.responseReaderJoined,
    "latency_ms": response.latencyMs,
    "error": response.error
  })
  job.responseLen = wire.len
  job.responseBytes = allocShared(wire.len)
  doAssert job.responseBytes != nil
  if wire.len > 0: copyMem(job.responseBytes, wire[0].unsafeAddr, wire.len)

proc performNativeBatch*(requests: seq[NativeRequest],
    deadline: MonoTime): seq[NativeResult] =
  ## Every request starts before any worker is joined. The deadline is shared.
  var jobs = newSeq[NativeJob](requests.len)
  var threads = newSeq[Thread[ptr NativeJob]](requests.len)
  var created = 0
  var joined = false
  try:
    for index, request in requests:
      var headers = newJArray()
      for (name, value) in request.headers: headers.add(%*[name, value])
      let wire = $(%*{"url": request.url, "headers": headers,
        "body": request.body})
      jobs[index].requestLen = wire.len
      jobs[index].requestBytes = allocShared(wire.len)
      doAssert jobs[index].requestBytes != nil
      copyMem(jobs[index].requestBytes, wire[0].unsafeAddr, wire.len)
      jobs[index].deadline = deadline
      createThread(threads[index], runRequest, jobs[index].addr)
      inc created
    for index in 0 ..< created: joinThread(threads[index])
    joined = true
    for job in jobs:
      var bytes = newString(job.responseLen)
      if bytes.len > 0: copyMem(bytes[0].addr, job.responseBytes, bytes.len)
      let response = parseJson(bytes)
      result.add(NativeResult(receivedAt: job.receivedAt, response: NativeHttpResponse(
        kind: parseEnum[NativeHttpKind](response["kind"].getStr()),
        httpStatus: (if response["status"].kind == JNull: none(int)
          else: some(response["status"].getInt())),
        headerBytes: decode(response["headers_b64"].getStr()),
        bodyBytes: decode(response["body_b64"].getStr()),
        transferComplete: response["complete"].getBool(),
        responseReaderJoined: (if response["reader_joined"].kind == JNull:
          none(bool) else: some(response["reader_joined"].getBool())),
        latencyMs: (if response["latency_ms"].kind == JNull: none(float)
          else: some(response["latency_ms"].getFloat())),
        error: response["error"].getStr()
      )))
  finally:
    if not joined:
      for index in 0 ..< created: joinThread(threads[index])
    for job in jobs:
      if job.requestBytes != nil: deallocShared(job.requestBytes)
      if job.responseBytes != nil: deallocShared(job.responseBytes)
