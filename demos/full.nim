## The full pipeline under load: configureLogging with an async console
## stream, a size-rotated file, and an error-only file, plus child loggers,
## a timing block, and a 250k-message burst to exercise rotation and the
## async writer. Writes demo.log (rotated) and error.log in the current
## directory.
##
## Run:
##   nim r demos/full.nim | ./lumber --pretty

import std/strformat
import ../src/lumber
import std/[json, streams]

type
  User = object
    name: string
    age: int

configureLogging(cfg):
  cfg.outputs = @[
    LogOutput(stream: newAsyncStream(newFileStream(stdout))),
    LogOutput(stream: newRollingFileStream("demo.log", maxBytes = 1_000_000, maxFiles = 3)),
    LogOutput(stream: newFileStream("error.log", fmAppend), level: LogLevel.ERROR),
  ]
var logger = newLogger(extra = %* {"service": "demo-api"})
var admin = User(name: "Admin", age: 35)

logger.trace("Starting up")
logger.debug("Loading config for", admin)
var reqLogger = logger.child(extra = %* {"requestId": "req-7f3a", "userId": 42})
reqLogger.info("Server listening on port 8080")

for i in 0 ..< 250_000:
  reqLogger.info(&"Processing request {i}")
  if i mod 100 == 0:
    reqLogger.warn(&"Slow request {i}", latency=i * 3)

reqLogger.warn("Disk usage at 92%")
var dbLogger = reqLogger.child(name = "db", extra = %* {"host": "db.local", "port": 5432})

dbLogger.time("connection attempt"):
  for i in 0 ..< 1_000_000:
    discard i

dbLogger.error("Failed to connect to database")
logger.fatal("Shutting down")

shutdownLogs()
