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

test "concurrent logging: intact lines, per-thread order, context isolation":
  removeFile(logFile)
  configureLogging(cfg):
    cfg.outputs = @[Output(stream: newFileStream(logFile, fmWrite))]

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
