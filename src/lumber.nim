## lumber - A compile-time optimized JSON logger for Nim
##
## Compile with `-d:lumberLevel=INFO` to set the minimum log level.
## Log calls below the compile-time threshold are completely eliminated.

import std/[jsonutils, times, macros, strutils, os, streams, exitprocs, locks]
import std/json
export json

import ./lumber/types
export types

import ./lumber/streams as lumberstreams
export SizeRotateStream, newRollingFileStream, TimeRotateStream, newDailyFileStream,
  BufferedStream, newBufferedStream, defaultBufferSize, defaultFlushIntervalMs,
  AsyncStream, newAsyncStream

type
  Logger* = object
    name*: string
    level*: LogLevel = LogLevel.TRACE
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

  Output* = object
    stream*: Stream
    level*: LogLevel = LogLevel.TRACE
    names*: seq[string] = @[]

var middleware*: seq[LogMiddleware] = @[]
var outputs*: seq[Output] = @[Output(stream: newFileStream(stdout))]
var context* {.threadvar.}: JsonNode
var writeLock*: Lock

initLock(writeLock)

proc use*(mw: LogMiddleware) =
  middleware.add(mw)

proc clearMiddleware*() =
  middleware.setLen(0)

proc flush*() =
  ## Flush all output streams. Call this before exiting to ensure
  ## buffered log data is written.
  for o in outputs:
    try:
      o.stream.flush()
    except CatchableError:
      discard

proc shutdown*() =
  ## Flush and close all output streams. Call on graceful exit.
  for o in outputs:
    try:
      o.stream.flush()
      o.stream.close()
    except CatchableError:
      discard

when defined(posix):
  import std/posix

addExitProc(proc() = flush())

proc flushOnExit*() =
  ## Register SIGTERM/SIGINT signal handlers that flush all outputs
  ## before process exit. Call once at startup if your application
  ## may be terminated by signals.
  ## Note: atexit flush is already registered automatically on import.
  setControlCHook(proc() {.noconv.} =
    shutdown()
    quit(130)
  )
  when defined(posix):
    proc handleTerm(sig: cint) {.noconv.} =
      shutdown()
      quit(143)
    discard posix.signal(SIGTERM, handleTerm)

template withContext*(fields: JsonNode, body: untyped) =
  let prev = context
  if prev.isNil:
    context = fields
  else:
    context = prev.copy()
    for key, val in fields:
      context[key] = val
  try:
    body
  finally:
    context = prev

const lumberLevel* {.strdefine.}: string = "TRACE"
const CompileLogLevel*: LogLevel = parseEnum[LogLevel](lumberLevel)

proc toLogStr[T: object](val: T): string =
  $typeof(val) & $val

proc toLogStr[T: not object](val: T): string =
  $val

var cachedSecond {.threadvar.}: int64
var cachedTimestamp {.threadvar.}: string

proc formatTimestamp(): string =
  let t = getTime()
  let sec = t.toUnix()
  let ms = t.nanosecond div 1_000_000
  if sec != cachedSecond:
    cachedSecond = sec
    cachedTimestamp = t.utc.format("yyyy-MM-dd'T'HH:mm:ss")
  result = newStringOfCap(24)
  result.add cachedTimestamp
  result.add '.'
  if ms < 10: result.add "00"
  elif ms < 100: result.add '0'
  result.addInt ms
  result.add 'Z'

proc escapeJsonStr(buf: var string, s: string) =
  for c in s:
    case c
    of '"': buf.add "\\\""
    of '\\': buf.add "\\\\"
    of '\n': buf.add "\\n"
    of '\r': buf.add "\\r"
    of '\t': buf.add "\\t"
    of '\b': buf.add "\\b"
    of '\f': buf.add "\\f"
    else:
      if ord(c) < 0x20:
        buf.add "\\u00"
        buf.add toHex(ord(c), 2).toLowerAscii()
      else:
        buf.add c

