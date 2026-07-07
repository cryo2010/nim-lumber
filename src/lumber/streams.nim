## Stream wrappers for lumber: rotating files, buffering, and async writing.
##
## These are general-purpose `Stream` implementations with no dependency on
## the logger itself. `import lumber` re-exports everything here.

import std/[streams, times, os, strutils, algorithm]
import ./types

# -- Rotating file streams --

type
  SizeRotateStream* = ref object of Stream
    basePath*: string
    maxBytes*: int64
    maxFiles*: int
    currentSize: int64
    file: File

  TimeRotateStream* = ref object of Stream
    basePath*: string
    maxFiles*: int
    currentDate: string
    file: File

proc rotateFiles(basePath: string, maxFiles: int) =
  let oldest = basePath & "." & $maxFiles
  if fileExists(oldest):
    removeFile(oldest)
  for i in countdown(maxFiles - 1, 1):
    let src = basePath & "." & $i
    let dst = basePath & "." & $(i + 1)
    if fileExists(src):
      moveFile(src, dst)
  if fileExists(basePath):
    moveFile(basePath, basePath & ".1")

proc sizeRotateClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = SizeRotateStream(s)
    if rs.file != nil:
      rs.file.close()

proc sizeRotateWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = SizeRotateStream(s)
    if rs.currentSize + bufLen.int64 > rs.maxBytes:
      rs.file.close()
      rotateFiles(rs.basePath, rs.maxFiles)
      rs.file = open(rs.basePath, fmWrite)
      rs.currentSize = 0
    discard rs.file.writeBuffer(buffer, bufLen)
    rs.currentSize += bufLen.int64

proc sizeRotateFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = SizeRotateStream(s)
    rs.file.flushFile()

proc newRollingFileStream*(path: string, maxBytes: int64 = 10_000_000,
                          maxFiles: int = 5): SizeRotateStream =
  new(result)
  result.basePath = path
  result.maxBytes = maxBytes
  result.maxFiles = maxFiles
  if fileExists(path):
    result.file = open(path, fmAppend)
    result.currentSize = getFileSize(path)
  else:
    result.file = open(path, fmWrite)
    result.currentSize = 0
  result.closeImpl = sizeRotateClose
  result.writeDataImpl = sizeRotateWrite
  result.flushImpl = sizeRotateFlush

proc dateSuffix(): string =
  now().utc.format("yyyy-MM-dd")

proc timeRotateClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = TimeRotateStream(s)
    if rs.file != nil:
      rs.file.close()

proc rotateTimeFiles(basePath: string, maxFiles: int) =
  let (dir, name, ext) = splitFile(basePath)
  let searchDir = if dir.len > 0: dir else: "."
  var dated: seq[string] = @[]
  for kind, path in walkDir(searchDir):
    if kind == pcFile:
      let fname = extractFilename(path)
      if fname.startsWith(name) and fname != name & ext and ext in fname:
        dated.add(path)
  dated.sort()
  while dated.len >= maxFiles:
    removeFile(dated[0])
    dated.delete(0)

proc timeRotateWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = TimeRotateStream(s)
    let today = dateSuffix()
    if today != rs.currentDate:
      rs.file.close()
      let (_, name, ext) = splitFile(rs.basePath)
      let dir = parentDir(rs.basePath)
      let datedName = if dir.len > 0: dir / name & "." & rs.currentDate & ext
                      else: name & "." & rs.currentDate & ext
      if fileExists(rs.basePath):
        moveFile(rs.basePath, datedName)
      rotateTimeFiles(rs.basePath, rs.maxFiles)
      rs.file = open(rs.basePath, fmWrite)
      rs.currentDate = today
    discard rs.file.writeBuffer(buffer, bufLen)

proc timeRotateFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = TimeRotateStream(s)
    rs.file.flushFile()

