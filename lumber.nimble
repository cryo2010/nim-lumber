# Package

version       = "0.1.0"
author        = "Craig Younker"
description   = "A JSON logger and prettifier CLI"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]


# Dependencies

requires "nim >= 2.2.10"
requires "regex >= 0.25.0"

# Tasks

task test, "Run the test suite":
  exec "nim c --hints:off --threads:on -r tests/test_logger.nim"
  exec "nim c --hints:off --threads:on -r tests/test_middleware.nim"

task buildDev, "Build the CLI (debug, with stack traces)":
  exec "nim c --threads:on -o:lumber src/lumber/cli.nim"

task buildProd, "Build the CLI (optimized release)":
  exec "nim c -d:release --threads:on --opt:speed --hints:off -o:lumber src/lumber/cli.nim"
