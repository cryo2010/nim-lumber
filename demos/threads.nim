## Hammers the logging hot path from many threads at once, then verifies the
## output: every line must be intact JSON (no torn writes), per-thread
## sequence numbers must arrive in order, and withContext fields must never
## leak between threads. Writes and then verifies threads.log in the
## current directory.
##
## Run:
##   nim r demos/threads.nim

import std/[os, streams, json]
import ../src/lumber

const
  numThreads = 8
  messagesPerThread = 5_000
  logFile = "threads.log"

removeFile(logFile)
configureLogging(cfg):
  cfg.outputs = @[Output(stream: newFileStream(logFile, fmWrite))]

proc worker(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var logger = newLogger(name = "worker")
    withContext(%* {"ctxThread": id}):
      for i in 0 ..< messagesPerThread:
        logger.info("message {0} from thread {1}", i, id, seqNo=i, thread=id)

var threads: array[numThreads, Thread[int]]
for i in 0 ..< numThreads:
  createThread(threads[i], worker, i)
joinThreads(threads)
flush()

# -- Verify --

var lineCount = 0
var nextSeq: array[numThreads, int]
for line in logFile.lines:
  if line.len == 0: continue
  let j = parseJson(line)  # raises on a torn/interleaved line
  inc lineCount
  let t = j["extra"]["thread"].getInt()
  doAssert j["extra"]["ctxThread"].getInt() == t,
    "withContext fields leaked between threads"
  doAssert j["extra"]["seqNo"].getInt() == nextSeq[t],
    "per-thread write order was not preserved"
  inc nextSeq[t]

doAssert lineCount == numThreads * messagesPerThread,
  "expected " & $(numThreads * messagesPerThread) & " lines, got " & $lineCount

echo "OK: ", lineCount, " lines from ", numThreads,
  " threads; all valid JSON, per-thread order preserved, context isolated"
