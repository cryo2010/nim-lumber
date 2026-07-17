import unittest
import std/[streams, os, json, strutils]
import regex
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
  configureLogging(cfg):
    cfg.middleware = @[]
    cfg.outputs = @[Output(stream: newCaptureStream())]

test "configureLogging commits middleware and outputs atomically":
  captured.setLen(0)
  configureLogging(cfg):
    cfg.outputs = @[Output(stream: newCaptureStream())]
    cfg.middleware = @[]
    cfg.middleware.add proc(record: var LogRecord): bool =
      record.extra["configured"] = %true
      true
  var logger = newLogger(name = "test")
  logger.info("hello")
  check captured.len == 1
  let j = parseJson(captured[0])
  check j["extra"]["configured"].getBool()

test "configureLogging commits nothing when the block raises":
  setupTest()
  expect ValueError:
    configureLogging(cfg):
      # Would suppress everything if it were committed
      cfg.middleware.add proc(record: var LogRecord): bool = false
      raise newException(ValueError, "boom")
  var logger = newLogger(name = "test")
  logger.info("still logged")
  check captured.len == 1

test "reentrant configureLogging raises a Defect instead of deadlocking":
  setupTest()
  expect Defect:
    configureLogging(outer):
      configureLogging(inner):
        discard inner
  # Configuration still works after the Defect
  configureLogging(cfg):
    cfg.outputs.add Output(stream: newCaptureStream())
  check outputs().len == 2

test "successive configureLogging calls compose":
  setupTest()
  configureLogging(cfg):
    cfg.outputs.add Output(stream: newCaptureStream())
  configureLogging(cfg):
    cfg.outputs.add Output(stream: newCaptureStream())
  # Each call started from the previous committed state
  check outputs().len == 3

test "records without fields carry no extra even with middleware":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add proc(record: var LogRecord): bool = true
  var logger = newLogger(name = "test")
  logger.info("plain")
  logger.info("with", field=1)
  check captured.len == 2
  check not parseJson(captured[0]).hasKey("extra")
  check parseJson(captured[1])["extra"]["field"].getInt() == 1

test "scratch extra is not shared between records":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add proc(record: var LogRecord): bool =
      if record.message == "mark":
        record.extra["marked"] = %true
      true
  var logger = newLogger(name = "test")
  logger.info("plain one")
  logger.info("mark")
  logger.info("plain two")
  check captured.len == 3
  check not parseJson(captured[0]).hasKey("extra")
  check parseJson(captured[1])["extra"]["marked"].getBool()
  check not parseJson(captured[2]).hasKey("extra")

test "positional arguments are appended and braces are never interpreted":
  setupTest()
  var logger = newLogger(name = "test")
  logger.info("Values:", 1, 2, 3)
  logger.info("literal {0} braces {}", "x")
  check parseJson(captured[0])["message"].getStr() == "Values: 1 2 3"
  check parseJson(captured[1])["message"].getStr() == "literal {0} braces {} x"

test "exception alongside a field named error does not crash":
  # Regression: addExceptionFields assumed an existing "error" key always
  # had a companion "errorType" and raised KeyError for plain kwargs
  setupTest()
  var logger = newLogger(name = "test")
  let e = newException(ValueError, "boom")
  logger.error("failed", error="disk full", cause=e)
  check captured.len == 1
  let errs = parseJson(captured[0])["extra"]["errors"]
  check errs.kind == JArray
  check errs.len == 2
  check errs[0]["error"].getStr() == "disk full"
  check errs[1]["error"].getStr() == "boom"
  check errs[1]["errorType"].getStr() == "ValueError"

test "two exceptions become an errors array":
  setupTest()
  var logger = newLogger(name = "test")
  logger.error("failed", newException(ValueError, "first"), newException(IOError, "second"))
  check captured.len == 1
  let errs = parseJson(captured[0])["extra"]["errors"]
  check errs.len == 2
  check errs[0]["errorType"].getStr() == "ValueError"
  check errs[1]["errorType"].getStr() == "IOError"

test "time block measures wall time, not CPU time":
  setupTest()
  var logger = newLogger(name = "test")
  logger.time("sleepy"):
    sleep(30)
  check captured.len == 1
  let ms = parseJson(captured[0])["extra"]["duration_ms"].getFloat()
  check ms >= 25.0

test "time template reports the same filename form as the level macros":
  # Regression: time used the bare instantiationInfo filename while the
  # macros emit project-relative paths, breaking filename filtering
  setupTest()
  var logger = newLogger(name = "test")
  logger.info("from macro")
  logger.time("from time"):
    discard
  check captured.len == 2
  check parseJson(captured[0])["filename"].getStr() ==
        parseJson(captured[1])["filename"].getStr()

test "rate limiter allows burst then suppresses":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newRateLimiter(window = 10.0, maxBurst = 3)
  var logger = newLogger(name = "test")
  for i in 0 ..< 10:
    logger.info("msg")
  check captured.len == 3

test "rate limiter resets after window":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newRateLimiter(window = 0.05, maxBurst = 2)
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

