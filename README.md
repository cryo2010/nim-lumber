# lumber

A compile-time optimized JSON logger for Nim with a built-in CLI prettifier.

## Features

- **Compile-time level filtering** - log calls below the threshold are eliminated from the binary entirely, with zero runtime cost
- **Structured JSON output** - every log line is valid JSON with timestamp, level, name, filename, line number, and message
- **String interpolation** - `{0}`, `{1}` placeholders in messages are replaced with stringified arguments
- **Type-aware object formatting** - object types are automatically prefixed with their type name (e.g. `User(name: "Dude", age: 40)`)
- **Child loggers** - create derived loggers that inherit and extend the parent's context
- **Extra fields** - attach structured metadata to loggers, merged into every log line under an `"extra"` key
- **Middleware** - a chain of functions that can enrich, transform, or suppress log records at runtime
- **Multiple output streams** - write to stdout, files, or any custom `Stream` simultaneously
- **Rotating file streams** - built-in size-based and time-based file rotation
- **Async stream wrapper** - non-blocking I/O via a background writer thread
- **CLI prettifier** - pipe JSON logs through the `lumber` binary for colored, human-readable output with level filtering

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

# Named logger with extra context
var logger = newLogger(name = "api", extra = %* {"service": "my-app"})
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

### String Interpolation

Use `{0}`, `{1}`, etc. to interpolate arguments into the message. Extra arguments are appended.

```nim
logger.info("User {0} logged in from {1}", username, ipAddr)
logger.info("Values:", 1, 2, 3)  # "Values: 1 2 3"
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

Create child loggers that inherit the parent's name and extra fields. Child extra fields are merged on top of the parent's.

```nim
var logger = newLogger(name = "api", extra = %* {"service": "my-app"})

var reqLogger = logger.child(extra = %* {"requestId": "abc-123"})
reqLogger.info("Handling request")
# extra: {"service": "my-app", "requestId": "abc-123"}

var dbLogger = reqLogger.child(name = "db", extra = %* {"query": "SELECT ..."})
dbLogger.error("Connection timeout")
# name: "db", extra: {"service": "my-app", "requestId": "abc-123", "query": "SELECT ..."}
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

### Output Streams

By default, logs write to stdout. You can write to multiple streams.

```nim
import std/streams

# Add a file stream alongside stdout
outputs.add(Stream(newFileStream("app.log", fmAppend)))

# Replace outputs entirely
outputs = @[Stream(newFileStream("app.log", fmAppend))]
```

### Rotating File Streams

#### Size-based rotation

Rotates when the file exceeds a size limit. Keeps numbered backups (`app.log.1`, `app.log.2`, etc.).

```nim
# 10MB max, keep 5 backup files (default)
outputs.add(Stream(newSizeRotateStream("app.log")))

# Custom: 50MB max, keep 10 backups
outputs.add(Stream(newSizeRotateStream("app.log", maxBytes = 50_000_000, maxFiles = 10)))
```

#### Time-based rotation

Rotates at midnight UTC. Keeps dated backups (`app.2026-07-02.log`, `app.2026-07-01.log`, etc.).

```nim
# Keep 30 days of logs (default)
outputs.add(Stream(newTimeRotateStream("app.log")))

# Keep 7 days
outputs.add(Stream(newTimeRotateStream("app.log", maxFiles = 7)))
```

### Async Streams

Wrap any stream with `newAsyncStream` for non-blocking I/O. Log calls push data onto a channel and return immediately; a background thread handles the writes.

```nim
# Async console output
outputs = @[Stream(newAsyncStream(newFileStream(stdout)))]

# Async rotating file
outputs.add(Stream(newAsyncStream(newSizeRotateStream("app.log"))))

# Close to flush and join the writer thread
for s in outputs:
  s.close()
```

## CLI Prettifier

The `lumber` binary reads JSON log lines from stdin and prints colored, formatted output.

```sh
myapp | lumber
```

Output format:

```
2026-07-03T00:00:00Z [INFO ] (mymodule.nim:10) Server started {"service":"my-app"}
```

Levels are color-coded: TRACE (blue), DEBUG (light blue), INFO (white), WARN (yellow), ERROR (red), FATAL (magenta).

### Level Filtering

Filter output by minimum level:

```sh
myapp | lumber --level warn
myapp | lumber --level=error
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

# Async console + rotating file
outputs = @[
  Stream(newAsyncStream(newFileStream(stdout))),
  Stream(newSizeRotateStream("app.log", maxBytes = 1_000_000, maxFiles = 3))
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

var dbLogger = reqLogger.child(name = "db", extra = %* {"host": "db.local", "port": 5432})
dbLogger.error("Failed to connect to database")

logger.fatal("Shutting down")

for s in outputs:
  s.close()
```

## License

MIT
