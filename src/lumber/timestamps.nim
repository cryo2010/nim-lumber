## UTC timestamp rendering from unix time using plain integer math
## (Howard Hinnant's civil-from-days). Used instead of std/times DateTime
## formatting on hot paths: utc() allocates and caches a Timezone ref in
## a threadvar that thread exit never frees, so every logging thread that
## touched it would leak one Timezone.

proc civilFromUnix(unixSec: int64): tuple[y, m, d, rem: int64] =
  ## Splits unix time into a UTC calendar date and the remaining
  ## second-of-day.
  var days = unixSec div 86400
  var rem = unixSec mod 86400
  if rem < 0:
    rem += 86400
    days -= 1
  let z = days + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = mp + (if mp < 10: 3 else: -9)
  let y = yoe + era * 400 + (if m <= 2: 1 else: 0)
  (y, m, d, rem)

template put2(s: var string, idx: int, v: int64) =
  s[idx] = chr(ord('0') + int(v div 10 mod 10))
  s[idx + 1] = chr(ord('0') + int(v mod 10))

proc utcDate*(unixSec: int64): string =
  ## Renders a unix timestamp as "yyyy-MM-dd" (UTC).
  let (y, m, d, _) = civilFromUnix(unixSec)
  result = newString(10)
  result.put2(0, y div 100)
  result.put2(2, y)
  result[4] = '-'
  result.put2(5, m)
  result[7] = '-'
  result.put2(8, d)

proc utcTimestamp*(unixSec: int64): string =
  ## Renders a unix timestamp as "yyyy-MM-ddTHH:mm:ss" (UTC).
  let (y, m, d, rem) = civilFromUnix(unixSec)
  result = newString(19)
  result.put2(0, y div 100)
  result.put2(2, y)
  result[4] = '-'
  result.put2(5, m)
  result[7] = '-'
  result.put2(8, d)
  result[10] = 'T'
  result.put2(11, rem div 3600)
  result[13] = ':'
  result.put2(14, rem mod 3600 div 60)
  result[16] = ':'
  result.put2(17, rem mod 60)
