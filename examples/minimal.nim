## The basics: log levels, string interpolation, structured fields, and
## automatic exception logging.
##
## Run (build the CLI first with `nimble buildProd` for the pretty version):
##   nim r examples/minimal.nim
##   nim r examples/minimal.nim | ./lumber --pretty

import std/strformat
import ../src/lumber

type
  User = object
    name: string

var logger = newLogger(name = "demo")
var user = User(name: "Alice")

logger.trace("This is a trace")
logger.debug(user)
logger.info(&"{user.name} logged in")
logger.warn("Disk usage high", partition="/dev/sda1", usage=92)

proc loadConfig() =
  raise newException(IOError, "file not found: config.toml")

proc initApp() =
  loadConfig()

try:
  initApp()
except IOError as e:
  logger.error("Failed to load config", e)

logger.fatal("Game over")
