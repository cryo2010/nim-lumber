## lumber CLI - JSON log prettifier
##
## Reads JSON log lines from stdin and prints colored, human-readable output.

import std/[json, strutils, os, times, parseopt]
import regex
import ../lumber

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
    highlightLine: string
    highlightMatch: string

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

proc bgColorNameToAnsi(name: string): string =
  ## Maps color names to ANSI background escape codes.
  case name.toLowerAscii().replace("_", "")
  of "black": "\e[40m"
  of "red": "\e[41m"
  of "green": "\e[42m"
  of "yellow": "\e[43m"
  of "blue": "\e[44m"
  of "magenta": "\e[45m"
  of "cyan": "\e[46m"
  of "white": "\e[107m"
  of "gray", "grey": "\e[100m"
  of "lightgray", "lightgrey": "\e[47m"
  of "lightred", "brightred": "\e[101m"
  of "lightgreen", "brightgreen": "\e[102m"
  of "lightyellow", "brightyellow": "\e[103m"
  of "lightblue", "brightblue": "\e[104m"
  of "lightmagenta", "brightmagenta": "\e[105m"
  of "lightcyan", "brightcyan": "\e[106m"
  of "darkgray": "\e[48;5;236m"
  of "darkergray": "\e[48;5;238m"
  of "subtlegray": "\e[48;5;234m"
  of "", "none": ""
  else:
    # Support 256-color codes like "238" directly
    try:
      let code = parseInt(name)
      if code >= 0 and code <= 255:
        return "\e[48;5;" & $code & "m"
    except ValueError:
      discard
    ""

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
    highlightLine: "\e[48;5;236m",
    highlightMatch: "\e[48;5;240m",
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

const configVersion = 1

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
  # Version check
  let ver = getToml(table, "version")
  if ver.len > 0 and ver != $configVersion:
    stderr.writeLine "lumber: config version " & ver & " is not supported (expected " & $configVersion & ")"
    quit(1)
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
  # Highlight colors (background)
  let hl = getToml(table, "colors.highlight_line")
  if hl.len > 0: theme.highlightLine = bgColorNameToAnsi(hl)
  let hm = getToml(table, "colors.highlight_match")
  if hm.len > 0: theme.highlightMatch = bgColorNameToAnsi(hm)
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
  theme.highlightLine = ""
  theme.highlightMatch = ""

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

const Version = "0.1.0"
const Help = """
lumber - JSON log prettifier

Usage: <app> | lumber [options]

Options:
  --level <level>       Minimum log level to display (trace, debug, info, warn, error, fatal)
  --filter <expr>       Filter logs by field value (can be repeated)
  --highlight <regex>   Highlight lines matching regex (can be repeated, alias: --hl)
  --tz <timezone>       Timezone for timestamps (IANA name or abbreviation like PST, EST, UTC)
  --pretty              Show extra fields indented below the message
  --format <template>   Custom output format using {tokens}
  --time-format <fmt>   Timestamp format using strftime specifiers (default: %Y-%m-%dT%H:%M:%S)
  --no-color            Disable colored output (also respects NO_COLOR and CI env vars)
  --config <path>       Path to config file (default: ~/.config/lumber/config.toml)
  --init                Create a default config file at ~/.config/lumber/config.toml
  --help, -h            Show this help
  --version, -v         Show version

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
  myapp | lumber --highlight "req-7f3a"
  myapp | lumber --hl "error|timeout"
  myapp | lumber --format "{timestamp} [{level}] {name}: {message}"
  myapp | lumber --tz PST"""

