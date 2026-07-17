## lumber - A compile-time optimized JSON logger for Nim
##
## Compile with `-d:lumberLevel=INFO` to set the minimum log level.
## Log calls below the compile-time threshold are completely eliminated.

import std/[jsonutils, times, monotimes, macros, strutils, os, streams, exitprocs, locks, atomics]
import std/json
export json

import ./lumber/types
export types

import ./lumber/version
export version

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

  LogConfig* = object
    middleware*: seq[LogMiddleware]
    outputs*: seq[Output]

var middleware: seq[LogMiddleware] = @[]
# Empty JObject handed to middleware when a record has no extra, so
# middleware never sees nil; reused across records until one writes to it.
# Guarded by writeLock.
var scratchExtra = newJObject()
var outputs*: seq[Output] = @[Output(stream: newFileStream(stdout))]
var context* {.threadvar.}: JsonNode
var writeLock: Lock
var configLock: Lock

initLock(writeLock)
initLock(configLock)

# Lock ordering: configLock is always acquired before writeLock, never the
# reverse. writeLog only takes writeLock, so logging never blocks on a
# running configuration callback.

var configOwner: Atomic[int]  # thread id holding configLock; 0 = unowned

proc raiseIfReentrant() =
  # Only the current thread can have stored its own id, so an equal value
  # proves reentrancy; configLock is a plain mutex and would deadlock.
  if configOwner.load(moRelaxed) == getThreadId():
    raise newException(Defect,
      "configureLogging is not reentrant: do not call it inside a " &
      "configureLogging block")

proc configureLoggingImpl(cb: proc(cfg: var LogConfig)) =
  # configLock serializes configurators for the whole snapshot-callback-commit
  # sequence, so concurrent reconfigurations cannot lose each other's updates.
  # writeLock is only held for the snapshot and the commit, so the callback
  # runs unlocked with respect to logging (and may log). If the callback
  # raises, nothing is committed.
  raiseIfReentrant()
  withLock configLock:
    configOwner.store(getThreadId(), moRelaxed)
    defer: configOwner.store(0, moRelaxed)
    var cfg: LogConfig
    withLock writeLock:
      cfg = LogConfig(middleware: middleware, outputs: outputs)
    cb(cfg)
    withLock writeLock:
      for old in outputs:
        var kept = false
        for o in cfg.outputs:
          if o.stream == old.stream:
            kept = true
            break
        if not kept:
          try:
            old.stream.flush()
          except CatchableError:
            discard
      middleware = cfg.middleware
      outputs = cfg.outputs

template configureLogging*(cfg, body: untyped) =
  ## Reconfigure middleware and outputs atomically. `cfg` names the variable
  ## that holds a snapshot of the current configuration inside the block;
  ## changes are committed when the block finishes, so loggers on other
  ## threads never observe a half-applied configuration. If the block raises,
  ## nothing is committed. Outputs dropped by the new configuration are
  ## flushed (but not closed).
  ##
  ## Concurrent `configureLogging` calls serialize; each block sees the
  ## previous one's committed state. The block must not call
  ## `configureLogging` itself: doing so raises a `Defect` (the config lock
  ## is not reentrant, and nested commits would silently lose updates).
  ## Reconfigure from long-lived threads (typically the main thread); with
  ## ORC, dropping the previous configuration's references from a
  ## short-lived thread corrupts cycle collection once that thread exits.
  ## Compiling with `--mm:atomicArc` removes this constraint.
  ##
  ## ```nim
  ## configureLogging(cfg):
  ##   cfg.outputs.add Output(stream: newRollingFileStream("app.log"))
  ## ```
  configureLoggingImpl(proc(cfg: var LogConfig) = body)

proc flushLogs*() =
  ## Flush all output streams. Call this before exiting to ensure
  ## buffered log data is written.
  for o in outputs:
    try:
      o.stream.flush()
    except CatchableError:
      discard

proc shutdownLogs*() =
  ## Flush and close all output streams; async writer threads are joined
  ## and file handles released. Call on graceful exit. Logging after this
  ## point is discarded by the closed streams.
  for o in outputs:
    try:
      o.stream.flush()
      o.stream.close()
    except CatchableError:
      discard

when defined(posix):
  import std/posix

addExitProc(proc() = flushLogs())

