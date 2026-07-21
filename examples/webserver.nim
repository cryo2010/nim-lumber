## Request-scoped logging in an async HTTP server: each request gets a
## withLogContext block carrying requestId/method/path, so every log line
## inside the handler is tagged automatically. Async handlers all run on
## one thread, so this composes with thread-local context.
##
## Run (then generate traffic with examples/webclient.nim or curl):
##   nim r examples/webserver.nim | ./lumber --pretty
##   curl http://localhost:8080/api/user

import std/[asynchttpserver, asyncdispatch, json, random, strutils, strformat]
import ../src/lumber

randomize()

var logger = newLogger(name = "server")

const users = ["alice", "bob", "charlie", "dana", "eve"]

proc handler(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    let user = users[rand(users.high)]
    let reqId = "req-" & toHex(rand(0xFFFF), 4).toLowerAscii()

    withLogContext(%* {"requestId": reqId, "method": $req.reqMethod, "path": req.url.path}):
      logger.info(&"{user} logged in", userId=user, ip="127.0.0.1")

      # Simulate occasional slow requests
      if rand(10) == 0:
        logger.warn("Slow response", latency=rand(200..500))

      await req.respond(Http200, """{"status":"ok","user":"""" & user & """"}""",
        newHttpHeaders([("Content-Type", "application/json")]))

proc main() {.async.} =
  var server = newAsyncHttpServer()
  logger.info("Listening on port 8080")
  server.listen(Port(8080))
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handler)
    else:
      await sleepAsync(500)

asyncCheck main()
runForever()