proc writeLog*(logger: Logger, level: LogLevel, filename: string, line: int,
               message: string, fields: JsonNode = nil) =
  if level < logger.level:
    return
  var extra: JsonNode
  let hasContext = not context.isNil
  let hasLoggerExtra = not logger.extra.isNil
  let hasFields = not fields.isNil and fields.kind == JObject and fields.len > 0
  # Merge order: context (lowest) → logger.extra → fields (highest)
  # Fast path: no merging needed
  if not hasContext and not hasFields:
    if middleware.len > 0 and not logger.extra.isNil:
      # Middleware mutates record.extra; give the record its own copy so
      # the mutation can't leak into the logger's persistent extra.
      extra = logger.extra.copy()
    else:
      extra = logger.extra  # nil or existing ref, no copy
  elif not hasContext and not hasLoggerExtra:
    extra = fields
  else:
    # Need to merge — copy the base and overlay
    if hasContext:
      extra = context.copy()
    else:
      extra = newJObject()
    if hasLoggerExtra:
      for key, val in logger.extra:
        extra[key] = val
    if hasFields:
      for key, val in fields:
        extra[key] = val
  let levelStr = $level
  var record = LogRecord(
    timestamp: formatTimestamp(),
    level: levelStr,
    name: logger.name,
    filename: filename,
    line: line,
    message: message,
    extra: extra
  )
  withLock writeLock:
    for mw in middleware:
      if not mw(record):
        return
    # Re-parse level only if middleware may have changed it
    let outLevel = if record.level == levelStr: level
                   else: parseEnum[LogLevel](record.level)
    var buf = newStringOfCap(256)
    buf.add "{\"timestamp\":\""
    buf.add record.timestamp
    buf.add "\",\"level\":\""
    buf.add record.level
    buf.add "\",\"name\":\""
    buf.escapeJsonStr(record.name)
    buf.add "\",\"filename\":\""
    buf.escapeJsonStr(record.filename)
    buf.add "\",\"line\":"
    buf.addInt record.line
    buf.add ",\"message\":\""
    buf.escapeJsonStr(record.message)
    buf.add "\""
    if not record.extra.isNil and record.extra.kind == JObject:
      buf.add ",\"extra\":"
      buf.add $record.extra
    buf.add "}"
    for o in outputs:
      if outLevel < o.level:
        continue
      if o.names.len > 0 and record.name notin o.names:
        continue
      o.stream.writeLine(buf)
      if o.stream of BufferedStream:
        if outLevel >= BufferedStream(o.stream).flushLevel:
          o.stream.flush()
      else:
        o.stream.flush()

proc exceptionToJson(e: ref Exception): JsonNode =
  ## Convert an exception to a JSON object with error, errorType, and stackTrace fields.
  result = newJObject()
  result["error"] = %e.msg
  result["errorType"] = %($e.name)
  let trace = e.getStackTrace()
  if trace.len > 0:
    result["stackTrace"] = %trace

proc addExceptionFields(fields: JsonNode, e: ref Exception) =
  ## Add exception fields. If multiple exceptions are logged, stores them as an array.
  if fields.hasKey("errors"):
    fields["errors"].add(exceptionToJson(e))
  elif fields.hasKey("error"):
    # Second exception — convert to array format
    let first = newJObject()
    first["error"] = fields["error"]
    first["errorType"] = fields["errorType"]
    if fields.hasKey("stackTrace"):
      first["stackTrace"] = fields["stackTrace"]
    fields.delete("error")
    fields.delete("errorType")
    if fields.hasKey("stackTrace"):
      fields.delete("stackTrace")
    fields["errors"] = %[first, exceptionToJson(e)]
  else:
    let obj = exceptionToJson(e)
    for key, val in obj:
      fields[key] = val

proc logArgSimple[T](args: var seq[string], val: T) =
  ## Fast path: just convert to string, no fields object needed.
  args.add(toLogStr(val))

proc logArg[T](args: var seq[string], fields: JsonNode, val: T) =
  ## Compile-time dispatch: exceptions get their fields extracted,
  ## everything else becomes a format string argument.
  when T is ref Exception:
    addExceptionFields(fields, val)
  else:
    args.add(toLogStr(val))

proc logKwarg[T](fields: JsonNode, key: string, val: T) =
  ## Compile-time dispatch for keyword args: exceptions get their fields
  ## extracted (key is ignored), everything else becomes a JSON field.
  when T is ref Exception:
    addExceptionFields(fields, val)
  else:
    fields[key] = %val

