import unittest
import std/[streams, os, json, strutils, re]
import lumber
import lumber/middleware

# Capture output to a string for assertions
var captured: seq[string] = @[]

type CaptureStream = ref object of Stream

proc captureWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    var data = newString(bufLen)
    copyMem(addr data[0], buffer, bufLen)
    if data.len > 0 and data[0] == '{':
      captured.add(data)

proc captureFlush(s: Stream) {.nimcall, gcsafe.} = discard
proc captureClose(s: Stream) {.nimcall, gcsafe.} = discard

proc newCaptureStream(): CaptureStream =
  new(result)
  result.writeDataImpl = captureWrite
  result.flushImpl = captureFlush
  result.closeImpl = captureClose

template setupTest() =
  captured.setLen(0)
  clearMiddleware()
  outputs = @[Output(stream: newCaptureStream())]

test "rate limiter allows burst then suppresses":
  setupTest()
  use newRateLimiter(window = 10.0, maxBurst = 3)
  var logger = newLogger(name = "test")
  for i in 0 ..< 10:
    logger.info("msg")
  check captured.len == 3

test "rate limiter resets after window":
  setupTest()
  use newRateLimiter(window = 0.05, maxBurst = 2)
  var logger = newLogger(name = "test")
  # Same line in a loop — all share one key
  for i in 0 ..< 5:
    logger.info("msg")
  check captured.len == 2
  # Wait for window to expire
  sleep(100)
  captured.setLen(0)
  for i in 0 ..< 3:
    logger.info("msg")
  check captured.len == 2

test "sampler logs 1 in N":
  setupTest()
  use newSampler(rate = 5)
  var logger = newLogger(name = "test")
  for i in 0 ..< 20:
    logger.info("msg")
  # Should log messages 1, 6, 11, 16 (counter mod 5 == 1)
  check captured.len == 4

test "level sampler passes high levels through":
  setupTest()
  use newLevelSampler(level = LogLevel.DEBUG, rate = 100)
  var logger = newLogger(name = "test")
  # ERROR should always pass
  for i in 0 ..< 10:
    logger.error("important")
  check captured.len == 10

test "level sampler samples low levels":
  setupTest()
  use newLevelSampler(level = LogLevel.DEBUG, rate = 5)
  var logger = newLogger(name = "test")
  for i in 0 ..< 20:
    logger.debug("noisy")
  # Should sample: 1, 6, 11, 16
  check captured.len == 4

test "level sampler combines both behaviors":
  setupTest()
  use newLevelSampler(level = LogLevel.INFO, rate = 10)
  var logger = newLogger(name = "test")
  for i in 0 ..< 20:
    logger.info("sampled")
  for i in 0 ..< 5:
    logger.error("always")
  # INFO: 2 sampled (1, 11), ERROR: 5 always
  check captured.len == 7

test "redactor replaces specified keys":
  setupTest()
  use newRedactor(@["password", "token"])
  var logger = newLogger(name = "test")
  logger.info("login", password="secret123", token="abc-xyz", user="alice")
  check captured.len == 1
  let j = parseJson(captured[0])
  check j["extra"]["password"].getStr() == "[REDACTED]"
  check j["extra"]["token"].getStr() == "[REDACTED]"
  check j["extra"]["user"].getStr() == "alice"

test "redactor ignores missing keys":
  setupTest()
  use newRedactor(@["password"])
  var logger = newLogger(name = "test")
  logger.info("no password here", user="alice")
  check captured.len == 1
  let j = parseJson(captured[0])
  check j["extra"]["user"].getStr() == "alice"
  check not j["extra"].hasKey("password")

test "redactor uses custom placeholder":
  setupTest()
  use newRedactor(@["ssn"], placeholder = "***")
  var logger = newLogger(name = "test")
  logger.info("record", ssn="123-45-6789")
  let j = parseJson(captured[0])
  check j["extra"]["ssn"].getStr() == "***"

test "pattern redactor scrubs matching values":
  setupTest()
  use newPatternRedactor(re"\d{4}-\d{4}-\d{4}-\d{4}")
  var logger = newLogger(name = "test")
  logger.info("Payment with card 4111-1111-1111-1111 processed", cardNum="4111-1111-1111-1111")
  check captured.len == 1
  let j = parseJson(captured[0])
  let msg = j["message"].getStr()
  check strutils.find(msg, "4111") == -1
  check strutils.find(msg, "[REDACTED]") >= 0
  check j["extra"]["cardNum"].getStr() == "[REDACTED]"

test "pattern redactor leaves non-matching values intact":
  setupTest()
  use newPatternRedactor(re"\d{4}-\d{4}-\d{4}-\d{4}")
  var logger = newLogger(name = "test")
  logger.info("Hello world", user="alice")
  check captured.len == 1
  let j = parseJson(captured[0])
  check j["message"].getStr() == "Hello world"
  check j["extra"]["user"].getStr() == "alice"
