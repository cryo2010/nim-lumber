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

test "GMT resolves to a DST-free zone":
  # Regression: GMT mapped to Europe/London, which renders as BST (+01:00)
  # in summer even though GMT is UTC year-round
  check resolveTimezone("GMT") == "Etc/GMT"
  check resolveTimezone("BST") == "Europe/London"
  check resolveTimezone("America/Bogota") == "America/Bogota"

# -- Argument parsing --

test "explicit flags are tracked so they can override config values":
  # Regression: --tz local and --level trace were indistinguishable from
  # "not passed", so a config file value silently won over them
  let explicit = parseArgs(@["--tz", "local", "--level", "trace"])
  check explicit.tzSet
  check explicit.tz == "local"
  check explicit.levelSet
  check explicit.level == LogLevel.TRACE
  let bare = parseArgs(@["--pretty"])
  check not bare.tzSet
  check not bare.levelSet
  check bare.pretty

test "parseTimestamp parses Z and offset timestamps":
  check parseTimestamp("2026-07-03T12:00:00Z") ==
        parseTimestamp("2026-07-03T05:00:00-07:00")
  check parseTimestamp("2026-07-03T12:00:00Z") ==
        parseTimestamp("2026-07-03T14:00:00+02:00")

test "parseTimestamp accepts fractional seconds":
  # Regression: lumber's own timestamps carry milliseconds, which made
  # timestamp filters fall back to string comparison
  check parseTimestamp("2026-07-03T12:00:00.139Z") ==
        parseTimestamp("2026-07-03T12:00:00Z")
  check parseTimestamp("2026-07-03T05:00:00.5-07:00") ==
        parseTimestamp("2026-07-03T12:00:00Z")

test "timestamp filters compare epochs across formats":
  let j = parseJson("""{"timestamp":"2026-07-03T15:27:17.139Z"}""")
  # Mixed offset forms only compare correctly as parsed times, not strings
  check matchesFilter(j, parseFilter("timestamp>2026-07-03T06:00:00-08:00"))
  check not matchesFilter(j, parseFilter("timestamp<2026-07-03T12:00:00Z"))