type
  FilterOp = enum
    opEq, opNeq, opGt, opGte, opLt, opLte, opRegex

  Filter = object
    key: string
    op: FilterOp
    value: string
    regex: Regex2

  CliOptions = object
    level: LogLevel
    tz: string
    filters: seq[Filter]
    highlights: seq[Regex2]
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
        result.regex = re2(result.value)
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
version = 1

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
# highlight_line = "236"
# highlight_match = "240"

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
                      highlights: @[], pretty: false, format: "",
                      timeFormat: "", noColor: false, configPath: "")
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
      of "highlight", "hl":
        let val = getOptVal(p)
        if val.len == 0:
          stderr.writeLine("lumber: --highlight requires a value")
          quit(1)
        result.highlights.add(re2("(?i)" & val))
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
    # Extract milliseconds if present (e.g. ".139" from "...ss.139Z")
    var msStr = ""
    var parseStr = raw
    let dotIdx = raw.rfind('.')
    if dotIdx > 0 and raw.endsWith("Z"):
      msStr = raw[dotIdx ..< ^1]  # ".139"
      parseStr = raw[0 ..< dotIdx] & "Z"
    let dt = parseStr.parse("yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    let epoch = dt.toTime().toUnix()
    if tz.toLowerAscii() == "utc":
      if timeFmt == defaultTimeFormat:
        return dt.format("yyyy-MM-dd'T'HH:mm:ss") & msStr & "Z UTC"
      else:
        let prev = getEnv("TZ")
        putEnv("TZ", "UTC")
        tzset()
        let (ts, _, _) = formatWithTz(epoch, timeFmt)
        if prev.len > 0: putEnv("TZ", prev)
        else: delEnv("TZ")
        tzset()
        return ts & msStr & " UTC"
    elif tz.toLowerAscii() == "local":
      let (ts, offset, abbr) = formatWithTz(epoch, timeFmt)
      return ts & msStr & offset & " " & abbr
    else:
      let prev = getEnv("TZ")
      putEnv("TZ", resolveTimezone(tz))
      tzset()
      let (ts, offset, abbr) = formatWithTz(epoch, timeFmt)
      if prev.len > 0: putEnv("TZ", prev)
      else: delEnv("TZ")
      tzset()
      return ts & msStr & offset & " " & abbr
  except CatchableError:
    return raw

# -- Rendering --

proc renderException(exc: JsonNode, theme: Theme, indent: string): string =
  ## Render a single exception object with its stack trace.
  for key, val in exc:
    if key == "stackTrace" and val.kind == JString:
      result &= "\n" & indent & theme.extraKey & key & reset & ":"
      let trace = val.getStr()
      for frame in trace.strip().splitLines():
        if frame.len > 0:
          result &= "\n" & indent & "  " & theme.extraValue & frame & (if theme.extraValue.len > 0: reset else: "")
    else:
      result &= "\n" & indent & theme.extraKey & key & reset & ": " &
                theme.extraValue & $val & (if theme.extraValue.len > 0: reset else: "")

proc hasExceptionFields(node: JsonNode): bool =
  node.hasKey("stackTrace") or node.hasKey("errors")

proc renderExtra(displayExtra: JsonNode, theme: Theme, pretty: bool): string =
  if displayExtra.isNil or displayExtra.len == 0:
    return ""
  if pretty or hasExceptionFields(displayExtra):
    for key, val in displayExtra:
      if key == "errors" and val.kind == JArray:
        for i, exc in val.elems:
          result &= "\n  " & theme.extraKey & "exception " & $(i + 1) & reset & ":"
          result &= renderException(exc, theme, "    ")
      elif key == "stackTrace" and val.kind == JString:
        result &= "\n  " & theme.extraKey & key & reset & ":"
        let trace = val.getStr()
        for frame in trace.strip().splitLines():
          if frame.len > 0:
            result &= "\n    " & theme.extraValue & frame & (if theme.extraValue.len > 0: reset else: "")
      else:
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

# -- Highlighting --

proc collectValues(j: JsonNode): seq[string] =
  ## Collect all string representations of field values for highlight matching.
  for key, val in j:
    case val.kind
    of JString: result.add(val.getStr())
    of JInt: result.add($val.getInt())
    of JFloat: result.add($val.getFloat())
    of JBool: result.add($val.getBool())
    of JObject:
      for subVals in collectValues(val):
        result.add(subVals)
    of JArray:
      for elem in val.elems:
        if elem.kind == JString: result.add(elem.getStr())
    of JNull: discard

proc highlightMatches(output: string, highlights: seq[Regex2],
                      theme: Theme, reset: string): string =
  ## Apply match-level background highlighting to matched text in the output.
  result = output
  for hl in highlights:
    var newResult = ""
    var pos = 0
    while pos < result.len:
      # Skip ANSI escape sequences
      if result[pos] == '\e':
        let mIdx = result.find('m', pos)
        if mIdx >= 0:
          newResult &= result[pos .. mIdx]
          pos = mIdx + 1
          continue
      var m: RegexMatch2
      if not find(result, hl, m, start = pos):
        newResult &= result[pos .. ^1]
        break
      let first = m.boundaries.a
      let last = m.boundaries.b
      # Add text before match
      if first > pos:
        newResult &= result[pos ..< first]
      # Add highlighted match
      newResult &= theme.highlightMatch & result[first .. last] & reset & theme.highlightLine
      # Guard against zero-width matches to keep the scan advancing
      pos = max(last + 1, first + 1)
    result = newResult

# -- Main --

when isMainModule:
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
  if opts.noColor or getEnv("NO_COLOR").len > 0 or getEnv("CI").len > 0:
    stripAnsi(theme)
    reset = ""

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
      var output = renderLine(fmt, theme, pretty, displayTs, jLevel, filename,
                              lineNum, name, message, durationStr, displayExtra)
      # Apply highlighting if any pattern matches any field value
      if opts.highlights.len > 0:
        let values = collectValues(j)
        var matched = false
        for val in values:
          for hl in opts.highlights:
            if val.contains(hl):
              matched = true
              break
          if matched: break
        if matched:
          # Replace all resets with reset+bg so background persists across tokens
          output = output.replace(reset, reset & theme.highlightLine)
          output = theme.highlightLine & highlightMatches(output, opts.highlights, theme, reset) & "\e[K" & reset
      stdout.writeLine(output)
    except JsonParsingError:
      stdout.writeLine(line)
