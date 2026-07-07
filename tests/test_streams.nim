import unittest
import std/[os, streams, strutils]
import lumber

# -- Size-based rotation --

test "rolling file stream rotates at the size limit and keeps maxFiles backups":
  let base = getTempDir() / "lumber_test_roll.log"
  for p in [base, base & ".1", base & ".2", base & ".3"]:
    removeFile(p)
  let s = newRollingFileStream(base, maxBytes = 200, maxFiles = 2)
  for i in 0 ..< 20:
    s.writeLine(alignLeft("line " & $i, 40))  # 41 bytes per line
  s.close()
  check fileExists(base)
  check fileExists(base & ".1")
  check fileExists(base & ".2")
  check not fileExists(base & ".3")  # maxFiles = 2 caps the backups
  # No file may exceed the limit by more than one line
  check getFileSize(base) <= 200 + 41
  check getFileSize(base & ".1") <= 200 + 41
  # The newest data lives in the base file
  check readFile(base).contains("line 19")
  for p in [base, base & ".1", base & ".2"]:
    removeFile(p)

test "rolling file stream appends to an existing file on reopen":
  let base = getTempDir() / "lumber_test_roll2.log"
  removeFile(base)
  var s = newRollingFileStream(base, maxBytes = 10_000)
  s.writeLine("first")
  s.close()
  s = newRollingFileStream(base, maxBytes = 10_000)
  s.writeLine("second")
  s.close()
  let content = readFile(base)
  check content.contains("first")
  check content.contains("second")

# -- Time-based rotation --

test "daily file stream appends to an existing file on reopen":
  let base = getTempDir() / "lumber_test_daily.log"
  removeFile(base)
  var s = newDailyFileStream(base)
  s.writeLine("first")
  s.close()
  s = newDailyFileStream(base)
  s.writeLine("second")
  s.close()
  let content = readFile(base)
  check content.contains("first")
  check content.contains("second")
  removeFile(base)

# -- Buffered stream (hybrid flush strategy) --

test "buffered stream holds writes until the buffer fills":
  let path = getTempDir() / "lumber_test_buf.log"
  removeFile(path)
  let buf = newBufferedStream(newFileStream(path, fmWrite),
                              maxSize = 128, flushIntervalMs = 0)
  buf.write("x".repeat(100))
  check getFileSize(path) == 0  # below maxSize: still buffered
  buf.write("y".repeat(100))    # 200 >= 128: flushed
  check getFileSize(path) == 200
  buf.close()
  removeFile(path)

test "buffered stream flushes on close":
  let path = getTempDir() / "lumber_test_buf2.log"
  removeFile(path)
  let buf = newBufferedStream(newFileStream(path, fmWrite),
                              maxSize = 4096, flushIntervalMs = 0)
  buf.write("pending")
  check getFileSize(path) == 0
  buf.close()
  check readFile(path) == "pending"
  removeFile(path)

test "buffered stream flushes after the interval elapses":
  let path = getTempDir() / "lumber_test_buf3.log"
  removeFile(path)
  let buf = newBufferedStream(newFileStream(path, fmWrite),
                              maxSize = 4096, flushIntervalMs = 50)
  buf.write("a")
  sleep(80)
  buf.write("b")  # the interval check runs on write
  check getFileSize(path) == 2
  buf.close()
  removeFile(path)

test "buffered output flushes immediately at flushLevel and above":
  let path = getTempDir() / "lumber_test_buf4.log"
  removeFile(path)
  let buf = newBufferedStream(newFileStream(path, fmWrite),
                              maxSize = 65536, flushIntervalMs = 0)
  configureLogging(cfg):
    cfg.middleware = @[]
    cfg.outputs = @[Output(stream: buf)]
  var logger = newLogger(name = "test")
  logger.info("buffered info")
  check getFileSize(path) == 0  # INFO is below the default ERROR threshold
  logger.error("flushed error")
  check getFileSize(path) > 0
  let content = readFile(path)
  check content.contains("buffered info")  # the flush carried earlier lines too
  check content.contains("flushed error")
  buf.close()
  removeFile(path)
  configureLogging(cfg):
    cfg.outputs = @[Output(stream: newFileStream(stdout))]

# -- Async stream --

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
