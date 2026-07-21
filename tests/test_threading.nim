import unittest
import std/[os, streams, json, strformat]
import lumber

# Hammers the logging hot path from many threads at once, then verifies the
# output. Workers allocate their loggers and context on their own heaps and
# only borrow the shared output stream under the write lock; configuration
# happens once, on the main thread (see the ORC note in the README).

const
  numThreads = 8
  messagesPerThread = 2_000

let logFile = getTempDir() / "lumber_test_threading.log"

proc worker(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var logger = newLogger(name = "worker")
    withLogContext(%* {"ctxThread": id}):
      for i in 0 ..< messagesPerThread:
        logger.info(&"message {i} from thread {id}", seqNo=i, thread=id)
    # ORC accumulates per-thread cycle-candidate state that thread exit
    # does not free; collect before exiting so the valgrind CI check
    # stays leak-clean (no-op under arc/atomicArc)
    GC_fullCollect()

test "concurrent logging: intact lines, per-thread order, context isolation":
  removeFile(logFile)
  configureLogging(cfg):
    cfg.outputs = @[LogOutput(stream: newFileStream(logFile, fmWrite))]

  var threads: array[numThreads, Thread[int]]
  for i in 0 ..< numThreads:
    createThread(threads[i], worker, i)
  joinThreads(threads)
  flushLogs()

  var lineCount = 0
  var nextSeq: array[numThreads, int]
  for line in logFile.lines:
    if line.len == 0: continue
    let j = parseJson(line)  # raises on a torn/interleaved line
    inc lineCount
    let t = j["extra"]["thread"].getInt()
    check j["extra"]["ctxThread"].getInt() == t
    check j["extra"]["seqNo"].getInt() == nextSeq[t]
    inc nextSeq[t]
  check lineCount == numThreads * messagesPerThread
  removeFile(logFile)

proc flusher(rounds: int) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< rounds:
      flushLogs()

test "flushLogs is safe while other threads log":
  # Regression: flushLogs iterated the outputs seq without the write
  # lock, racing configureLogging commits and in-flight writes
  removeFile(logFile)
  configureLogging(cfg):
    cfg.outputs = @[LogOutput(stream: newFileStream(logFile, fmWrite))]

  var threads: array[numThreads, Thread[int]]
  for i in 0 ..< numThreads:
    createThread(threads[i], worker, i)
  var flushThread: Thread[int]
  createThread(flushThread, flusher, 500)
  joinThreads(threads)
  joinThread(flushThread)
  flushLogs()

  var lineCount = 0
  for line in logFile.lines:
    if line.len == 0: continue
    discard parseJson(line)  # raises on a torn line
    inc lineCount
  check lineCount == numThreads * messagesPerThread
  removeFile(logFile)

# One module-level logger with a persistent extra, shared by all threads:
# the README's idiomatic setup. Record assembly (including the refcount
# traffic on logger.extra) happens under the write lock, so this is safe
# under non-atomic ARC/ORC too.

var sharedLogger = newLogger(name = "shared", extra = %* {"service": "api"})

proc sharedWorker(id: int) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< messagesPerThread:
      sharedLogger.info(&"shared message {i}", seqNo=i, thread=id)
    GC_fullCollect()  # see worker

test "one logger with extra fields shared across threads":
  removeFile(logFile)
  configureLogging(cfg):
    cfg.outputs = @[LogOutput(stream: newFileStream(logFile, fmWrite))]

  var threads: array[numThreads, Thread[int]]
  for i in 0 ..< numThreads:
    createThread(threads[i], sharedWorker, i)
  joinThreads(threads)
  flushLogs()

  var lineCount = 0
  var nextSeq: array[numThreads, int]
  for line in logFile.lines:
    if line.len == 0: continue
    let j = parseJson(line)
    inc lineCount
    check j["extra"]["service"].getStr() == "api"
    let t = j["extra"]["thread"].getInt()
    check j["extra"]["seqNo"].getInt() == nextSeq[t]
    inc nextSeq[t]
  check lineCount == numThreads * messagesPerThread
  removeFile(logFile)
