## Rate-limiter middleware: bursts beyond maxBurst are dropped, and the
## first message after the window resets carries a `suppressed` count of
## what was dropped.
##
## Run:
##   nim r demos/ratelimit.nim | ./lumber --pretty

import std/os
import ../src/lumber
import ../src/lumber/middleware

configureLogging(cfg):
  cfg.middleware.add newRateLimiter(window = 1.0, maxBurst = 3)

var logger = newLogger(name = "demo")

echo "--- Sending 10 messages, waiting, then 3 more (burst=3, window=1s) ---"
echo "--- First message after reset will show suppressed=7 ---"
echo ""

var slept = false
for i in 1 .. 13:
  if i == 11 and not slept:
    sleep(1100)
    slept = true
  logger.info("Event {0}", i)
