## Built-in middleware for lumber
##
## Usage:
##   import lumber
##   import lumber/middleware
##
##   configureLogging(cfg):
##     cfg.middleware.add newRateLimiter(window = 1.0, maxBurst = 10)
##     cfg.middleware.add newSampler(rate = 100)  # log 1 in 100

import std/[tables, times, strutils, json]
import regex
import ../lumber

proc newRateLimiter*(window: float = 1.0, maxBurst: int = 5): LogMiddleware =
  ## Creates middleware that limits log output per source location.
  ## Within each `window` (seconds), only the first `maxBurst` messages
  ## from the same file:line are emitted. Resets after the window expires.
  ## When messages were suppressed, the next emitted message from that
  ## source includes a `suppressed` field with the count of dropped messages.
  ##
  ## Suppressed counts survive window resets so they can be reported on the
  ## next emit; a source that stops logging entirely retains its last count
  ## until then. Memory is bounded by the number of distinct file:line
  ## sources, not by log volume.
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
        # Earlier middleware may have replaced extra with nil
        if record.extra.isNil:
          record.extra = newJObject()
        if record.extra.kind == JObject:
          record.extra["suppressed"] = %suppressed
        dropped.del(key)
      return true
    else:
      dropped[key] = dropped.getOrDefault(key, 0) + 1
      return false

proc newSampler*(rate: int = 10): LogMiddleware =
  ## Creates middleware that logs 1 in every `rate` messages.
  ## The first message is always logged. Every Nth message thereafter
  ## is emitted; the rest are suppressed. A `rate` of 1 or less logs
  ## every message.
  if rate <= 1:
    return proc(record: var LogRecord): bool = true
  var counter = 0
  result = proc(record: var LogRecord): bool =
    counter.inc()
    counter mod rate == 1

proc newLevelSampler*(level: LogLevel, rate: int = 10): LogMiddleware =
  ## Creates middleware that samples only messages at or below `level`.
  ## Messages above `level` always pass through unsampled.
  ## Useful for sampling DEBUG/TRACE while keeping all WARN+ intact.
  ## A `rate` of 1 or less logs every message.
  if rate <= 1:
    return proc(record: var LogRecord): bool = true
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

proc redactKeysIn(node: JsonNode, redactKeys: seq[string], placeholder: string) =
  ## Replaces the values of matching keys anywhere in nested objects and
  ## arrays. Redaction that stopped at the top level would leak the same
  ## secret one nesting level down.
  case node.kind
  of JObject:
    for key, val in node.pairs:
      if key in redactKeys:
        node[key] = %placeholder
      else:
        redactKeysIn(val, redactKeys, placeholder)
  of JArray:
    for elem in node.elems:
      redactKeysIn(elem, redactKeys, placeholder)
  else:
    discard

proc newRedactor*(keys: seq[string] = @[], placeholder: string = "[REDACTED]"): LogMiddleware =
  ## Creates middleware that replaces the values of specified extra field keys
  ## with a placeholder string, including keys inside nested objects and
  ## arrays. Useful for removing sensitive data like passwords, tokens, or
  ## PII from log output.
  ##
  ## If `keys` is empty, uses a built-in default list of common sensitive field
  ## names (password, token, apiKey, ssn, creditCard, etc.).
  ## If `keys` is provided, it completely overrides the defaults.
  let redactKeys = if keys.len > 0: keys else: defaultRedactKeys
  result = proc(record: var LogRecord): bool =
    if not record.extra.isNil:
      redactKeysIn(record.extra, redactKeys, placeholder)
    true

proc redactPatternIn(node: JsonNode, pattern: Regex2, placeholder: string) =
  ## Replaces pattern matches in string values anywhere in nested objects
  ## and arrays.
  case node.kind
  of JObject:
    for key, val in node.pairs:
      if val.kind == JString:
        let replaced = val.getStr().replace(pattern, placeholder)
        if replaced != val.getStr():
          node[key] = %replaced
      else:
        redactPatternIn(val, pattern, placeholder)
  of JArray:
    for i in 0 ..< node.len:
      if node[i].kind == JString:
        let replaced = node[i].getStr().replace(pattern, placeholder)
        if replaced != node[i].getStr():
          node.elems[i] = %replaced
      else:
        redactPatternIn(node[i], pattern, placeholder)
  else:
    discard

proc newPatternRedactor*(pattern: Regex2, placeholder: string = "[REDACTED]"): LogMiddleware =
  ## Creates middleware that scans all string values in extra fields
  ## (including nested objects and arrays) and the message, replacing any
  ## match of `pattern` with the placeholder. Useful for redacting credit
  ## card numbers, API keys, emails, etc.
  result = proc(record: var LogRecord): bool =
    record.message = record.message.replace(pattern, placeholder)
    if not record.extra.isNil:
      redactPatternIn(record.extra, pattern, placeholder)
    true
