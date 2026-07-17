import unittest
import std/streams
import lumber

# Compiled by the nimble test task with -d:lumberLevel=ERROR to verify
# that calls below the compile-time threshold are eliminated, including
# the time template (regression: time bypassed the gate and logged at
# any level).

doAssert CompileLogLevel == LogLevel.ERROR,
  "this test must be compiled with -d:lumberLevel=ERROR"

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

configureLogging(cfg):
  cfg.middleware = @[]
  cfg.outputs = @[Output(stream: newCaptureStream())]

test "level macros below the threshold emit nothing":
  captured.setLen(0)
  var logger = newLogger(name = "gate")
  logger.info("eliminated")
  logger.warn("eliminated")
  check captured.len == 0
  logger.error("kept")
  check captured.len == 1

test "time template below the threshold runs the body but emits nothing":
  captured.setLen(0)
  var logger = newLogger(name = "gate")
  var ran = false
  logger.time("eliminated"):  # INFO, below the ERROR threshold
    ran = true
  check ran
  check captured.len == 0
  logger.time(LogLevel.ERROR, "kept"):
    discard
  check captured.len == 1
