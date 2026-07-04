## lumber - A compile-time optimized JSON logger for Nim
##
## Compile with `-d:lumberLevel=INFO` to set the minimum log level.
## Log calls below the compile-time threshold are completely eliminated.

import std/[json, jsonutils, times, macros, strutils, os, streams, algorithm]

type
  LogLevel* = enum
    TRACE, DEBUG, INFO, WARN, ERROR, FATAL

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

proc toLogStr*[T: object](val: T): string =
  $typeof(val) & $val

proc toLogStr*[T: not object](val: T): string =
  $val

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
               message: string, fields: JsonNode = nil) =
  let recordLevel = parseEnum[LogLevel](level)
  if recordLevel < logger.level:
    return
  var extra: JsonNode
  if not logger.extra.isNil:
    extra = logger.extra.copy()
    if not fields.isNil and fields.kind == JObject:
      for key, val in fields:
        extra[key] = val
  elif not fields.isNil:
    extra = fields.copy()
  else:
    extra = nil
  var record = LogRecord(
    timestamp: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    level: level,
    name: logger.name,
    filename: filename,
    line: line,
    message: message,
    extra: extra
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
  let outLevel = parseEnum[LogLevel](record.level)
  let line = $output
  for o in outputs:
    if outLevel < o.level:
      continue
    if o.names.len > 0 and record.name notin o.names:
      continue
    o.stream.writeLine(line)
    o.stream.flush()

proc genLogCall(level: LogLevel, logger: NimNode, args: NimNode): NimNode =
  if level < CompileLogLevel:
    return newStmtList()
  var call = newCall(bindSym"buildMessage")
  var namedArgs: seq[(string, NimNode)] = @[]
  for arg in args:
    if arg.kind == nnkExprEqExpr:
      namedArgs.add(($arg[0], arg[1]))
    else:
      call.add(newCall(bindSym"toLogStr", arg))
  let info = lineInfoObj(logger)
  let levelStr = newLit($level)
  let filename = newLit(info.filename.relativePath(getProjectPath()))
  let line = newLit(info.line)
  if namedArgs.len > 0:
    let fieldsVar = genSym(nskLet, "fields")
    let buildFields = newStmtList()
    buildFields.add(newLetStmt(fieldsVar, newCall(ident"newJObject")))
    for (key, val) in namedArgs:
      buildFields.add(
        newCall(ident"[]=", fieldsVar, newLit(key), newCall(ident"%", val))
      )
    let writeCall = newCall(bindSym"writeLog", logger, levelStr, filename, line, call, fieldsVar)
    buildFields.add(writeCall)
    result = buildFields
  else:
    result = newCall(bindSym"writeLog", logger, levelStr, filename, line, call)

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
  writeLog(logger, $LogLevel.INFO, instantiationInfo().filename, instantiationInfo().line, message, fields)

template time*(logger: Logger, level: LogLevel, message: string, body: untyped) =
  let start = cpuTime()
  body
  let durationMs = (cpuTime() - start) * 1000.0
  let fields = newJObject()
  fields["duration_ms"] = %durationMs
  writeLog(logger, $level, instantiationInfo().filename, instantiationInfo().line, message, fields)

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

when isMainModule:
  var reset = "\e[0m"

  type
    Theme = object
      timestamp: string
      filename: string
      name: string
      message: string
      duration: string
      extraKey: string
      extraValue: string
      levelTrace: string
      levelDebug: string
      levelInfo: string
      levelWarn: string
      levelError: string
      levelFatal: string

  proc colorNameToAnsi(name: string): string =
    case name.toLowerAscii().replace("_", "")
    of "black": "\e[30m"
    of "red": "\e[31m"
    of "green": "\e[32m"
    of "yellow": "\e[33m"
    of "blue": "\e[34m"
    of "magenta": "\e[35m"
    of "cyan": "\e[36m"
    of "white": "\e[97m"
    of "gray", "grey": "\e[90m"
    of "lightgray", "lightgrey": "\e[37m"
    of "lightred", "brightred": "\e[91m"
    of "lightgreen", "brightgreen": "\e[92m"
    of "lightyellow", "brightyellow": "\e[93m"
    of "lightblue", "brightblue": "\e[94m"
    of "lightmagenta", "brightmagenta": "\e[95m"
    of "lightcyan", "brightcyan": "\e[96m"
    of "", "none": ""
    else: ""

  proc defaultTheme(): Theme =
    Theme(
      timestamp: "\e[90m",
      filename: "\e[37m",
      name: "\e[36m",
      message: "",
      duration: "\e[90m",
      extraKey: "\e[36m",
      extraValue: "",
      levelTrace: "\e[34m",
      levelDebug: "\e[94m",
      levelInfo: "\e[97m",
      levelWarn: "\e[33m",
      levelError: "\e[91m",
      levelFatal: "\e[35m",
    )

  proc colorForLevel(theme: Theme, level: string): string =
    case level
    of "TRACE": theme.levelTrace
    of "DEBUG": theme.levelDebug
    of "INFO": theme.levelInfo
    of "WARN": theme.levelWarn
    of "ERROR": theme.levelError
    of "FATAL": theme.levelFatal
    else: theme.levelInfo

  # -- Minimal TOML parser --

  type TomlTable = seq[(string, string)]  # flat list of "section.key" -> "value"

  proc parseToml(content: string): TomlTable =
    var section = ""
    for line in content.splitLines():
      let stripped = line.strip()
      if stripped.len == 0 or stripped[0] == '#':
        continue
      if stripped[0] == '[' and stripped[^1] == ']':
        section = stripped[1 ..< ^1].strip()
        continue
      let eqIdx = stripped.find('=')
      if eqIdx < 0:
        continue
      let key = stripped[0 ..< eqIdx].strip()
      var val = stripped[eqIdx + 1 .. ^1].strip()
      # Strip quotes from string values
      if val.len >= 2 and val[0] == '"' and val[^1] == '"':
        val = val[1 ..< ^1]
      let fullKey = if section.len > 0: section & "." & key else: key
      result.add((fullKey, val))

  proc getToml(table: TomlTable, key: string, default: string = ""): string =
    for (k, v) in table:
      if k == key:
        return v
    default

  # -- Config loading --

  proc findGlobalConfig(): string =
    let xdg = getEnv("XDG_CONFIG_HOME")
    if xdg.len > 0:
      let path = xdg / "lumber" / "config.toml"
      if fileExists(path): return path
    let home = getEnv("HOME")
    if home.len > 0:
      let path = home / ".config" / "lumber" / "config.toml"
      if fileExists(path): return path
    ""

  proc findProjectConfig(): string =
    var dir = getCurrentDir()
    while true:
      let path = dir / ".lumber.toml"
      if fileExists(path): return path
      let parent = parentDir(dir)
      if parent == dir: break  # reached root
      dir = parent
    ""

  proc loadConfig(path: string, theme: var Theme, fmt: var string,
                  timeFmt: var string, pretty: var bool, tz: var string,
                  level: var LogLevel) =
    if path.len == 0 or not fileExists(path):
      return
    let content = readFile(path)
    let table = parseToml(content)
    # Format
    let tmpl = getToml(table, "format.template")
    if tmpl.len > 0: fmt = tmpl
    let tf = getToml(table, "format.time_format")
    if tf.len > 0: timeFmt = tf
    # Colors
    let ts = getToml(table, "colors.timestamp")
    if ts.len > 0: theme.timestamp = colorNameToAnsi(ts)
    let fn = getToml(table, "colors.filename")
    if fn.len > 0: theme.filename = colorNameToAnsi(fn)
    let nm = getToml(table, "colors.name")
    if nm.len > 0: theme.name = colorNameToAnsi(nm)
    let msg = getToml(table, "colors.message")
    if msg.len > 0: theme.message = colorNameToAnsi(msg)
    let dur = getToml(table, "colors.duration")
    if dur.len > 0: theme.duration = colorNameToAnsi(dur)
    let ek = getToml(table, "colors.extra_key")
    if ek.len > 0: theme.extraKey = colorNameToAnsi(ek)
    let ev = getToml(table, "colors.extra_value")
    if ev.len > 0: theme.extraValue = colorNameToAnsi(ev)
    # Level colors
    let lt = getToml(table, "colors.level.trace")
    if lt.len > 0: theme.levelTrace = colorNameToAnsi(lt)
    let ld = getToml(table, "colors.level.debug")
    if ld.len > 0: theme.levelDebug = colorNameToAnsi(ld)
    let li = getToml(table, "colors.level.info")
    if li.len > 0: theme.levelInfo = colorNameToAnsi(li)
    let lw = getToml(table, "colors.level.warn")
    if lw.len > 0: theme.levelWarn = colorNameToAnsi(lw)
    let le = getToml(table, "colors.level.error")
    if le.len > 0: theme.levelError = colorNameToAnsi(le)
    let lf = getToml(table, "colors.level.fatal")
    if lf.len > 0: theme.levelFatal = colorNameToAnsi(lf)
    # Options
    let pVal = getToml(table, "options.pretty")
    if pVal == "true": pretty = true
    let tzVal = getToml(table, "options.tz")
    if tzVal.len > 0: tz = tzVal
    let lvVal = getToml(table, "options.level")
    if lvVal.len > 0:
      try: level = parseEnum[LogLevel](lvVal.toUpperAscii())
      except ValueError: discard

  proc stripAnsi(theme: var Theme) =
    theme.timestamp = ""
    theme.filename = ""
    theme.name = ""
    theme.message = ""
    theme.duration = ""
    theme.extraKey = ""
    theme.extraValue = ""
    theme.levelTrace = ""
    theme.levelDebug = ""
    theme.levelInfo = ""
    theme.levelWarn = ""
    theme.levelError = ""
    theme.levelFatal = ""

  const defaultFormat = "{timestamp} [{level}] ({filename}:{line}) {name}: {message}{duration}{extra}"

  proc levelOrd(level: string): int =
    case level.toUpperAscii()
    of "TRACE": 0
    of "DEBUG": 1
    of "INFO": 2
    of "WARN": 3
    of "ERROR": 4
    of "FATAL": 5
    else: -1

  import std/[parseopt, re]

  const Version = "0.1.0"
  const Help = """
lumber - JSON log prettifier

Usage: <app> | lumber [options]

Options:
  --level <level>     Minimum log level to display (trace, debug, info, warn, error, fatal)
  --filter <expr>     Filter logs by field value (can be repeated)
  --tz <timezone>     Timezone for timestamps (IANA name or abbreviation like PST, EST, UTC)
  --pretty            Show extra fields indented below the message
  --format <template> Custom output format using {tokens}
  --time-format <fmt> Timestamp format using strftime specifiers (default: %Y-%m-%dT%H:%M:%S)
  --no-color          Disable colored output
  --config <path>     Path to config file (default: ~/.config/lumber/config.toml)
  --init              Create a default config file at ~/.config/lumber/config.toml
  --help, -h          Show this help
  --version, -v       Show version

Format tokens:
  {timestamp}         Timestamp with offset and timezone abbreviation
  {level}             Log level (padded, e.g. "INFO ")
  {filename}          Source filename
  {line}              Source line number
  {name}              Logger name
  {message}           Log message
  {duration}          Duration if present, empty otherwise
  {extra}             Extra fields (inline or indented with --pretty)

Filter expressions:
  key=value           Exact match
  key!=value          Not equal
  key>value           Greater than (numeric)
  key>=value          Greater than or equal (numeric)
  key<value           Less than (numeric)
  key<=value          Less than or equal (numeric)
  key~pattern         Regex match

Filters match against top-level fields and extra fields.
Multiple filters are ANDed together.

Examples:
  myapp | lumber
  myapp | lumber --level warn
  myapp | lumber --filter userId=1234
  myapp | lumber --filter "latency>500" --filter "path~^/api"
  myapp | lumber --filter "timestamp>2026-07-03T12:00:00Z"
  myapp | lumber --format "{timestamp} [{level}] {name}: {message}"
  myapp | lumber --tz PST"""

  type
    FilterOp = enum
      opEq, opNeq, opGt, opGte, opLt, opLte, opRegex

    Filter = object
      key: string
      op: FilterOp
      value: string
      regex: Regex

    CliOptions = object
      level: LogLevel
      tz: string
      filters: seq[Filter]
      pretty: bool
      format: string
      timeFormat: string
      noColor: bool
      configPath: string

  proc parseFilter(expr: string): Filter =
    # Order matters — check longer operators first
    for (op, token) in [(opNeq, "!="), (opGte, ">="), (opLte, "<="),
                         (opGt, ">"), (opLt, "<"), (opRegex, "~"), (opEq, "=")]:
      let idx = expr.find(token)
      if idx > 0:
        result.key = expr[0 ..< idx]
        result.op = op
        result.value = expr[idx + token.len .. ^1]
        if op == opRegex:
          result.regex = re(result.value)
        return
    stderr.writeLine("lumber: invalid filter expression '" & expr & "'")
    quit(1)

  proc getField(j: JsonNode, key: string): JsonNode =
    ## Look up key in top-level fields first, then in extra
    result = j.getOrDefault(key)
    if result.isNil or result.kind == JNull:
      let extra = j.getOrDefault("extra")
      if not extra.isNil and extra.kind == JObject:
        result = extra.getOrDefault(key)

  proc parseTimestamp(s: string): int64 =
    ## Parses ISO 8601 timestamps to unix epoch. Supports Z, +HH:MM, -HH:MM offsets.
    if s.endsWith("Z"):
      return s.parse("yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime().toUnix()
    # Try with offset like 2026-07-03T15:27:17-07:00
    let sign = if s[^6] == '+': 1 elif s[^6] == '-': -1 else: 0
    if sign != 0 and s[^3] == ':':
      let base = s[0 ..< ^6].parse("yyyy-MM-dd'T'HH:mm:ss", utc())
      let hours = parseInt(s[^5 .. ^4])
      let mins = parseInt(s[^2 .. ^1])
      let offsetSecs = sign * (hours * 3600 + mins * 60)
      return base.toTime().toUnix() - offsetSecs.int64
    raise newException(ValueError, "unrecognized timestamp format")

  proc matchesFilter(j: JsonNode, f: Filter): bool =
    let node = getField(j, f.key)
    if node.isNil or node.kind == JNull:
      return f.op == opNeq  # missing field only matches !=
    let strVal = case node.kind
      of JString: node.getStr()
      of JInt: $node.getInt()
      of JFloat: $node.getFloat()
      of JBool: $node.getBool()
      else: $node
    case f.op
    of opEq:
      strVal == f.value
    of opNeq:
      strVal != f.value
    of opRegex:
      strVal.contains(f.regex)
    of opGt, opGte, opLt, opLte:
      # Try timestamp comparison first
      try:
        let a = parseTimestamp(strVal)
        let b = parseTimestamp(f.value)
        case f.op
        of opGt: a > b
        of opGte: a >= b
        of opLt: a < b
        of opLte: a <= b
        else: false
      except ValueError:
        # Try numeric comparison
        try:
          let a = strVal.parseFloat()
          let b = f.value.parseFloat()
          case f.op
          of opGt: a > b
          of opGte: a >= b
          of opLt: a < b
          of opLte: a <= b
          else: false
        except ValueError:
          # Fall back to string comparison
          case f.op
          of opGt: strVal > f.value
          of opGte: strVal >= f.value
          of opLt: strVal < f.value
          of opLte: strVal <= f.value
          else: false

  proc matchesAllFilters(j: JsonNode, filters: seq[Filter]): bool =
    for f in filters:
      if not matchesFilter(j, f):
        return false
    true

  const defaultConfigContent = """# lumber CLI prettifier configuration
# Place this file at ~/.config/lumber/config.toml

[format]
# template = "{timestamp} [{level}] ({filename}:{line}) {name}: {message}{duration}{extra}"
# time_format = "%Y-%m-%dT%H:%M:%S"

[colors]
# timestamp = "gray"
# filename = "light_gray"
# name = "cyan"
# message = ""
# duration = "gray"
# extra_key = "cyan"
# extra_value = ""

[colors.level]
# trace = "blue"
# debug = "light_blue"
# info = "white"
# warn = "yellow"
# error = "red"
# fatal = "magenta"

[options]
# pretty = false
# tz = "local"
# level = "trace"
"""

  proc initConfig() =
    let xdg = getEnv("XDG_CONFIG_HOME")
    let dir = if xdg.len > 0: xdg / "lumber"
              else: getEnv("HOME") / ".config" / "lumber"
    let path = dir / "config.toml"
    if fileExists(path):
      stderr.writeLine("lumber: config already exists at " & path)
      quit(1)
    createDir(dir)
    writeFile(path, defaultConfigContent)
    echo "Created " & path

  proc getOptVal(p: var OptParser): string =
    result = p.val
    if result.len == 0:
      p.next()
      if p.kind == cmdArgument:
        result = p.key
      else:
        return ""

  proc parseArgs(): CliOptions =
    result = CliOptions(level: LogLevel.TRACE, tz: "local", filters: @[],
                        pretty: false, format: "", timeFormat: "",
                        noColor: false, configPath: "")
    var p = initOptParser()
    while true:
      p.next()
      case p.kind
      of cmdEnd: break
      of cmdShortOption, cmdLongOption:
        case p.key
        of "help", "h":
          echo Help
          quit(0)
        of "version", "v":
          echo "lumber " & Version
          quit(0)
        of "init":
          initConfig()
          quit(0)
        of "level":
          let val = getOptVal(p)
          if val.len == 0:
            stderr.writeLine("lumber: --level requires a value")
            quit(1)
          try:
            result.level = parseEnum[LogLevel](val.toUpperAscii())
          except ValueError:
            stderr.writeLine("lumber: invalid level '" & val & "'. Expected: trace, debug, info, warn, error, fatal")
            quit(1)
        of "filter":
          let val = getOptVal(p)
          if val.len == 0:
            stderr.writeLine("lumber: --filter requires a value")
            quit(1)
          result.filters.add(parseFilter(val))
        of "tz":
          let val = getOptVal(p)
          if val.len == 0:
            stderr.writeLine("lumber: --tz requires a value")
            quit(1)
          result.tz = val
        of "format":
          let val = getOptVal(p)
          if val.len == 0:
            stderr.writeLine("lumber: --format requires a value")
            quit(1)
          result.format = val
        of "time-format", "timeformat":
          let val = getOptVal(p)
          if val.len == 0:
            stderr.writeLine("lumber: --time-format requires a value")
            quit(1)
          result.timeFormat = val
        of "config":
          let val = getOptVal(p)
          if val.len == 0:
            stderr.writeLine("lumber: --config requires a value")
            quit(1)
          result.configPath = val
        of "pretty":
          result.pretty = true
        of "no-color", "nocolor":
          result.noColor = true
        else:
          stderr.writeLine("lumber: unknown option '--" & p.key & "'")
          quit(1)
      of cmdArgument:
        stderr.writeLine("lumber: unexpected argument '" & p.key & "'")
        quit(1)

  type CTime {.importc: "time_t", header: "<time.h>".} = int64
  type Tm {.importc: "struct tm", header: "<time.h>".} = object

  proc localtime_r(clock: ptr CTime, result: var Tm): ptr Tm {.importc, header: "<time.h>".}
  proc c_strftime(buf: cstring, maxsize: csize_t, fmt: cstring, tp: ptr Tm): csize_t {.importc: "strftime", header: "<time.h>".}
  proc tzset() {.importc, header: "<time.h>".}

  proc resolveTimezone(tz: string): string =
    ## Maps common abbreviations to IANA timezone names
    case tz.toUpperAscii()
    of "PST", "PDT", "PT": "America/Los_Angeles"
    of "MST", "MDT", "MT": "America/Denver"
    of "CST", "CDT", "CT": "America/Chicago"
    of "EST", "EDT", "ET": "America/New_York"
    of "GMT": "Europe/London"
    of "BST": "Europe/London"
    of "CET", "CEST": "Europe/Berlin"
    of "EET", "EEST": "Europe/Helsinki"
    of "JST": "Asia/Tokyo"
    of "KST": "Asia/Seoul"
    of "CST_CHINA", "CCT": "Asia/Shanghai"
    of "IST": "Asia/Kolkata"
    of "AEST", "AEDT", "AET": "Australia/Sydney"
    of "ACST", "ACDT": "Australia/Adelaide"
    of "AWST": "Australia/Perth"
    of "NZST", "NZDT", "NZT": "Pacific/Auckland"
    of "HST": "Pacific/Honolulu"
    of "AKST", "AKDT": "America/Anchorage"
    of "AST", "ADT": "America/Halifax"
    of "BRT": "America/Sao_Paulo"
    of "SGT": "Asia/Singapore"
    of "HKT": "Asia/Hong_Kong"
    of "ICT": "Asia/Bangkok"
    of "WIB": "Asia/Jakarta"
    of "PKT": "Asia/Karachi"
    of "MSK": "Europe/Moscow"
    of "WAT": "Africa/Lagos"
    of "EAT": "Africa/Nairobi"
    of "SAST": "Africa/Johannesburg"
    else: tz  # Assume it's already an IANA name

  const defaultTimeFormat = "%Y-%m-%dT%H:%M:%S"

  proc formatWithTz(epoch: int64, timeFmt: string): (string, string, string) =
    ## Returns (formatted timestamp, offset, timezone abbreviation) using current TZ
    var t = CTime(epoch)
    var tm: Tm
    discard localtime_r(addr t, tm)
    var tsBuf: array[64, char]
    let tsLen = c_strftime(cast[cstring](addr tsBuf[0]), csize_t(64), timeFmt.cstring, addr tm)
    var ts = newString(tsLen)
    for i in 0 ..< tsLen.int:
      ts[i] = tsBuf[i]
    var offBuf: array[8, char]
    let offLen = c_strftime(cast[cstring](addr offBuf[0]), csize_t(8), "%z", addr tm)
    var offset = newString(offLen)
    for i in 0 ..< offLen.int:
      offset[i] = offBuf[i]
    # Convert "+0700" to "+07:00"
    if offset.len == 5:
      offset = offset[0..2] & ":" & offset[3..4]
    var tzBuf: array[16, char]
    let tzLen = c_strftime(cast[cstring](addr tzBuf[0]), csize_t(16), "%Z", addr tm)
    var abbr = newString(tzLen)
    for i in 0 ..< tzLen.int:
      abbr[i] = tzBuf[i]
    (ts, offset, abbr)

  proc formatTimestamp(raw: string, tz: string, timeFmt: string): string =
    try:
      let dt = raw.parse("yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
      let epoch = dt.toTime().toUnix()
      if tz.toLowerAscii() == "utc":
        if timeFmt == defaultTimeFormat:
          return dt.format("yyyy-MM-dd'T'HH:mm:ss'Z'") & " UTC"
        else:
          let prev = getEnv("TZ")
          putEnv("TZ", "UTC")
          tzset()
          let (ts, _, _) = formatWithTz(epoch, timeFmt)
          if prev.len > 0: putEnv("TZ", prev)
          else: delEnv("TZ")
          tzset()
          return ts & " UTC"
      elif tz.toLowerAscii() == "local":
        let (ts, offset, abbr) = formatWithTz(epoch, timeFmt)
        return ts & offset & " " & abbr
      else:
        let prev = getEnv("TZ")
        putEnv("TZ", resolveTimezone(tz))
        tzset()
        let (ts, offset, abbr) = formatWithTz(epoch, timeFmt)
        if prev.len > 0: putEnv("TZ", prev)
        else: delEnv("TZ")
        tzset()
        return ts & offset & " " & abbr
    except CatchableError:
      return raw

  let opts = parseArgs()

  # Build config: defaults -> global config -> project config -> CLI overrides
  var theme = defaultTheme()
  var fmt = defaultFormat
  var timeFmt = defaultTimeFormat
  var pretty = opts.pretty
  var tz = opts.tz
  var level = opts.level

  if opts.configPath.len > 0:
    loadConfig(opts.configPath, theme, fmt, timeFmt, pretty, tz, level)
  else:
    loadConfig(findGlobalConfig(), theme, fmt, timeFmt, pretty, tz, level)
    loadConfig(findProjectConfig(), theme, fmt, timeFmt, pretty, tz, level)

  # CLI overrides take precedence
  if opts.pretty: pretty = true
  if opts.tz != "local": tz = opts.tz
  if opts.level != LogLevel.TRACE: level = opts.level
  if opts.format.len > 0: fmt = opts.format
  if opts.timeFormat.len > 0: timeFmt = opts.timeFormat
  if opts.noColor or getEnv("NO_COLOR").len > 0:
    stripAnsi(theme)
    reset = ""

  proc renderExtra(displayExtra: JsonNode, theme: Theme, pretty: bool): string =
    if displayExtra.isNil or displayExtra.len == 0:
      return ""
    if pretty:
      for key, val in displayExtra:
        result &= "\n  " & theme.extraKey & key & reset & ": " &
                  theme.extraValue & $val & (if theme.extraValue.len > 0: reset else: "")
    else:
      result = " " & theme.filename & $displayExtra & reset

  proc renderLine(fmt: string, theme: Theme, pretty: bool,
                  timestamp, level, filename: string, lineNum: int,
                  name, message: string, durationStr: string,
                  displayExtra: JsonNode): string =
    var i = 0
    while i < fmt.len:
      if fmt[i] == '{':
        let closeIdx = fmt.find('}', i)
        if closeIdx > i:
          let token = fmt[i + 1 ..< closeIdx]
          case token
          of "timestamp":
            result &= theme.timestamp & timestamp & (if theme.timestamp.len > 0: reset else: "")
          of "level":
            let color = colorForLevel(theme, level)
            let padded = alignLeft(level, 5)
            result &= color & padded & (if color.len > 0: reset else: "")
          of "filename":
            result &= theme.filename & filename & (if theme.filename.len > 0: reset else: "")
          of "line":
            result &= $lineNum
          of "name":
            result &= theme.name & name & (if theme.name.len > 0: reset else: "")
          of "message":
            result &= theme.message & message & (if theme.message.len > 0: reset else: "")
          of "duration":
            result &= durationStr
          of "extra":
            result &= renderExtra(displayExtra, theme, pretty)
          else:
            result &= fmt[i .. closeIdx]
          i = closeIdx + 1
        else:
          result &= fmt[i]
          inc i
      else:
        result &= fmt[i]
        inc i

  var line: string
  while stdin.readLine(line):
    try:
      let j = parseJson(line)
      let jLevel = j.getOrDefault("level").getStr("")
      if levelOrd(jLevel) < ord(level):
        continue
      if opts.filters.len > 0 and not matchesAllFilters(j, opts.filters):
        continue
      let timestamp = j.getOrDefault("timestamp").getStr("")
      let displayTs = formatTimestamp(timestamp, tz, timeFmt)
      let filename = j.getOrDefault("filename").getStr("")
      let lineNum = j.getOrDefault("line").getInt(0)
      let message = j.getOrDefault("message").getStr("")
      let extra = j.getOrDefault("extra")
      let name = j.getOrDefault("name").getStr("")
      var durationStr = ""
      var displayExtra: JsonNode = nil
      if not extra.isNil and extra.kind == JObject and extra.len > 0:
        if extra.hasKey("duration_ms"):
          let ms = extra["duration_ms"].getFloat()
          if ms >= 1000.0:
            durationStr = " " & theme.duration & "(" & formatFloat(ms / 1000.0, ffDecimal, 2) & "s)" &
                          (if theme.duration.len > 0: reset else: "")
          else:
            durationStr = " " & theme.duration & "(" & $ms.int & "ms)" &
                          (if theme.duration.len > 0: reset else: "")
          if extra.len > 1:
            displayExtra = newJObject()
            for key, val in extra:
              if key != "duration_ms":
                displayExtra[key] = val
        else:
          displayExtra = extra
      let output = renderLine(fmt, theme, pretty, displayTs, jLevel, filename,
                              lineNum, name, message, durationStr, displayExtra)
      stdout.writeLine(output)
    except JsonParsingError:
      stdout.writeLine(line)
