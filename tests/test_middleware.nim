import unittest
import std/[streams, os]
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
