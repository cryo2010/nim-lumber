import ../src/lumber

type
  User = object
    name: string

var logger = newLogger(name = "demo")
var user = User(name: "Alice")

logger.trace("This is a trace")
logger.debug(user)
logger.info("{0} logged in", user.name)
logger.warn("Disk usage at {0}%", 92)
logger.error("Connection failed", host="db.local", port=5432)

proc loadConfig() =
  raise newException(IOError, "file not found: config.toml")

proc initApp() =
  loadConfig()

try:
  initApp()
except IOError as e:
  logger.error("Failed to load config", e)

logger.fatal("Game over")
