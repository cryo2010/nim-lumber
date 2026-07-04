## Built-in middleware for lumber
##
## Usage:
##   import lumber
##   import lumber/middleware
##
##   use newRateLimiter(window = 1.0, maxBurst = 10)
##   use newSampler(rate = 100)  # log 1 in 100

import std/[tables, times, strutils]
import ../lumber

proc newRateLimiter*(window: float = 1.0, maxBurst: int = 5): LogMiddleware =
  ## Creates middleware that limits log output per source location.
  ## Within each `window` (seconds), only the first `maxBurst` messages
  ## from the same file:line are emitted. Resets after the window expires.
  var counts = initTable[string, int]()
  var lastReset = epochTime()
  result = proc(record: var LogRecord): bool =
    let now = epochTime()
    if now - lastReset >= window:
      counts.clear()
      lastReset = now
    let key = record.filename & ":" & $record.line
    let count = counts.getOrDefault(key, 0) + 1
    counts[key] = count
    count <= maxBurst

proc newSampler*(rate: int = 10): LogMiddleware =
  ## Creates middleware that logs 1 in every `rate` messages.
  ## The first message is always logged. Every Nth message thereafter
  ## is emitted; the rest are suppressed.
  var counter = 0
  result = proc(record: var LogRecord): bool =
    counter.inc()
    counter mod rate == 1

proc newLevelSampler*(level: LogLevel, rate: int = 10): LogMiddleware =
  ## Creates middleware that samples only messages at or below `level`.
  ## Messages above `level` always pass through unsampled.
  ## Useful for sampling DEBUG/TRACE while keeping all WARN+ intact.
  var counter = 0
  result = proc(record: var LogRecord): bool =
    let recordLevel = parseEnum[LogLevel](record.level)
    if recordLevel > level:
      return true
    counter.inc()
    counter mod rate == 1
