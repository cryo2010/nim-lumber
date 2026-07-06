# lumber

[![CI](https://github.com/cryo2010/nim-lumber/actions/workflows/ci.yml/badge.svg)](https://github.com/cryo2010/nim-lumber/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A compile-time optimized JSON logger for Nim with a built-in CLI prettifier.

<img src="docs/screenshot.png" alt="lumber CLI output" width="100%">

## Features

- **Compile-time level filtering** - log calls below the threshold are eliminated from the binary entirely, with zero runtime cost; per-logger runtime levels handle the rest
- **Structured JSON output** - every log line is valid JSON with timestamp, level, name, filename, line number, and message
- **Structured messages** - named `key=value` arguments become discrete JSON fields, queryable by log aggregators; `{0}`-style placeholders interpolate positional arguments
- **Exception logging** - pass any `ref Exception` and lumber extracts the message, type, and stack trace automatically
- **Contextual logging** - attach fields per logger, inherit them through child loggers, or scope them to a call stack with thread-local `withContext`
- **Middleware** - enrich, transform, or suppress log records at runtime; rate limiter, sampler, and redaction included
- **Flexible outputs** - write to stdout, files, or any custom `Stream` simultaneously, with built-in size/time rotation, buffering, a background-thread async writer, and automatic flush on exit
- **Thread-safe** - safe for concurrent use from multiple threads
- **Minimal dependencies** - the Nim standard library plus a single pure-Nim package ([regex](https://github.com/nitely/nim-regex)), compiled in statically; no C libraries or runtime dependencies
- **CLI prettifier** - pipe JSON logs through the `lumber` binary for colored, human-readable output with level filtering, field filtering, timezone support, and customizable format/colors via TOML config

## Installation

```
nimble install lumber
```

## Quick Start

```nim
import lumber

var logger = newLogger()
logger.info("Hello, world!")
```

> **Tip:** If you prefer namespaced access (`lumber.outputs`, `lumber.use`, etc.), use `from lumber import nil`. All examples below use plain `import lumber` for brevity.

Output:

```json
{"timestamp":"2026-07-06T20:44:45.742Z","level":"INFO","name":"mymodule","filename":"mymodule.nim","line":4,"message":"Hello, world!"}
```

Piped through the `lumber` CLI prettifier:

```
2026-07-06T13:44:45.742-07:00 PDT [INFO ] (mymodule.nim:4) mymodule: Hello, world!
```

## Compile-Time Level Filtering

Set the minimum log level at compile time with `-d:lumberLevel`. Calls below this level produce no code in the binary.

```sh
nim c -d:lumberLevel=WARN myapp.nim
```

With this flag, `logger.trace()`, `logger.debug()`, and `logger.info()` are completely eliminated -- arguments are type-checked but never evaluated at runtime.

Available levels (in order): `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`

The default is `TRACE` (all levels enabled).

## API

### Creating a Logger

```nim
# Name defaults to the calling module's filename
var logger = newLogger()

# Named logger with extra context (JsonNode)
var logger = newLogger(name = "api", extra = %* {"service": "my-app"})

# Extra also accepts Nim objects — fields are serialized automatically
type AppContext = object
  service: string
  version: string

var logger = newLogger(name = "api", extra = AppContext(service: "my-app", version: "1.2.0"))
```

### Log Levels

```nim
logger.trace("Detailed tracing info")
logger.debug("Debug information")
logger.info("General information")
logger.warn("Warning")
logger.error("Error occurred")
logger.fatal("Fatal error")
```

Output:

```json
{"timestamp":"2026-07-06T20:44:46.592Z","level":"TRACE","name":"app","filename":"app.nim","line":4,"message":"Detailed tracing info"}
{"timestamp":"2026-07-06T20:44:46.592Z","level":"DEBUG","name":"app","filename":"app.nim","line":5,"message":"Debug information"}
{"timestamp":"2026-07-06T20:44:46.592Z","level":"INFO","name":"app","filename":"app.nim","line":6,"message":"General information"}
{"timestamp":"2026-07-06T20:44:46.592Z","level":"WARN","name":"app","filename":"app.nim","line":7,"message":"Warning"}
{"timestamp":"2026-07-06T20:44:46.592Z","level":"ERROR","name":"app","filename":"app.nim","line":8,"message":"Error occurred"}
{"timestamp":"2026-07-06T20:44:46.592Z","level":"FATAL","name":"app","filename":"app.nim","line":9,"message":"Fatal error"}
```

Piped through `lumber`:

```
2026-07-06T13:44:46.592-07:00 PDT [TRACE] (app.nim:4) app: Detailed tracing info
2026-07-06T13:44:46.592-07:00 PDT [DEBUG] (app.nim:5) app: Debug information
2026-07-06T13:44:46.592-07:00 PDT [INFO ] (app.nim:6) app: General information
2026-07-06T13:44:46.592-07:00 PDT [WARN ] (app.nim:7) app: Warning
2026-07-06T13:44:46.592-07:00 PDT [ERROR] (app.nim:8) app: Error occurred
2026-07-06T13:44:46.592-07:00 PDT [FATAL] (app.nim:9) app: Fatal error
```

### Runtime Level Filtering

Each logger has a `level` field that short-circuits before building the log record, running middleware, or serializing JSON.

```nim
var logger = newLogger(name = "api")
logger.level = LogLevel.WARN  # only WARN+ will be processed
logger.info("skipped")        # no work done
logger.error("processed")     # goes through normally
```

Output — only the ERROR line is emitted:

```json
{"timestamp":"2026-07-06T20:44:47.409Z","level":"ERROR","name":"api","filename":"app.nim","line":6,"message":"processed"}
```

Piped through `lumber`:

```
2026-07-06T13:44:47.409-07:00 PDT [ERROR] (app.nim:6) api: processed
```

Child loggers inherit the parent's level.

### String Interpolation

Use `{0}`, `{1}`, etc. to interpolate arguments into the message. Extra arguments are appended. Any type with a `$` operator works; objects are prefixed with their type name.

```nim
logger.info("User {0} logged in from {1}", "alice", "10.0.0.1")
logger.info("Values:", 1, 2, 3)

type User = object
  name: string
  age: int

logger.info("Found {0}", User(name: "Dude", age: 40))
```

Output:

```json
{"timestamp":"2026-07-06T20:44:48.243Z","level":"INFO","name":"api","filename":"app.nim","line":4,"message":"User alice logged in from 10.0.0.1"}
{"timestamp":"2026-07-06T20:44:48.243Z","level":"INFO","name":"api","filename":"app.nim","line":5,"message":"Values: 1 2 3"}
{"timestamp":"2026-07-06T20:44:48.243Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"Found User(name: \"Dude\", age: 40)"}
```

Piped through `lumber`:

```
2026-07-06T13:44:48.243-07:00 PDT [INFO ] (app.nim:4) api: User alice logged in from 10.0.0.1
2026-07-06T13:44:48.243-07:00 PDT [INFO ] (app.nim:5) api: Values: 1 2 3
2026-07-06T13:44:48.243-07:00 PDT [INFO ] (app.nim:11) api: Found User(name: "Dude", age: 40)
```

### Structured Messages

Named arguments become discrete fields in the `extra` JSON object, keeping them queryable by log aggregators rather than buried in a text string.

```nim
let reqId = "req-abc"
logger.info("User logged in", user="alice", ip="10.0.0.1")

# Mix positional interpolation with named fields
logger.info("Request {0} completed", reqId, status=200, latency=42)
```

Output:

```json
{"timestamp":"2026-07-06T20:44:49.081Z","level":"INFO","name":"api","filename":"app.nim","line":5,"message":"User logged in","extra":{"user":"alice","ip":"10.0.0.1"}}
{"timestamp":"2026-07-06T20:44:49.082Z","level":"INFO","name":"api","filename":"app.nim","line":6,"message":"Request req-abc completed","extra":{"status":200,"latency":42}}
```

Piped through `lumber --pretty`:

```
2026-07-06T13:44:49.081-07:00 PDT [INFO ] (app.nim:5) api: User logged in
  user: "alice"
  ip: "10.0.0.1"
2026-07-06T13:44:49.082-07:00 PDT [INFO ] (app.nim:6) api: Request req-abc completed
  status: 200
  latency: 42
```

Message-level fields override logger extra on key collision:

```nim
var logger = newLogger(extra = %* {"user": "system"})
logger.info("login", user="alice")
```

Output — `user` is `"alice"`, not `"system"`:

```json
{"timestamp":"2026-07-06T20:44:49.908Z","level":"INFO","name":"app","filename":"app.nim","line":4,"message":"login","extra":{"user":"alice"}}
```

Piped through `lumber --pretty`:

```
2026-07-06T13:44:49.908-07:00 PDT [INFO ] (app.nim:4) app: login
  user: "alice"
```

### Exception Logging

Pass any `ref Exception` as an argument — lumber automatically extracts the message, type name, and stack trace into structured fields.

```nim
proc loadConfig() =
  raise newException(IOError, "file not found: config.toml")

proc initApp() =
  loadConfig()

try:
  initApp()
except IOError as e:
  logger.error("Failed to load config", e)
```

Output:

```json
{"timestamp":"2026-07-06T20:44:50.747Z","level":"ERROR","name":"api","filename":"app.nim","line":14,"message":"Failed to load config","extra":{"error":"file not found: config.toml","errorType":"IOError","stackTrace":"app.nim(12) app\napp.nim(9) initApp\napp.nim(6) loadConfig\n"}}
```

Piped through `lumber` — stack traces are rendered on separate lines automatically:

```
2026-07-06T13:44:50.747-07:00 PDT [ERROR] (app.nim:14) api: Failed to load config
  error: "file not found: config.toml"
  errorType: "IOError"
  stackTrace:
    app.nim(12) app
    app.nim(9) initApp
    app.nim(6) loadConfig
```

The exception can be passed positionally (as above), as a keyword argument (`error=e` — the key is ignored), or mixed with other fields (`logger.error("Failed", e, retries=3)`). Multiple exceptions are stored as an array:

```nim
logger.error("Multiple failures", e1, e2)
```

Output:

```json
{"timestamp":"2026-07-06T20:44:50.747Z","level":"ERROR","name":"api","filename":"app.nim","line":18,"message":"Multiple failures","extra":{"errors":[{"error":"bad input","errorType":"ValueError"},{"error":"disk full","errorType":"IOError"}]}}
```

Piped through `lumber`:

```
2026-07-06T13:44:50.747-07:00 PDT [ERROR] (app.nim:18) api: Multiple failures
  exception 1:
    error: "bad input"
    errorType: "ValueError"
  exception 2:
    error: "disk full"
    errorType: "IOError"
```

### Timing Blocks

Measure the duration of a block and log it automatically with `duration_ms` in extra:

```nim
# Default: logs at INFO level
logger.time("db query"):
  db.exec("SELECT * FROM users")

# Custom level
logger.time(LogLevel.DEBUG, "template render"):
  renderPage()
```

Output:

```json
{"timestamp":"2026-07-06T20:46:29.020Z","level":"INFO","name":"db","filename":"app.nim","line":5,"message":"db query","extra":{"duration_ms":137.24900000000002}}
{"timestamp":"2026-07-06T20:46:29.041Z","level":"DEBUG","name":"db","filename":"app.nim","line":11,"message":"template render","extra":{"duration_ms":21.38100000000001}}
```

Piped through `lumber` — the duration is displayed inline after the message:

```
2026-07-06T13:46:29.020-07:00 PDT [INFO ] (app.nim:5) db: db query (137ms)
2026-07-06T13:46:29.041-07:00 PDT [DEBUG] (app.nim:11) db: template render (21ms)
```

### Child Loggers

Create child loggers that inherit the parent's name, level, and extra fields. Child extra fields are merged on top of the parent's.

```nim
var logger = newLogger(name = "api", extra = %* {"service": "my-app"})

var reqLogger = logger.child(extra = %* {"requestId": "abc-123"})
reqLogger.info("Handling request")

var dbLogger = reqLogger.child(name = "db", extra = %* {"query": "SELECT ..."})
dbLogger.error("Connection timeout")
```

Output:

```json
{"timestamp":"2026-07-06T20:44:52.516Z","level":"INFO","name":"api","filename":"app.nim","line":6,"message":"Handling request","extra":{"service":"my-app","requestId":"abc-123"}}
{"timestamp":"2026-07-06T20:44:52.516Z","level":"ERROR","name":"db","filename":"app.nim","line":9,"message":"Connection timeout","extra":{"service":"my-app","requestId":"abc-123","query":"SELECT ..."}}
```

Piped through `lumber --pretty`:

```
2026-07-06T13:44:52.516-07:00 PDT [INFO ] (app.nim:6) api: Handling request
  service: "my-app"
  requestId: "abc-123"
2026-07-06T13:44:52.516-07:00 PDT [ERROR] (app.nim:9) db: Connection timeout
  service: "my-app"
  requestId: "abc-123"
  query: "SELECT ..."
```

Child extra also accepts Nim objects:

```nim
type DbContext = object
  host: string
  port: int

var dbLogger = reqLogger.child(name = "db", extra = DbContext(host: "db.local", port: 5432))
```

### Thread-Local Context

Use `withContext` to attach ambient fields that any logger on the current thread will pick up — without passing the logger through function calls.

```nim
var logger = newLogger(name = "api")

withContext(%* {"requestId": "abc-123", "userId": 42}):
  logger.info("handling request")

  # Nesting adds fields, restores on exit
  withContext(%* {"orderId": "ord-789"}):
    logger.info("processing payment")

  logger.info("done")
```

Output — note `orderId` appears only inside the nested block:

```json
{"timestamp":"2026-07-06T20:44:53.346Z","level":"INFO","name":"api","filename":"app.nim","line":6,"message":"handling request","extra":{"requestId":"abc-123","userId":42}}
{"timestamp":"2026-07-06T20:44:53.346Z","level":"INFO","name":"api","filename":"app.nim","line":9,"message":"processing payment","extra":{"requestId":"abc-123","userId":42,"orderId":"ord-789"}}
{"timestamp":"2026-07-06T20:44:53.346Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"done","extra":{"requestId":"abc-123","userId":42}}
```

Piped through `lumber --pretty`:

```
2026-07-06T13:44:53.346-07:00 PDT [INFO ] (app.nim:6) api: handling request
  requestId: "abc-123"
  userId: 42
2026-07-06T13:44:53.346-07:00 PDT [INFO ] (app.nim:9) api: processing payment
  requestId: "abc-123"
  userId: 42
  orderId: "ord-789"
2026-07-06T13:44:53.346-07:00 PDT [INFO ] (app.nim:11) api: done
  requestId: "abc-123"
  userId: 42
```

Priority order (highest wins): message fields > logger extra > thread-local context.

### Middleware

Middleware functions receive a mutable `LogRecord` and return `true` to continue the chain or `false` to suppress the record.

```nim
# Enrich every log line
use proc(record: var LogRecord): bool =
  if record.extra.isNil:
    record.extra = newJObject()
  record.extra["env"] = %"production"
  true

# Suppress debug logs at runtime
use proc(record: var LogRecord): bool =
  record.level != "DEBUG"

var logger = newLogger(name = "api")
logger.info("request served")
logger.debug("cache miss")  # suppressed by the second middleware

# Clear all middleware
clearMiddleware()
```

Output — the INFO line is enriched with `env`; the DEBUG line is suppressed:

```json
{"timestamp":"2026-07-06T20:44:54.172Z","level":"INFO","name":"api","filename":"app.nim","line":15,"message":"request served","extra":{"env":"production"}}
```

Piped through `lumber --pretty`:

```
2026-07-06T13:44:54.172-07:00 PDT [INFO ] (app.nim:15) api: request served
  env: "production"
```

The `LogRecord` type:

```nim
type LogRecord* = object
  timestamp*: string
  level*: string
  name*: string
  filename*: string
  line*: int
  message*: string
  extra*: JsonNode
```

### Built-in Middleware

Import `lumber/middleware` for ready-made middleware:

```nim
import lumber
import lumber/middleware
import std/os

# Rate limiter: allow max 5 messages per second from the same source location
use newRateLimiter(window = 1.0, maxBurst = 5)

var logger = newLogger(name = "api")
for i in 1 .. 13:
  if i == 13:
    sleep(1100)  # let the rate-limit window expire
  logger.info("Event {0}", i)
```

Events 6-12 are dropped. When the window expires, the next emitted message from that source location includes a `suppressed` field with the count of dropped messages:

```json
{"timestamp":"2026-07-06T20:46:30.041Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"Event 1"}
{"timestamp":"2026-07-06T20:46:30.042Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"Event 2"}
{"timestamp":"2026-07-06T20:46:30.042Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"Event 3"}
{"timestamp":"2026-07-06T20:46:30.042Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"Event 4"}
{"timestamp":"2026-07-06T20:46:30.042Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"Event 5"}
{"timestamp":"2026-07-06T20:46:31.143Z","level":"INFO","name":"api","filename":"app.nim","line":11,"message":"Event 13","extra":{"suppressed":7}}
```

Piped through `lumber --pretty`:

```
2026-07-06T13:46:30.041-07:00 PDT [INFO ] (app.nim:11) api: Event 1
2026-07-06T13:46:30.042-07:00 PDT [INFO ] (app.nim:11) api: Event 2
2026-07-06T13:46:30.042-07:00 PDT [INFO ] (app.nim:11) api: Event 3
2026-07-06T13:46:30.042-07:00 PDT [INFO ] (app.nim:11) api: Event 4
2026-07-06T13:46:30.042-07:00 PDT [INFO ] (app.nim:11) api: Event 5
2026-07-06T13:46:31.143-07:00 PDT [INFO ] (app.nim:11) api: Event 13
  suppressed: 7
```

The remaining built-in middleware (the pattern redactor takes a compiled regex, so `import regex` where you use it):

```nim
# Sampler: log 1 in every 100 messages
use newSampler(rate = 100)

# Level sampler: sample DEBUG/TRACE at 1-in-50, always pass WARN+
use newLevelSampler(level = LogLevel.DEBUG, rate = 50)

# Redact sensitive fields using built-in defaults
use newRedactor()

# Override with a custom key list (replaces defaults entirely)
use newRedactor(@["password", "token", "ssn"])

# Redact values matching a regex pattern (e.g. credit card numbers)
use newPatternRedactor(re2"\d{4}-\d{4}-\d{4}-\d{4}")

# Custom placeholder
use newRedactor(@["apiKey"], placeholder = "***")
```

Default redacted keys: `api_key`, `api_secret`, `apiKey`, `apiSecret`, `authorization`, `card_number`, `cardNumber`, `cookie`, `credit_card`, `creditCard`, `cvv`, `passwd`, `password`, `pin`, `secret`, `ssn`, `token`.

### Outputs and Routing

Each output has a `stream`, an optional `level` filter, and an optional `names` filter. By default, logs write to stdout at all levels.

```nim
import std/streams

outputs = @[
  # Console: all levels, all loggers
  Output(stream: newFileStream(stdout)),

  # File: only ERROR and above
  Output(stream: newFileStream("error.log", fmAppend), level: LogLevel.ERROR),

  # File: only logs from the "db" logger
  Output(stream: newFileStream("db.log", fmAppend), names: @["db"]),
]
```

The `Output` type:

```nim
type Output* = object
  stream*: Stream
  level*: LogLevel = LogLevel.TRACE  # default: accept all levels
  names*: seq[string] = @[]             # default: accept all logger names
```

### Rotating File Streams

#### Size-based rotation

Rotates when the file exceeds a size limit. Keeps numbered backups (`app.log.1`, `app.log.2`, etc.).

```nim
# 10MB max, keep 5 backup files (default)
Output(stream: newRollingFileStream("app.log"))

# Custom: 50MB max, keep 10 backups
Output(stream: newRollingFileStream("app.log", maxBytes = 50_000_000, maxFiles = 10))
```

#### Time-based rotation

Rotates at midnight UTC. Keeps dated backups (`app.2026-07-02.log`, `app.2026-07-01.log`, etc.).

```nim
# Keep 30 days of logs (default)
Output(stream: newDailyFileStream("app.log"))

# Keep 7 days
Output(stream: newDailyFileStream("app.log", maxFiles = 7))
```

### Buffered Streams

Wrap any stream with `newBufferedStream` for high-throughput logging. Uses a hybrid flush strategy inspired by Go's zap logger:

- **Flush on buffer full** — when accumulated data exceeds `maxSize` (default: 4096 bytes)
- **Flush on timer** — when `flushIntervalMs` has elapsed since last flush (default: 1000ms)
- **Flush on level** — immediately on ERROR or FATAL (configurable via `flushLevel`)
- **Flush on close** — always flushes remaining data

```nim
# Default settings (4KB buffer, flush every 1s or on ERROR+)
outputs = @[Output(stream: newBufferedStream(newFileStream(stdout)))]

# Custom: 8KB buffer, flush every 500ms, immediate flush on WARN+
outputs = @[Output(stream: newBufferedStream(
  newFileStream("app.log", fmAppend),
  maxSize = 8192,
  flushIntervalMs = 500,
  flushLevel = LogLevel.WARN
))]

# Combine with rotating files
outputs = @[Output(stream: newBufferedStream(newRollingFileStream("app.log")))]
```

In benchmarks, buffered streams are ~1.5-2.3x faster than unbuffered, with the gap widening with more outputs.

### Async Streams

Wrap any stream with `newAsyncStream` for non-blocking I/O. Log calls push data onto a channel and return immediately; a background thread handles the writes.

```nim
# Async console output
outputs = @[Output(stream: newAsyncStream(newFileStream(stdout)))]

# Async rotating file
outputs.add(Output(stream: newAsyncStream(newRollingFileStream("app.log"))))

# Close to flush and join the writer thread
for o in outputs:
  o.stream.close()
```

## CLI Prettifier

The `lumber` binary reads JSON log lines from stdin and prints colored, formatted output.

```sh
myapp | lumber
```

Output format (extra fields render inline by default; use `--pretty` to indent them on separate lines):

```
2026-07-06T13:44:49.081-07:00 PDT [INFO ] (app.nim:5) api: User logged in {"user":"alice","ip":"10.0.0.1"}
```

Levels are color-coded: TRACE (blue), DEBUG (light blue), INFO (white), WARN (yellow), ERROR (red), FATAL (magenta).

### Options

```
--level <level>       Minimum log level to display
--filter <expr>       Filter logs by field value (can be repeated)
--highlight <regex>   Highlight lines matching regex (can be repeated, alias: --hl)
--tz <timezone>       Timezone for timestamps (IANA name or abbreviation)
--format <template>   Output format template
--time-format <fmt>   Timestamp format using strftime specifiers
--pretty              Indent extra fields on separate lines
--no-color            Disable colored output (also respects NO_COLOR env var)
--config <path>       Path to config file
--init                Create default config file at ~/.config/lumber/config.toml
--help, -h            Show help
--version, -v         Show version
```

### Field Filtering

Filter logs by field values using expressions. Filters match against top-level fields (`timestamp`, `level`, `name`, `message`) and `extra` fields. Multiple filters are ANDed together.

```sh
# Exact match
myapp | lumber --filter userId=1234

# Not equal
myapp | lumber --filter "env!=production"

# Numeric comparison
myapp | lumber --filter "latency>500"
myapp | lumber --filter "status>=400"

# Regex match
myapp | lumber --filter "path~^/api"
myapp | lumber --filter "message~timeout|refused"

# Timestamp filtering (supports UTC and offset formats)
myapp | lumber --filter "timestamp>2026-07-03T12:00:00Z"
myapp | lumber --filter "timestamp>2026-07-03T15:00:00-07:00"

# Combine multiple filters
myapp | lumber --filter userId=1234 --filter "latency>500"
```

### Highlighting

Highlight lines where any field value matches a regex. Unlike `--filter`, non-matching lines are still shown — matching lines get a background tint, and the matched text itself gets a brighter highlight. Matching is case-insensitive.

```sh
# Highlight a request ID across interleaved logs
myapp | lumber --highlight "req-7f3a"

# Short alias
myapp | lumber --hl "timeout|refused"

# Multiple patterns
myapp | lumber --hl "alice" --hl "error"
```

The background extends to the terminal's right edge. Highlight colors are configurable in the config file via `colors.highlight_line` (whole line background) and `colors.highlight_match` (matched text background). Both accept 256-color codes or named colors.

### Timezone Support

Timestamps are displayed in local time by default. Use `--tz` with an IANA timezone name or common abbreviation:

```sh
myapp | lumber --tz=UTC
myapp | lumber --tz=PST
myapp | lumber --tz=America/New_York
myapp | lumber --tz=JST
```

The displayed timestamp includes the UTC offset and abbreviated timezone name for clarity:

```
2026-07-03T15:27:17-07:00 PDT [INFO ] ...
2026-07-03T18:27:17-04:00 EDT [INFO ] ...
```

Non-JSON lines pass through unchanged.

### Output Format

Customize the output layout with `--format`. Available placeholders: `{timestamp}`, `{level}`, `{filename}`, `{line}`, `{name}`, `{message}`, `{duration}`, `{extra}`.

```sh
# Minimal output
myapp | lumber --format "{level} {message}"

# Without filename/line
myapp | lumber --format "{timestamp} [{level}] {name}: {message}{extra}"
```

### Timestamp Format

Customize how timestamps are displayed with `--time-format` using strftime specifiers:

```sh
# Time only
myapp | lumber --time-format "%H:%M:%S"

# Short date
myapp | lumber --time-format "%b %d %H:%M"
```

The default format is `%Y-%m-%dT%H:%M:%S`. The UTC offset and timezone abbreviation are always appended after the formatted time.

### Configuration File

Lumber looks for configuration in two places (later sources override earlier ones):

1. **Global**: `~/.config/lumber/config.toml` (respects `$XDG_CONFIG_HOME`)
2. **Project**: `.lumber.toml` in the current or any parent directory (walks up like `.git`)

Generate a default config file with `--init`:

```sh
lumber --init
```

Example config:

```toml
version = 1

[format]
template = "{timestamp} [{level}] ({filename}:{line}) {name}: {message}{duration}{extra}"
time_format = "%Y-%m-%dT%H:%M:%S"

[colors]
timestamp = "gray"
filename = "light_gray"
name = "cyan"
message = ""
duration = "gray"
extra_key = "cyan"
extra_value = ""
highlight_line = "236"
highlight_match = "240"

[colors.level]
trace = "blue"
debug = "light_blue"
info = "white"
warn = "yellow"
error = "red"
fatal = "magenta"

[options]
pretty = false
tz = "local"
level = "trace"
```

Available colors: `black`, `blue`, `cyan`, `gray`, `green`, `light_blue`, `light_cyan`, `light_gray`, `light_green`, `light_magenta`, `light_red`, `light_yellow`, `magenta`, `red`, `white`, `yellow`. Highlight colors also accept 256-color codes (e.g. `"236"`, `"240"`).

CLI flags always take precedence over config file values.

## Full Example

```nim
import lumber
import std/[json, streams]

type
  User = object
    name: string
    age: int

# Async console + rotating file + error-only file
outputs = @[
  Output(stream: newAsyncStream(newFileStream(stdout))),
  Output(stream: newRollingFileStream("app.log", maxBytes = 1_000_000, maxFiles = 3)),
  Output(stream: newFileStream("error.log", fmAppend), level: LogLevel.ERROR),
]

# Add request context via middleware
use proc(record: var LogRecord): bool =
  if record.extra.isNil:
    record.extra = newJObject()
  record.extra["env"] = %"production"
  true

var logger = newLogger(extra = %* {"service": "demo-api"})
var admin = User(name: "Admin", age: 35)

logger.info("Starting up")
logger.debug("Loading config for {0}", admin)

var reqLogger = logger.child(extra = %* {"requestId": "req-7f3a", "userId": 42})
reqLogger.info("Server listening on port {0}", 8080)
reqLogger.warn("Disk usage at {0}%", 92)

# Structured message fields
reqLogger.info("Request handled", status=200, latency=42, path="/api/users")

var dbLogger = reqLogger.child(name = "db", extra = %* {"host": "db.local", "port": 5432})
dbLogger.error("Failed to connect to database")

logger.fatal("Shutting down")

for o in outputs:
  o.stream.close()
```

Console output (also written to `app.log`; ERROR and FATAL additionally go to `error.log`):

```json
{"timestamp":"2026-07-06T20:44:57.230Z","level":"INFO","name":"demo","filename":"demo.nim","line":26,"message":"Starting up","extra":{"service":"demo-api","env":"production"}}
{"timestamp":"2026-07-06T20:44:57.231Z","level":"DEBUG","name":"demo","filename":"demo.nim","line":27,"message":"Loading config for User(name: \"Admin\", age: 35)","extra":{"service":"demo-api","env":"production"}}
{"timestamp":"2026-07-06T20:44:57.231Z","level":"INFO","name":"demo","filename":"demo.nim","line":30,"message":"Server listening on port 8080","extra":{"service":"demo-api","requestId":"req-7f3a","userId":42,"env":"production"}}
{"timestamp":"2026-07-06T20:44:57.231Z","level":"WARN","name":"demo","filename":"demo.nim","line":31,"message":"Disk usage at 92%","extra":{"service":"demo-api","requestId":"req-7f3a","userId":42,"env":"production"}}
{"timestamp":"2026-07-06T20:44:57.231Z","level":"INFO","name":"demo","filename":"demo.nim","line":34,"message":"Request handled","extra":{"service":"demo-api","requestId":"req-7f3a","userId":42,"status":200,"latency":42,"path":"/api/users","env":"production"}}
{"timestamp":"2026-07-06T20:44:57.231Z","level":"ERROR","name":"db","filename":"demo.nim","line":37,"message":"Failed to connect to database","extra":{"service":"demo-api","requestId":"req-7f3a","userId":42,"host":"db.local","port":5432,"env":"production"}}
{"timestamp":"2026-07-06T20:44:57.232Z","level":"FATAL","name":"demo","filename":"demo.nim","line":39,"message":"Shutting down","extra":{"service":"demo-api","env":"production"}}
```

Piped through `lumber --pretty`:

```
2026-07-06T13:44:57.230-07:00 PDT [INFO ] (demo.nim:26) demo: Starting up
  service: "demo-api"
  env: "production"
2026-07-06T13:44:57.231-07:00 PDT [DEBUG] (demo.nim:27) demo: Loading config for User(name: "Admin", age: 35)
  service: "demo-api"
  env: "production"
2026-07-06T13:44:57.231-07:00 PDT [INFO ] (demo.nim:30) demo: Server listening on port 8080
  service: "demo-api"
  requestId: "req-7f3a"
  userId: 42
  env: "production"
2026-07-06T13:44:57.231-07:00 PDT [WARN ] (demo.nim:31) demo: Disk usage at 92%
  service: "demo-api"
  requestId: "req-7f3a"
  userId: 42
  env: "production"
2026-07-06T13:44:57.231-07:00 PDT [INFO ] (demo.nim:34) demo: Request handled
  service: "demo-api"
  requestId: "req-7f3a"
  userId: 42
  status: 200
  latency: 42
  path: "/api/users"
  env: "production"
2026-07-06T13:44:57.231-07:00 PDT [ERROR] (demo.nim:37) db: Failed to connect to database
  service: "demo-api"
  requestId: "req-7f3a"
  userId: 42
  host: "db.local"
  port: 5432
  env: "production"
2026-07-06T13:44:57.232-07:00 PDT [FATAL] (demo.nim:39) demo: Shutting down
  service: "demo-api"
  env: "production"
```

## License

MIT
