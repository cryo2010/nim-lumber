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
  clearMiddleware()
  use proc(record: var LogRecord): bool =
    if record.extra.isNil:
      record.extra = newJObject()
    record.extra["env"] = %"test"
    true
  var logger = newLogger(name = "test")
  logger.info("enriched")
  clearMiddleware()

test "middleware can suppress records":
  clearMiddleware()
  use proc(record: var LogRecord): bool =
    record.level != "DEBUG"
  var logger = newLogger(name = "test")
  logger.info("should appear")
  logger.debug("should be suppressed")
  clearMiddleware()

test "middleware chain runs in order":
  clearMiddleware()
  use proc(record: var LogRecord): bool =
    record.message &= " [first]"
    true
  use proc(record: var LogRecord): bool =
    record.message &= " [second]"
    true
  var logger = newLogger(name = "test")
  logger.info("chained")
  clearMiddleware()

test "compile-time no-op for lower levels":
  # This compiles and runs but produces no output when compiled with -d:lumberLevel=INFO
  var logger = newLogger(name = "test")
  logger.trace("should appear at TRACE level")
  logger.debug("should appear at DEBUG level")
