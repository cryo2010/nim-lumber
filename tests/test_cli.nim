import unittest
import std/json
import lumber
import lumber/cli

# -- Filters --

test "numeric filters do not crash on values shorter than a timestamp":
  # Regression: parseTimestamp indexed s[^6] unconditionally, so any
  # comparison value shorter than 6 chars (e.g. --filter "latency>500")
  # raised an IndexDefect instead of falling back to numeric comparison
  let j = parseJson("""{"level":"INFO","extra":{"latency":700}}""")
  check matchesFilter(j, parseFilter("latency>500"))
  check not matchesFilter(j, parseFilter("latency<500"))
  check matchesFilter(j, parseFilter("latency>=700"))
  check matchesFilter(j, parseFilter("latency<=700"))

test "parseTimestamp rejects non-timestamp values with ValueError":
  for bad in ["500", "abc", "", "1", "12:00", "not-a-timestamp"]:
    expect ValueError:
      discard parseTimestamp(bad)

# -- Level filtering --

test "missing or unknown levels pass the level filter":
  # Regression: JSON lines without a recognized level were silently
  # dropped (levelOrd -1 compared below every threshold) while non-JSON
  # lines were echoed verbatim
  check passesLevel("", LogLevel.TRACE)
  check passesLevel("", LogLevel.FATAL)
  check passesLevel("NOTICE", LogLevel.WARN)
  check passesLevel("WARN", LogLevel.WARN)
  check passesLevel("error", LogLevel.WARN)
  check not passesLevel("INFO", LogLevel.WARN)
  check not passesLevel("trace", LogLevel.DEBUG)

test "parseTimestamp parses Z and offset timestamps":
  check parseTimestamp("2026-07-03T12:00:00Z") ==
        parseTimestamp("2026-07-03T05:00:00-07:00")
  check parseTimestamp("2026-07-03T12:00:00Z") ==
        parseTimestamp("2026-07-03T14:00:00+02:00")
