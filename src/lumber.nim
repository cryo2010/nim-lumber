## lumber - A compile-time optimized JSON logger for Nim
##
## Compile with `-d:lumberLevel=INFO` to set the minimum log level.
## Log calls below the compile-time threshold are completely eliminated.

import std/[json, times, macros, strutils, os, streams, algorithm]

type
  LogLevel* = enum
    TRACE, DEBUG, INFO, WARN, ERROR, FATAL

  Logger* = object
    name*: string
    extra*: JsonNode

  LogRecord* = object
    timestamp*: string
    level*: string
    name*: string
    filename*: string
    line*: int
    message*: string
    extra*: JsonNode

  LogMiddleware* = proc(record: var LogRecord): bool

var middleware*: seq[LogMiddleware] = @[]
var outputs*: seq[Stream] = @[Stream(newFileStream(stdout))]

proc use*(mw: LogMiddleware) =
  middleware.add(mw)

proc clearMiddleware*() =
  middleware.setLen(0)

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

proc newSizeRotateStream*(path: string, maxBytes: int64 = 10_000_000,
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

proc newTimeRotateStream*(path: string, maxFiles: int = 30): TimeRotateStream =
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

proc asyncWrite(s: Stream, buffer: pointer, bufLen: int) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    var data = newString(bufLen)
    copyMem(addr data[0], buffer, bufLen)
    a.state.chan.send(AsyncMsg(data: data))

proc asyncFlush(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    a.state.chan.send(AsyncMsg(isFlush: true))

proc asyncClose(s: Stream) {.nimcall.} =
  {.cast(raises: []).}: {.cast(tags: []).}:
    let a = AsyncStream(s)
    a.state.chan.send(AsyncMsg(isClose: true))
    joinThread(a.thread)
    a.state.chan.close()
    deallocShared(a.state)

proc newAsyncStream*(inner: Stream): AsyncStream =
  new(result)
  result.state = cast[ptr AsyncState](allocShared0(sizeof(AsyncState)))
  result.state.chan.open()
  result.state.inner = inner
  result.writeDataImpl = asyncWrite
  result.flushImpl = asyncFlush
  result.closeImpl = asyncClose
  createThread(result.thread, asyncWriterLoop, result.state)

const lumberLevel* {.strdefine.}: string = "TRACE"
const CompileLogLevel*: LogLevel = parseEnum[LogLevel](lumberLevel)

proc buildMessage*(args: varargs[string]): string =
  if args.len == 0: return ""
  if args.len == 1: return args[0]
  result = args[0]
  var used: set[uint8] = {}
  for i in 1 ..< args.len:
    let placeholder = "{" & $(i - 1) & "}"
    if placeholder in result:
      result = result.replace(placeholder, args[i])
      used.incl(uint8(i))
  for i in 1 ..< args.len:
    if uint8(i) notin used:
      result &= " " & args[i]

proc writeLog*(logger: Logger, level: string, filename: string, line: int,
               message: string) =
  var record = LogRecord(
    timestamp: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    level: level,
    name: logger.name,
    filename: filename,
    line: line,
    message: message,
    extra: if not logger.extra.isNil: logger.extra.copy() else: nil
  )
  for mw in middleware:
    if not mw(record):
      return
  var output = %* {
    "timestamp": record.timestamp,
    "level": record.level,
    "name": record.name,
    "filename": record.filename,
    "line": record.line,
    "message": record.message
  }
  if not record.extra.isNil and record.extra.kind == JObject:
    output["extra"] = record.extra
  let line = $output
  for s in outputs:
    s.writeLine(line)
    s.flush()

proc genLogCall(level: LogLevel, logger: NimNode, args: NimNode): NimNode =
  if level < CompileLogLevel:
    return newStmtList()
  var call = newCall(bindSym"buildMessage")
  for arg in args:
    let argType = arg.getTypeInst()
    if argType.typeKind == ntyObject:
      let typeName = newLit($argType)
      call.add(newCall(ident"&", typeName, newCall(ident"$", arg)))
    else:
      call.add(newCall(ident"$", arg))
  let info = lineInfoObj(logger)
  let levelStr = newLit($level)
  let filename = newLit(info.filename.relativePath(getProjectPath()))
  let line = newLit(info.line)
  result = newCall(bindSym"writeLog", logger, levelStr, filename, line, call)

macro trace*(logger: typed, args: varargs[typed]): untyped =
  genLogCall(LogLevel.TRACE, logger, args)

macro debug*(logger: typed, args: varargs[typed]): untyped =
  genLogCall(LogLevel.DEBUG, logger, args)

macro info*(logger: typed, args: varargs[typed]): untyped =
  genLogCall(LogLevel.INFO, logger, args)

macro warn*(logger: typed, args: varargs[typed]): untyped =
  genLogCall(LogLevel.WARN, logger, args)

macro error*(logger: typed, args: varargs[typed]): untyped =
  genLogCall(LogLevel.ERROR, logger, args)

macro fatal*(logger: typed, args: varargs[typed]): untyped =
  genLogCall(LogLevel.FATAL, logger, args)

proc initLogger*(callerInfo: tuple[filename: string, line: int, column: int],
                  name: string, extra: JsonNode): Logger =
  var modName = callerInfo.filename
  let slashIdx = modName.rfind('/')
  if slashIdx >= 0: modName = modName[slashIdx + 1 .. ^1]
  let bslashIdx = modName.rfind('\\')
  if bslashIdx >= 0: modName = modName[bslashIdx + 1 .. ^1]
  let dotIdx = modName.rfind('.')
  if dotIdx > 0: modName = modName[0 ..< dotIdx]
  Logger(name: if name.len > 0: name else: modName, extra: extra)

template newLogger*(name: string = "", extra: JsonNode = nil): Logger =
  initLogger(instantiationInfo(), name, extra)

proc child*(logger: Logger, name: string = "", extra: JsonNode = nil): Logger =
  var merged: JsonNode
  if not logger.extra.isNil and logger.extra.kind == JObject:
    merged = logger.extra.copy()
    if not extra.isNil and extra.kind == JObject:
      for key, val in extra:
        merged[key] = val
  elif not extra.isNil:
    merged = extra.copy()
  else:
    merged = nil
  Logger(
    name: if name.len > 0: name else: logger.name,
    extra: merged
  )

when isMainModule:
  const
    reset = "\e[0m"
    gray = "\e[90m"
    lightGray = "\e[37m"
    blue = "\e[34m"
    lightBlue = "\e[94m"
    white = "\e[97m"
    yellow = "\e[33m"
    brightRed = "\e[91m"
    magenta = "\e[35m"

  proc colorForLevel(level: string): string =
    case level
    of "TRACE": blue
    of "DEBUG": lightBlue
    of "INFO": white
    of "WARN": yellow
    of "ERROR": brightRed
    of "FATAL": magenta
    else: white

  proc levelOrd(level: string): int =
    case level.toUpperAscii()
    of "TRACE": 0
    of "DEBUG": 1
    of "INFO": 2
    of "WARN": 3
    of "ERROR": 4
    of "FATAL": 5
    else: -1

  proc parseArgs(): LogLevel =
    result = LogLevel.TRACE
    let args = commandLineParams()
    var i = 0
    while i < args.len:
      var value = ""
      if args[i].startsWith("--level="):
        value = args[i][8 .. ^1]
      elif args[i] == "--level" and i + 1 < args.len:
        value = args[i + 1]
        inc i
      if value.len > 0:
        try:
          result = parseEnum[LogLevel](value.toUpperAscii())
        except ValueError:
          stderr.writeLine("lumber: invalid level '" & value & "'. Expected: trace, debug, info, warn, error, fatal")
          quit(1)
      inc i

  let minLevel = parseArgs()

  var line: string
  while stdin.readLine(line):
    try:
      let j = parseJson(line)
      let level = j.getOrDefault("level").getStr("")
      if levelOrd(level) < ord(minLevel):
        continue
      let timestamp = j.getOrDefault("timestamp").getStr("")
      let filename = j.getOrDefault("filename").getStr("")
      let lineNum = j.getOrDefault("line").getInt(0)
      let message = j.getOrDefault("message").getStr("")
      let extra = j.getOrDefault("extra")
      let color = colorForLevel(level)
      let paddedLevel = alignLeft(level, 5)
      var output = gray & timestamp & reset & " " & color & "[" & paddedLevel & "]" & reset & " " & lightGray & "(" & filename & ":" & $lineNum & ")" & reset & " " & message
      if not extra.isNil and extra.kind == JObject and extra.len > 0:
        output &= " " & lightGray & $extra & reset
      stdout.writeLine(output)
    except JsonParsingError:
      stdout.writeLine(line)