proc shutdownLogsOnSignal*() =
  ## Register SIGTERM/SIGINT handlers that run `shutdownLogs` and quit
  ## (exit codes 143 and 130). Call once at startup in applications that
  ## have no signal handling of their own; it matters when buffered or
  ## async outputs hold data in memory, since default signal death skips
  ## the automatic atexit flush. Applications with their own graceful
  ## shutdown should not use this (it overwrites the Ctrl-C hook and
  ## quits immediately); call `shutdownLogs` from their shutdown path
  ## instead.
  setControlCHook(proc() {.noconv.} =
    shutdownLogs()
    quit(130)
  )
  when defined(posix):
    proc handleTerm(sig: cint) {.noconv.} =
      shutdownLogs()
      quit(143)
    discard posix.signal(SIGTERM, handleTerm)

template withLogContext*(fields: JsonNode, body: untyped) =
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
    if middleware.len > 0:
      # Middleware always sees a JObject in record.extra so it can add
      # fields without nil checks. The scratch object is reused across
      # records while no middleware touches it (guarded by writeLock).
      var usedScratch = false
      if record.extra.isNil:
        record.extra = scratchExtra
        usedScratch = true
      var keep = true
      for mw in middleware:
        if not mw(record):
          keep = false
          break
      if usedScratch and record.extra == scratchExtra:
        if scratchExtra.len == 0:
          record.extra = nil  # untouched; keep the scratch for reuse
        else:
          scratchExtra = newJObject()  # donated to this record
      if not keep:
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
    if not record.extra.isNil and record.extra.kind == JObject and record.extra.len > 0:
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
      elif o.stream of AsyncStream:
        # The writer thread batches under load and flushes when its queue
        # drains; a per-record flush message would defeat the batching
        discard
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
  if fields.hasKey("errors") and fields["errors"].kind == JArray:
    fields["errors"].add(exceptionToJson(e))
  elif fields.hasKey("error"):
    # A second exception, or a user-supplied field named "error": convert to
    # array format, carrying over only the companion fields that exist (a
    # plain error="..." kwarg has no errorType or stackTrace)
    let first = newJObject()
    first["error"] = fields["error"]
    fields.delete("error")
    for key in ["errorType", "stackTrace"]:
      if fields.hasKey(key):
        first[key] = fields[key]
        fields.delete(key)
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
  ## Joins the message and any extra positional arguments with spaces.
  ## lumber does not interpret placeholders in messages; use Nim's
  ## `std/strformat` (`&"..."`) for interpolation. It is evaluated inside
  ## the level gate, so filtered calls skip the formatting entirely.
  case args.len
  of 0: ""
  of 1: args[0]
  else: args.join(" ")

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
  # Bind non-trivial logger expressions to a temporary so the runtime level
  # gate below doesn't evaluate them twice
  var loggerRef = logger
  var setup = newStmtList()
  if logger.kind notin {nnkSym, nnkIdent}:
    loggerRef = genSym(nskLet, "lumberLogger")
    setup.add(newLetStmt(loggerRef, logger))
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
  let writeCall = newCall(bindSym"writeLog", loggerRef, levelLit, filename, line, msgCall, fieldsNode)
  stmts.add(writeCall)
  # Gate everything behind the runtime level check so filtered calls never
  # evaluate arguments, build the fields object, or format the message
  let cond = infix(levelLit, ">=", newDotExpr(loggerRef, ident"level"))
  result = setup
  result.add(newTree(nnkIfStmt, newTree(nnkElifBranch, cond, stmts)))

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

proc elapsedMs(start: MonoTime): float =
  (getMonoTime() - start).inNanoseconds.float / 1_000_000.0

template time*(logger: Logger, level: LogLevel, message: string, body: untyped) =
  ## Runs `body` and logs its wall-clock duration at `level` with a
  ## `duration_ms` field.
  let start = getMonoTime()
  body
  let durationMs = elapsedMs(start)
  let fields = newJObject()
  fields["duration_ms"] = %durationMs
  let info = instantiationInfo()
  writeLog(logger, level, info.filename, info.line, message, fields)

template time*(logger: Logger, message: string, body: untyped) =
  ## Runs `body` and logs its wall-clock duration at INFO level with a
  ## `duration_ms` field.
  time(logger, LogLevel.INFO, message, body)

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
