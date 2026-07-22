import unittest
import std/[os, streams, json, strformat, atomics, locks]
import lumber

# Hammers the logging hot path from many threads at once, then verifies the
# output. Workers allocate their loggers and context on their own heaps and
# only borrow the shared output stream under the write lock; configuration
# happens once, on the main thread (see the ORC note in the README).

const
  numThreads = 8
  messagesPerThread = 2_000

var loggingDone: Atomic[int]
var collectLock: Lock
initLock(collectLock)

proc collectAfterAllLoggers() =
  ## ORC accumulates per-thread cycle-candidate state that thread exit
  ## does not free, so workers collect before exiting to keep the
  ## valgrind CI check leak-clean (no-op under arc/atomicArc). Two
  ## synchronization points matter, because the ORC collector walks refs
  ## without taking any lock: the barrier keeps a collector from racing
  ## another worker's refcount updates while it still logs, and the lock
  ## keeps two collectors from marking shared objects at the same time
  ## (helgrind flags both). sleep rather than spin: valgrind serializes
  ## threads, and a busy-wait starves the workers this one waits for.
  discard loggingDone.fetchAdd(1)
  while loggingDone.load < numThreads:
    sleep(1)
  withLock collectLock:
    GC_fullCollect()

let logFile = getTempDir() / "lumber_test_threading.log"

proc worker(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var logger = newLogger(name = "worker")
    withLogContext(%* {"ctxThread": id}):
      for i in 0 ..< messagesPerThread:
        logger.info(&"message {i} from thread {id}", seqNo=i, thread=id)
    collectAfterAllLoggers()

test "concurrent logging: intact lines, per-thread order, context isolation":
  removeFile(logFile)
  configureLogging(cfg):
    cfg.outputs = @[LogOutput(stream: newFileStream(logFile, fmWrite))]

  loggingDone.store(0)
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

  loggingDone.store(0)
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
    collectAfterAllLoggers()

test "one logger with extra fields shared across threads":
  removeFile(logFile)
  configureLogging(cfg):
    cfg.outputs = @[LogOutput(stream: newFileStream(logFile, fmWrite))]

  loggingDone.store(0)
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

# Daily rotation writes run on whichever thread happens to log, so the
# rotation date check must not leak per thread (regression: dateSuffix
# used std/times utc(), which caches a Timezone in a threadvar that
# thread exit never frees; the valgrind CI task catches it here)

let dailyLog = getTempDir() / "lumber_test_threading_daily.log"

proc dailyWorker(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var logger = newLogger(name = "daily")
    for i in 0 ..< 100:
      logger.info(&"daily message {i}", thread=id)
    collectAfterAllLoggers()

test "daily rotation output logged from threads":
  removeFile(dailyLog)
  let daily = newDailyFileStream(dailyLog)
  defer: daily.close()  # runs after the restore below (LIFO)
  configureLogging(cfg):
    cfg.outputs = @[LogOutput(stream: daily)]
  defer:
    configureLogging(cfg):
      cfg.outputs = @[LogOutput(stream: newFileStream(stdout))]

  loggingDone.store(0)
  var threads: array[numThreads, Thread[int]]
  for i in 0 ..< numThreads:
    createThread(threads[i], dailyWorker, i)
  joinThreads(threads)
  flushLogs()

  var lineCount = 0
  for line in dailyLog.lines:
    if line.len == 0: continue
    discard parseJson(line)
    inc lineCount
  check lineCount == numThreads * 100
  removeFile(dailyLog)
