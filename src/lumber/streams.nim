## Stream wrappers for lumber: rotating files, buffering, and async writing.
##
## These are general-purpose `Stream` implementations with no dependency on
## the logger itself. `import lumber` re-exports everything here.

import std/[streams, times, os, strutils, algorithm, atomics]
import ./types
import ./timestamps

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

# The rotate/buffered/async impls promise raises: [] to the Stream vtable,
# but file I/O genuinely fails (disk full, permissions). A logger must not
# take the application down from a write path, and letting an exception
# escape a raises: [] cast is undefined behavior, so every impl catches
# CatchableError, drops the data, and tries to recover on the next call.

proc sizeRotateClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = SizeRotateStream(s)
    if rs.file != nil:
      try:
        rs.file.close()
      except CatchableError:
        discard
      rs.file = nil

proc sizeRotateWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    if bufLen <= 0: return
    let rs = SizeRotateStream(s)
    try:
      if rs.file != nil and rs.currentSize + bufLen.int64 > rs.maxBytes:
        rs.file.close()
        rs.file = nil  # never write through a closed handle if rotation fails
        rotateFiles(rs.basePath, rs.maxFiles)
        rs.file = open(rs.basePath, fmWrite)
        rs.currentSize = 0
      if rs.file == nil:
        # A previous rotation failed; reopen instead of dropping forever
        rs.file = open(rs.basePath, fmAppend)
        rs.currentSize = getFileSize(rs.basePath)
      discard rs.file.writeBuffer(buffer, bufLen)
      rs.currentSize += bufLen.int64
    except CatchableError:
      discard

proc sizeRotateFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = SizeRotateStream(s)
    if rs.file != nil:
      try:
        rs.file.flushFile()
      except CatchableError:
        discard

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
  # Civil-from-days math instead of now().utc: rotation runs on whichever
  # thread happens to log, and std/times utc() leaks a threadvar Timezone
  # per thread (see timestamps.nim)
  utcDate(getTime().toUnix())

proc timeRotateClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = TimeRotateStream(s)
    if rs.file != nil:
      try:
        rs.file.close()
      except CatchableError:
        discard
      rs.file = nil

proc isDatedBackup(fname, name, ext: string): bool =
  ## Matches exactly "<name>.YYYY-MM-dd<ext>", the names TimeRotateStream
  ## produces when it rotates. A loose prefix match would also catch
  ## unrelated siblings like "<name>-other<ext>" or size-rotation backups
  ## ("<name><ext>.1") and delete user data.
  const dateLen = len("2000-01-01")
  if fname.len != name.len + 1 + dateLen + ext.len:
    return false
  if not (fname.startsWith(name & ".") and fname.endsWith(ext)):
    return false
  let date = fname[name.len + 1 ..< name.len + 1 + dateLen]
  for i, c in date:
    if i == 4 or i == 7:
      if c != '-': return false
    elif c notin {'0'..'9'}:
      return false
  true

proc rotateTimeFiles*(basePath: string, maxFiles: int) =
  ## Deletes the oldest dated backups of `basePath` until at most `maxFiles`
  ## remain. Only files named "<name>.YYYY-MM-dd<ext>" are considered.
  ## Called by `TimeRotateStream` on rotation; exported for testing.
  let (dir, name, ext) = splitFile(basePath)
  let searchDir = if dir.len > 0: dir else: "."
  var dated: seq[string] = @[]
  for kind, path in walkDir(searchDir):
    if kind == pcFile and isDatedBackup(extractFilename(path), name, ext):
      dated.add(path)
  dated.sort()
  while dated.len > maxFiles:
    removeFile(dated[0])
    dated.delete(0)

proc timeRotateWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    if bufLen <= 0: return
    let rs = TimeRotateStream(s)
    try:
      let today = dateSuffix()
      if rs.file != nil and today != rs.currentDate:
        rs.file.close()
        rs.file = nil  # never write through a closed handle if rotation fails
        let (_, name, ext) = splitFile(rs.basePath)
        let dir = parentDir(rs.basePath)
        let datedName = if dir.len > 0: dir / name & "." & rs.currentDate & ext
                        else: name & "." & rs.currentDate & ext
        if fileExists(rs.basePath):
          moveFile(rs.basePath, datedName)
        rotateTimeFiles(rs.basePath, rs.maxFiles)
        # Mark the rotation done before reopening: if open fails, the next
        # write must not redo the move with a stale date
        rs.currentDate = today
        rs.file = open(rs.basePath, fmWrite)
      if rs.file == nil:
        # A previous rotation failed; reopen instead of dropping forever
        rs.file = open(rs.basePath, fmAppend)
        rs.currentDate = dateSuffix()
      discard rs.file.writeBuffer(buffer, bufLen)
    except CatchableError:
      discard

proc timeRotateFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let rs = TimeRotateStream(s)
    if rs.file != nil:
      try:
        rs.file.flushFile()
      except CatchableError:
        discard

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
    try:
      if bs.buf.len > 0:
        bs.inner.write(bs.buf)
        bs.buf.setLen(0)
      bs.inner.flush()
    except CatchableError:
      # Drop the buffer rather than grow without bound while the inner
      # stream is stuck
      bs.buf.setLen(0)
    bs.lastFlushTime = epochTime()

proc bufWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    if bufLen <= 0: return
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
    try:
      bs.inner.close()
    except CatchableError:
      discard

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
    closed: Atomic[bool]

proc asyncWriterLoop(state: ptr AsyncState) {.thread.} =
  # Inner-stream failures are swallowed: an exception escaping a thread
  # aborts the whole process, and a logger must not do that on disk-full
  while true:
    let msg = state.chan.recv()
    try:
      if msg.isClose:
        state.inner.flush()
        state.inner.close()
      elif msg.isFlush:
        state.inner.flush()
      else:
        state.inner.write(msg.data)
        # Batch while there is backlog; flush the moment the queue drains so
        # data never sits in the inner stream's buffer while the logger is idle
        if state.chan.peek() == 0:
          state.inner.flush()
    except CatchableError:
      discard
    if msg.isClose:
      break

proc asyncWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    if bufLen <= 0: return
    let a = AsyncStream(s)
    if a.closed.load(moAcquire): return
    var data = newString(bufLen)
    copyMem(addr data[0], buffer, bufLen)
    a.state.chan.send(AsyncMsg(data: data))

proc asyncFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    if a.closed.load(moAcquire): return
    a.state.chan.send(AsyncMsg(isFlush: true))

proc asyncClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    # exchange makes a second close a no-op instead of a double free
    if a.closed.exchange(true, moAcquireRelease): return
    a.state.chan.send(AsyncMsg(isClose: true))
    joinThread(a.thread)
    a.state.chan.close()
    # deallocShared does not run destructors: release the inner ref
    # explicitly or it leaks
    a.state.inner = nil
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