proc newDailyFileStream*(path: string, maxFiles: int = 30): TimeRotateStream =
  new(result)
  result.basePath = path
  result.maxFiles = maxFiles
  result.currentDate = dateSuffix()
  if fileExists(path):
    result.file = open(path, fmAppend)
  else:
    result.file = open(path, fmWrite)
  result.closeImpl = timeRotateClose
  result.writeDataImpl = timeRotateWrite
  result.flushImpl = timeRotateFlush

# -- Buffered stream wrapper (hybrid flush strategy) --

type
  BufferedStream* = ref object of Stream
    inner: Stream
    buf: string
    maxSize*: int
    flushLevel*: LogLevel
    flushIntervalMs*: int
    lastFlushTime: float

const defaultBufferSize* = 4096
const defaultFlushIntervalMs* = 1000

proc bufFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let bs = BufferedStream(s)
    if bs.buf.len > 0:
      bs.inner.write(bs.buf)
      bs.buf.setLen(0)
    bs.inner.flush()
    bs.lastFlushTime = epochTime()

proc bufWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let bs = BufferedStream(s)
    let oldLen = bs.buf.len
    bs.buf.setLen(oldLen + bufLen)
    copyMem(addr bs.buf[oldLen], buffer, bufLen)
    if bs.buf.len >= bs.maxSize:
      bufFlush(s)
    elif bs.flushIntervalMs > 0:
      let now = epochTime()
      if (now - bs.lastFlushTime) * 1000.0 >= bs.flushIntervalMs.float:
        bufFlush(s)

proc bufClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let bs = BufferedStream(s)
    bufFlush(s)
    bs.inner.close()

proc newBufferedStream*(inner: Stream, maxSize: int = defaultBufferSize,
                        flushLevel: LogLevel = LogLevel.ERROR,
                        flushIntervalMs: int = defaultFlushIntervalMs): BufferedStream =
  new(result)
  result.inner = inner
  result.buf = newStringOfCap(maxSize)
  result.maxSize = maxSize
  result.flushLevel = flushLevel
  result.flushIntervalMs = flushIntervalMs
  result.lastFlushTime = epochTime()
  result.writeDataImpl = bufWrite
  result.flushImpl = bufFlush
  result.closeImpl = bufClose

# -- Async stream wrapper --

type
  AsyncMsg = object
    data: string
    isFlush: bool
    isClose: bool

  AsyncState = object
    chan: Channel[AsyncMsg]
    inner: Stream

  AsyncStream* = ref object of Stream
    state: ptr AsyncState
    thread: Thread[ptr AsyncState]
    closed: bool

proc asyncWriterLoop(state: ptr AsyncState) {.thread.} =
  while true:
    let msg = state.chan.recv()
    if msg.isClose:
      state.inner.flush()
      state.inner.close()
      break
    elif msg.isFlush:
      state.inner.flush()
    else:
      state.inner.write(msg.data)
      # Batch while there is backlog; flush the moment the queue drains so
      # data never sits in the inner stream's buffer while the logger is idle
      if state.chan.peek() == 0:
        state.inner.flush()

proc asyncWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    if a.closed: return
    var data = newString(bufLen)
    copyMem(addr data[0], buffer, bufLen)
    a.state.chan.send(AsyncMsg(data: data))

proc asyncFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    if a.closed: return
    a.state.chan.send(AsyncMsg(isFlush: true))

proc asyncClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    if a.closed: return
    a.closed = true
    a.state.chan.send(AsyncMsg(isClose: true))
    joinThread(a.thread)
    a.state.chan.close()
    deallocShared(a.state)

proc newAsyncStream*(inner: Stream): AsyncStream =
  ## Wraps `inner` so writes return immediately and a background thread
  ## performs the actual I/O. Writes are batched while the queue has
  ## backlog; the writer flushes `inner` whenever the queue drains, and
  ## `close` flushes everything and joins the thread.
  new(result)
  result.state = cast[ptr AsyncState](allocShared0(sizeof(AsyncState)))
  result.state.chan.open()
  result.state.inner = inner
  result.writeDataImpl = asyncWrite
  result.flushImpl = asyncFlush
  result.closeImpl = asyncClose
  createThread(result.thread, asyncWriterLoop, result.state)
