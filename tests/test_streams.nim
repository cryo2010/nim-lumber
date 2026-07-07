import unittest
import std/[os, streams, strutils]
import lumber

let asyncLog = getTempDir() / "lumber_test_async.log"

test "async stream flushes when its queue drains, without close":
  removeFile(asyncLog)
  let async = newAsyncStream(newFileStream(asyncLog, fmWrite))
  configureLogging(cfg):
    cfg.middleware = @[]
    cfg.outputs = @[Output(stream: async)]
  var logger = newLogger(name = "test")
  for i in 0 ..< 100:
    logger.info("message {0}", i)
  # Give the writer thread time to drain and flush; no close() here, so
  # the data on disk proves the drain-flush happened
  sleep(200)
  var lines = 0
  for line in asyncLog.lines:
    if line.len > 0:
      check line.startsWith("{")
      inc lines
  check lines == 100
  async.close()
  removeFile(asyncLog)
  configureLogging(cfg):
    cfg.outputs = @[Output(stream: newFileStream(stdout))]
