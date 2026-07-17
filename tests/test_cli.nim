import unittest
import std/json
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

test "parseTimestamp parses Z and offset timestamps":
  check parseTimestamp("2026-07-03T12:00:00Z") ==
        parseTimestamp("2026-07-03T05:00:00-07:00")
  check parseTimestamp("2026-07-03T12:00:00Z") ==
        parseTimestamp("2026-07-03T14:00:00+02:00")
