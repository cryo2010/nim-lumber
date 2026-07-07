import unittest
import std/json
import lumber

type
  User = object
    name: string
    age: int

test "basic message":
  var logger = newLogger(name = "test")
  logger.info("Here's a message")

test "basic data message":
  var logger = newLogger(name = "test")
  logger.info(4)

test "message with interpolated argument":
  var logger = newLogger(name = "test")
  var user = User(name: "Dude", age: 40)
  logger.info("Here is a user {0}", user)

test "object argument":
  var logger = newLogger(name = "test")
  var user = User(name: "Dude", age: 40)
  logger.info(user)

test "message with extra arguments":
  var logger = newLogger(name = "test")
  logger.info("Arguments:", "foo", 5, true, %* {"foo": "bar"})

test "logger with extra fields":
  var logger = newLogger(name = "test", extra = %* {"requestId": 1234})
  logger.info("with extras")

test "default module name":
  var logger = newLogger()
  logger.info("default name test")

test "child logger inherits and merges extra":
  var parent = newLogger(name = "api", extra = %* {"requestId": "abc-123"})
  var child = parent.child(extra = %* {"userId": 42})
  child.info("child log")

test "child logger can override name":
  var parent = newLogger(name = "api")
  var child = parent.child(name = "db")
  child.info("db log")

test "child logger inherits name when not overridden":
  var parent = newLogger(name = "api")
  var child = parent.child(extra = %* {"layer": "service"})
  child.info("inherited name")

test "middleware can enrich records":
  configureLogging(cfg):
    cfg.middleware = @[]
  configureLogging(cfg):
    cfg.middleware.add proc(record: var LogRecord): bool =
      record.extra["env"] = %"test"
      true
  var logger = newLogger(name = "test")
  logger.info("enriched")
  configureLogging(cfg):
    cfg.middleware = @[]

test "middleware can suppress records":
  configureLogging(cfg):
    cfg.middleware = @[]
  configureLogging(cfg):
    cfg.middleware.add proc(record: var LogRecord): bool =
      record.level != "DEBUG"
  var logger = newLogger(name = "test")
  logger.info("should appear")
  logger.debug("should be suppressed")
  configureLogging(cfg):
    cfg.middleware = @[]

test "middleware chain runs in order":
  configureLogging(cfg):
    cfg.middleware = @[]
  configureLogging(cfg):
    cfg.middleware.add proc(record: var LogRecord): bool =
      record.message &= " [first]"
      true
  configureLogging(cfg):
    cfg.middleware.add proc(record: var LogRecord): bool =
      record.message &= " [second]"
      true
  var logger = newLogger(name = "test")
  logger.info("chained")
  configureLogging(cfg):
    cfg.middleware = @[]

test "extra accepts Nim objects":
  type Context = object
    requestId: string
    userId: int
  var logger = newLogger(name = "test", extra = Context(requestId: "req-1", userId: 7))
  logger.info("object extra")

test "child accepts Nim objects":
  type Tags = object
    env: string
  var parent = newLogger(name = "test")
  var child = parent.child(extra = Tags(env: "staging"))
  child.info("child with object extra")

test "structured message fields":
  var logger = newLogger(name = "test")
  logger.info("User logged in", user="alice", ip="10.0.0.1")

test "structured fields override logger extra":
  var logger = newLogger(name = "test", extra = %* {"user": "system"})
  logger.info("login", user="alice")

test "structured fields with no message args":
  var logger = newLogger(name = "test")
  logger.info("event", status=200, path="/api/health")

test "time block logs duration":
  var logger = newLogger(name = "test")
  logger.time("db query"):
    var sum = 0
    for i in 0 ..< 1000:
      sum += i

test "time block with custom level":
  var logger = newLogger(name = "test")
  logger.time(LogLevel.DEBUG, "slow op"):
    var sum = 0
    for i in 0 ..< 1000:
      sum += i

test "runtime-filtered calls do not evaluate arguments":
  var evaluated = false
  proc sideEffect(): string =
    evaluated = true
    "value"
  var logger = newLogger(name = "test")
  logger.level = LogLevel.ERROR
  logger.info("msg {0}", sideEffect())
  logger.info("event", field=sideEffect())
  check not evaluated
  logger.level = LogLevel.TRACE
  logger.error("msg {0}", sideEffect())
  check evaluated

test "compile-time no-op for lower levels":
  # This compiles and runs but produces no output when compiled with -d:lumberLevel=INFO
  var logger = newLogger(name = "test")
  logger.trace("should appear at TRACE level")
  logger.debug("should appear at DEBUG level")

test "withContext adds thread-local fields":
  var logger = newLogger(name = "test")
  withContext(%* {"requestId": "abc-123", "userId": 42}):
    logger.info("in context")

test "withContext nests and restores":
  var logger = newLogger(name = "test")
  withContext(%* {"requestId": "abc-123"}):
    logger.info("outer")
    withContext(%* {"orderId": "ord-1"}):
      logger.info("inner")
    logger.info("back to outer")

test "withContext merges with logger extra":
  var logger = newLogger(name = "test", extra = %* {"service": "api"})
  withContext(%* {"requestId": "req-1"}):
    logger.info("merged")

test "withContext fields overridden by message fields":
  var logger = newLogger(name = "test")
  withContext(%* {"user": "system"}):
    logger.info("login", user="alice")
