## Built-in middleware for lumber
##
## Usage:
##   import lumber
##   import lumber/middleware
##
##   use newRateLimiter(window = 1.0, maxBurst = 10)
##   use newSampler(rate = 100)  # log 1 in 100

import std/[tables, times, strutils, json, re]
import ../lumber

proc newRateLimiter*(window: float = 1.0, maxBurst: int = 5): LogMiddleware =
  ## Creates middleware that limits log output per source location.
  ## Within each `window` (seconds), only the first `maxBurst` messages
  ## from the same file:line are emitted. Resets after the window expires.
  ## When messages were suppressed, the next emitted message from that
  ## source includes a `suppressed` field with the count of dropped messages.
  var counts = initTable[string, int]()
  var dropped = initTable[string, int]()
  var lastReset = epochTime()
  result = proc(record: var LogRecord): bool =
    let now = epochTime()
    if now - lastReset >= window:
      counts.clear()
      lastReset = now
    let key = record.filename & ":" & $record.line
    let count = counts.getOrDefault(key, 0) + 1
    counts[key] = count
    if count <= maxBurst:
      let suppressed = dropped.getOrDefault(key, 0)
      if suppressed > 0:
        if record.extra.isNil:
          record.extra = newJObject()
        record.extra["suppressed"] = %suppressed
        dropped.del(key)
      return true
    else:
      dropped[key] = dropped.getOrDefault(key, 0) + 1
      return false

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

const defaultRedactKeys* = @[
  "api_key", "api_secret", "apiKey", "apiSecret",
  "authorization", "card_number", "cardNumber",
  "cookie", "credit_card", "creditCard", "cvv",
  "passwd", "password", "pin", "secret", "ssn", "token",
]

proc newRedactor*(keys: seq[string] = @[], placeholder: string = "[REDACTED]"): LogMiddleware =
  ## Creates middleware that replaces the values of specified extra field keys
  ## with a placeholder string. Useful for removing sensitive data like passwords,
  ## tokens, or PII from log output.
  ##
  ## If `keys` is empty, uses a built-in default list of common sensitive field
  ## names (password, token, apiKey, ssn, creditCard, etc.).
  ## If `keys` is provided, it completely overrides the defaults.
  let redactKeys = if keys.len > 0: keys else: defaultRedactKeys
  result = proc(record: var LogRecord): bool =
    if not record.extra.isNil and record.extra.kind == JObject:
      for key in redactKeys:
        if record.extra.hasKey(key):
          record.extra[key] = %placeholder
    true

proc newPatternRedactor*(pattern: Regex, placeholder: string = "[REDACTED]"): LogMiddleware =
  ## Creates middleware that scans all string values in extra fields and the
  ## message, replacing any match of `pattern` with the placeholder.
  ## Useful for redacting credit card numbers, API keys, emails, etc.
  result = proc(record: var LogRecord): bool =
    record.message = record.message.replacef(pattern, placeholder)
    if not record.extra.isNil and record.extra.kind == JObject:
      for key, val in record.extra.pairs:
        if val.kind == JString:
          let replaced = val.getStr().replacef(pattern, placeholder)
          if replaced != val.getStr():
            record.extra[key] = %replaced
    true