proc buildMessageFromSeq(args: seq[string]): string =
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

proc genLogCall(level: LogLevel, logger: NimNode, args: NimNode): NimNode =
  if level < CompileLogLevel:
    return newStmtList()
  var positionalArgs: seq[NimNode] = @[]
  var namedArgs: seq[(string, NimNode)] = @[]
  for arg in args:
    if arg.kind == nnkExprEqExpr:
      namedArgs.add(($arg[0], arg[1]))
    else:
      positionalArgs.add(arg)
  let info = lineInfoObj(logger)
  let levelLit = newLit(level)
  let filename = newLit(info.filename.relativePath(getProjectPath()))
  let line = newLit(info.line)
  let fieldsVar = genSym(nskVar, "fields")
  let argsVar = genSym(nskVar, "args")
  let stmts = newStmtList()
  let needsFields = namedArgs.len > 0 or positionalArgs.len > 1
  if needsFields:
    stmts.add(newVarStmt(fieldsVar, newCall(ident"newJObject")))
  stmts.add(newVarStmt(argsVar, newNimNode(nnkCall).add(
    newNimNode(nnkBracketExpr).add(bindSym"newSeqOfCap", ident"string"),
    newLit(positionalArgs.len)
  )))
  if needsFields:
    for arg in positionalArgs:
      stmts.add(newCall(bindSym"logArg", argsVar, fieldsVar, arg))
    for (key, val) in namedArgs:
      stmts.add(
        newCall(bindSym"logKwarg", fieldsVar, newLit(key), val)
      )
  else:
    for arg in positionalArgs:
      stmts.add(newCall(bindSym"logArgSimple", argsVar, arg))
  let msgCall = newCall(bindSym"buildMessageFromSeq", argsVar)
  let fieldsNode = if needsFields:
    # Pass nil when object is empty (no exception was found at runtime)
    newNimNode(nnkIfExpr).add(
      newNimNode(nnkElifExpr).add(
        newNimNode(nnkInfix).add(ident">", newCall(ident"len", fieldsVar), newLit(0)),
        fieldsVar
      ),
      newNimNode(nnkElseExpr).add(newNilLit())
    )
  else:
    newNilLit()
  let writeCall = newCall(bindSym"writeLog", logger, levelLit, filename, line, msgCall, fieldsNode)
  stmts.add(writeCall)
  result = stmts

macro trace*(logger: typed, args: varargs[untyped]): untyped =
  genLogCall(LogLevel.TRACE, logger, args)

macro debug*(logger: typed, args: varargs[untyped]): untyped =
  genLogCall(LogLevel.DEBUG, logger, args)

macro info*(logger: typed, args: varargs[untyped]): untyped =
  genLogCall(LogLevel.INFO, logger, args)

macro warn*(logger: typed, args: varargs[untyped]): untyped =
  genLogCall(LogLevel.WARN, logger, args)

macro error*(logger: typed, args: varargs[untyped]): untyped =
  genLogCall(LogLevel.ERROR, logger, args)

macro fatal*(logger: typed, args: varargs[untyped]): untyped =
  genLogCall(LogLevel.FATAL, logger, args)

template time*(logger: Logger, message: string, body: untyped) =
  let start = cpuTime()
  body
  let durationMs = (cpuTime() - start) * 1000.0
  let fields = newJObject()
  fields["duration_ms"] = %durationMs
  writeLog(logger, LogLevel.INFO, instantiationInfo().filename, instantiationInfo().line, message, fields)

template time*(logger: Logger, level: LogLevel, message: string, body: untyped) =
  let start = cpuTime()
  body
  let durationMs = (cpuTime() - start) * 1000.0
  let fields = newJObject()
  fields["duration_ms"] = %durationMs
  writeLog(logger, level, instantiationInfo().filename, instantiationInfo().line, message, fields)

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

template newLogger*[T: object](name: string = "", extra: T): Logger =
  initLogger(instantiationInfo(), name, extra.toJson())

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
    level: logger.level,
    extra: merged
  )

proc child*[T: object](logger: Logger, name: string = "", extra: T): Logger =
  logger.child(name, extra.toJson())
