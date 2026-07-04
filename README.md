# lumber

A compile-time optimized JSON logger for Nim with a built-in CLI prettifier.

## Features

- **Compile-time level filtering** - log calls below the threshold are eliminated from the binary entirely, with zero runtime cost
- **Structured JSON output** - every log line is valid JSON with timestamp, level, name, filename, line number, and message
- **Structured messages** - named `key=value` arguments become discrete JSON fields, queryable by log aggregators
- **String interpolation** - `{0}`, `{1}` placeholders in messages are replaced with stringified arguments
- **Type-aware object formatting** - object types are automatically prefixed with their type name (e.g. `User(name: "Dude", age: 40)`)
- **Runtime level filtering** - per-logger level short-circuits before building records
- **Child loggers** - create derived loggers that inherit and extend the parent's context
- **Extra fields** - attach structured metadata to loggers, merged into every log line under an `"extra"` key
- **Middleware** - a chain of functions that can enrich, transform, or suppress log records at runtime
- **Multiple output streams** - write to stdout, files, or any custom `Stream` simultaneously
- **Rotating file streams** - built-in size-based and time-based file rotation
- **Async stream wrapper** - non-blocking I/O via a background writer thread
- **CLI prettifier** - pipe JSON logs through the `lumber` binary for colored, human-readable output with level filtering, field filtering, and timezone support

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

Output:

```json
{"timestamp":"2026-07-03T00:00:00Z","level":"INFO","name":"mymodule","filename":"mymodule.nim","line":4,"message":"Hello, world!"}
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

### Runtime Level Filtering

Each logger has a `level` field that short-circuits before building the log record, running middleware, or serializing JSON.

```nim
var logger = newLogger(name = "api")
logger.level = LogLevel.WARN  # only WARN+ will be processed
logger.info("skipped")        # no work done
logger.error("processed")     # goes through normally
```

Child loggers inherit the parent's level.

### String Interpolation

Use `{0}`, `{1}`, etc. to interpolate arguments into the message. Extra arguments are appended.

```nim
logger.info("User {0} logged in from {1}", username, ipAddr)
logger.info("Values:", 1, 2, 3)  # "Values: 1 2 3"
```

### Structured Messages

Named arguments become discrete fields in the `extra` JSON object, keeping them queryable by log aggregators rather than buried in a text string.

```nim
logger.info("User logged in", user="alice", ip="10.0.0.1")
# extra: {"user": "alice", "ip": "10.0.0.1"}

# Mix positional interpolation with named fields
logger.info("Request {0} completed", reqId, status=200, latency=42)
# message: "Request req-abc completed", extra: {"status": 200, "latency": 42}
```

Message-level fields override logger extra on key collision:

```nim
var logger = newLogger(extra = %* {"user": "system"})
logger.info("login", user="alice")
# extra.user is "alice", not "system"
```

### Any Type as an Argument

Any type with a `$` operator can be passed. Objects are prefixed with their type name.

```nim
type User = object
  name: string
  age: int

var user = User(name: "Dude", age: 40)
logger.info("Found {0}", user)
# message: "Found User(name: \"Dude\", age: 40)"

logger.info(user)
# message: "User(name: \"Dude\", age: 40)"
```

### Child Loggers

Create child loggers that inherit the parent's name, level, and extra fields. Child extra fields are merged on top of the parent's.

```nim
var logger = newLogger(name = "api", extra = %* {"service": "my-app"})

var reqLogger = logger.child(extra = %* {"requestId": "abc-123"})
reqLogger.info("Handling request")
# extra: {"service": "my-app", "requestId": "abc-123"}

var dbLogger = reqLogger.child(name = "db", extra = %* {"query": "SELECT ..."})
dbLogger.error("Connection timeout")
# name: "db", extra: {"service": "my-app", "requestId": "abc-123", "query": "SELECT ..."}

# Child also accepts Nim objects
type DbContext = object
  host: string
  port: int

var dbLogger = reqLogger.child(name = "db", extra = DbContext(host: "db.local", port: 5432))
```

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

# Clear all middleware
clearMiddleware()
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

Output format:

```
2026-07-03T15:00:00-07:00 PDT [INFO ] (mymodule.nim:10) Server started {"service":"my-app"}
```

Levels are color-coded: TRACE (blue), DEBUG (light blue), INFO (white), WARN (yellow), ERROR (red), FATAL (magenta).

### Options

```
--level <level>     Minimum log level to display
--filter <expr>     Filter logs by field value (can be repeated)
--tz <timezone>     Timezone for timestamps (IANA name or abbreviation)
--help, -h          Show help
--version, -v       Show version
```

### Level Filtering

Filter output by minimum level:

```sh
myapp | lumber --level warn
myapp | lumber --level=error
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

## License

MIT