test "rate limiter reports suppressed count":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newRateLimiter(window = 0.05, maxBurst = 2)
  var logger = newLogger(name = "test")
  # Single loop: first 5 iterations emit (2 pass, 3 suppressed),
  # then sleep, then 3 more from the same source line
  var slept = false
  for i in 0 ..< 8:
    if i == 5 and not slept:
      sleep(100)
      captured.setLen(0)
      slept = true
    logger.info("msg")
  # After reset: 2 pass (maxBurst), first one carries suppressed=3
  check captured.len == 2
  let j = parseJson(captured[0])
  check j["extra"]["suppressed"].getInt() == 3

test "middleware mutation does not leak into logger extra":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add proc(record: var LogRecord): bool =
      record.extra["injected"] = %"per-message"
      true
  var logger = newLogger(name = "test", extra = %* {"requestId": "abc"})
  logger.info("first")
  logger.info("second")
  check logger.extra == %* {"requestId": "abc"}
  check captured.len == 2
  for line in captured:
    let j = parseJson(line)
    check j["extra"]["injected"].getStr() == "per-message"
    check j["extra"]["requestId"].getStr() == "abc"

test "rate limiter suppressed count does not stick to logger extra":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newRateLimiter(window = 0.05, maxBurst = 1)
  var logger = newLogger(name = "test", extra = %* {"service": "api"})
  # Single source line: emit, drop 3, then emit again after the window
  # so the suppressed count attaches to that second emit
  for i in 0 ..< 5:
    if i == 4:
      sleep(100)
    logger.info("msg")
  sleep(100)  # new window, no pending drops
  logger.info("clean")
  check not logger.extra.hasKey("suppressed")
  check captured.len == 3
  let withCount = parseJson(captured[1])
  check withCount["extra"]["suppressed"].getInt() == 3
  let last = parseJson(captured[2])
  check not last["extra"].hasKey("suppressed")

test "sampler logs 1 in N":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newSampler(rate = 5)
  var logger = newLogger(name = "test")
  for i in 0 ..< 20:
    logger.info("msg")
  # Should log messages 1, 6, 11, 16 (counter mod 5 == 1)
  check captured.len == 4

test "sampler with rate 1 logs everything":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newSampler(rate = 1)
  var logger = newLogger(name = "test")
  for i in 0 ..< 10:
    logger.info("msg")
  check captured.len == 10

test "level sampler with rate 1 logs everything":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newLevelSampler(level = LogLevel.DEBUG, rate = 1)
  var logger = newLogger(name = "test")
  for i in 0 ..< 10:
    logger.debug("msg")
  check captured.len == 10

test "level sampler passes high levels through":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newLevelSampler(level = LogLevel.DEBUG, rate = 100)
  var logger = newLogger(name = "test")
  # ERROR should always pass
  for i in 0 ..< 10:
    logger.error("important")
  check captured.len == 10

test "level sampler samples low levels":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newLevelSampler(level = LogLevel.DEBUG, rate = 5)
  var logger = newLogger(name = "test")
  for i in 0 ..< 20:
    logger.debug("noisy")
  # Should sample: 1, 6, 11, 16
  check captured.len == 4

test "level sampler combines both behaviors":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newLevelSampler(level = LogLevel.INFO, rate = 10)
  var logger = newLogger(name = "test")
  for i in 0 ..< 20:
    logger.info("sampled")
  for i in 0 ..< 5:
    logger.error("always")
  # INFO: 2 sampled (1, 11), ERROR: 5 always
  check captured.len == 7

test "redactor replaces specified keys":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newRedactor(@["password", "token"])
  var logger = newLogger(name = "test")
  logger.info("login", password="secret123", token="abc-xyz", user="alice")
  check captured.len == 1
  let j = parseJson(captured[0])
  check j["extra"]["password"].getStr() == "[REDACTED]"
  check j["extra"]["token"].getStr() == "[REDACTED]"
  check j["extra"]["user"].getStr() == "alice"

test "redactor ignores missing keys":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newRedactor(@["password"])
  var logger = newLogger(name = "test")
  logger.info("no password here", user="alice")
  check captured.len == 1
  let j = parseJson(captured[0])
  check j["extra"]["user"].getStr() == "alice"
  check not j["extra"].hasKey("password")

test "redactor uses custom placeholder":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newRedactor(@["ssn"], placeholder = "***")
  var logger = newLogger(name = "test")
  logger.info("record", ssn="123-45-6789")
  let j = parseJson(captured[0])
  check j["extra"]["ssn"].getStr() == "***"

test "pattern redactor scrubs matching values":
  setupTest()
  configureLogging(cfg):
    cfg.middleware.add newPatternRedactor(re2"\d{4}-\d{4}-\d{4}-\d{4}")
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
  configureLogging(cfg):
    cfg.middleware.add newPatternRedactor(re2"\d{4}-\d{4}-\d{4}-\d{4}")
  var logger = newLogger(name = "test")
  logger.info("Hello world", user="alice")
  check captured.len == 1
  let j = parseJson(captured[0])
  check j["message"].getStr() == "Hello world"
  check j["extra"]["user"].getStr() == "alice"
