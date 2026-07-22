import unittest
import std/[json, os, strutils, times]
import lumber

test "nimble version matches LumberVersion":
  # Nimble requires a literal in the .nimble file, so the version exists
  # in two places; this guards against drift
  let nimblePath = if fileExists("lumber.nimble"): "lumber.nimble"
                   else: ".." / "lumber.nimble"
  var nimbleVersion = ""
  for line in readFile(nimblePath).splitLines:
    let l = line.strip()
    if l.startsWith("version"):
      nimbleVersion = l.split('"')[1]
      break
  check nimbleVersion == LumberVersion

test "utcTimestamp and utcDate match std/times rendering":
  # The log timestamp uses hand-rolled civil-from-days math (std/times
  # DateTime formatting leaks a threadvar Timezone per thread); pin it
  # to std/times across edge dates
  var epochs = @[
    0'i64,                # 1970-01-01T00:00:00
    86399,                # 1970-01-01T23:59:59
    951782400,            # 2000-02-29 leap day in a leap century
    1099180799,           # 2004-10-31 (leap year, month lengths)
    2147483647,           # 2038-01-19 32-bit rollover
    4107542399'i64,       # 2100-02-28T23:59:59, 2100 is not a leap year
  ]
  for step in 0 ..< 500:
    epochs.add int64(step) * 7_776_001 + 1  # ~90 day stride across decades
  for epoch in epochs:
    check utcTimestamp(epoch) ==
          epoch.fromUnix.utc.format("yyyy-MM-dd'T'HH:mm:ss")
    check utcDate(epoch) == epoch.fromUnix.utc.format("yyyy-MM-dd")

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
  logger.info("Here is a user", user)

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
  logger.info("msg", sideEffect())
  logger.info("event", field=sideEffect())
  check not evaluated
  logger.level = LogLevel.TRACE
  logger.error("msg", sideEffect())
  check evaluated

test "compile-time no-op for lower levels":
  # This compiles and runs but produces no output when compiled with -d:lumberLevel=INFO
  var logger = newLogger(name = "test")
  logger.trace("should appear at TRACE level")
  logger.debug("should appear at DEBUG level")

test "withLogContext adds thread-local fields":
  var logger = newLogger(name = "test")
  withLogContext(%* {"requestId": "abc-123", "userId": 42}):
    logger.info("in context")

test "withLogContext nests and restores":
  var logger = newLogger(name = "test")
  withLogContext(%* {"requestId": "abc-123"}):
    logger.info("outer")
    withLogContext(%* {"orderId": "ord-1"}):
      logger.info("inner")
    logger.info("back to outer")

test "withLogContext merges with logger extra":
  var logger = newLogger(name = "test", extra = %* {"service": "api"})
  withLogContext(%* {"requestId": "req-1"}):
    logger.info("merged")

test "withLogContext fields overridden by message fields":
  var logger = newLogger(name = "test")
  withLogContext(%* {"user": "system"}):
    logger.info("login", user="alice")
