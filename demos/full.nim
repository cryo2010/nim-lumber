import ../src/lumber
import std/[json, streams]

type
  User = object
    name: string
    age: int

configureLogging(cfg):
  cfg.outputs = @[
    Output(stream: newAsyncStream(newFileStream(stdout))),
    Output(stream: newRollingFileStream("demo.log", maxBytes = 1_000_000, maxFiles = 3)),
    Output(stream: newFileStream("error.log", fmAppend), level: LogLevel.ERROR),
  ]
var logger = newLogger(extra = %* {"service": "demo-api"})
var admin = User(name: "Admin", age: 35)

logger.trace("Starting up")
logger.debug("Loading config for {0}", admin)
var reqLogger = logger.child(extra = %* {"requestId": "req-7f3a", "userId": 42})
reqLogger.info("Server listening on port {0}", 8080)

for i in 0 ..< 250_000:
  reqLogger.info("Processing request {0}", i)
  if i mod 100 == 0:
    reqLogger.warn("Slow request {0}, latency={1}ms", i, i * 3)

reqLogger.warn("Disk usage at {0}%", 92)
var dbLogger = reqLogger.child(name = "db", extra = %* {"host": "db.local", "port": 5432})

dbLogger.time("connection attempt"):
  for i in 0 ..< 1_000_000:
    discard i

dbLogger.error("Failed to connect to database")
logger.fatal("Shutting down")

for o in outputs:
  o.stream.close()
