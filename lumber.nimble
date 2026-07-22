# Package

import std/strutils

# Nimble requires a string literal here. Keep in sync with
# src/lumber/version.nim: run `nimble setVersion X.Y.Z` to update both;
# the test suite fails on drift.
version       = "0.4.0"
author        = "Craig Younker"
description   = "A JSON logger and prettifier CLI"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
namedBin["lumber/cli"] = "lumber"


# Dependencies

requires "nim >= 2.2.10"
requires "regex >= 0.25.0"

# Tasks

# The test tasks are thin wrappers over scripts/tests.nims so CI can call
# that file directly with `nim e`: nimble 0.22 exits 0 when a task fails,
# so a nimble-invoked gate cannot actually gate.

task test, "Run the test suite (set LUMBER_TEST_MM to test another memory manager, e.g. atomicArc)":
  exec "nim e --hints:off scripts/tests.nims test"

task testValgrind, "Run the test suite under valgrind, via Docker when valgrind is not installed (set LUMBER_TEST_MM as with test)":
  exec "nim e --hints:off scripts/tests.nims valgrind"

task testHelgrind, "Run the threaded tests under helgrind, via Docker when valgrind is not installed (set LUMBER_TEST_MM as with test)":
  exec "nim e --hints:off scripts/tests.nims helgrind"

task setVersion, "Set the package version in lumber.nimble and src/lumber/version.nim (nimble setVersion X.Y.Z)":
  proc replaceLine(path, prefix, newLine: string) =
    var lines = readFile(path).splitLines
    for i in 0 ..< lines.len:
      if lines[i].startsWith(prefix):
        lines[i] = newLine
        writeFile(path, lines.join("\n"))
        return
    quit("setVersion: could not find '" & prefix & "' in " & path)

  # The version is the last parameter of the invocation
  var newVer = ""
  for i in 0 .. paramCount():
    newVer = paramStr(i)
  let parts = newVer.split('.')
  var valid = parts.len == 3
  if valid:
    for p in parts:
      try:
        discard parseInt(p)
      except ValueError:
        valid = false
  if not valid:
    quit("usage: nimble setVersion X.Y.Z")

  replaceLine("lumber.nimble", "version",
    "version       = \"" & newVer & "\"")
  replaceLine("src/lumber/version.nim", "const LumberVersion",
    "const LumberVersion* = \"" & newVer & "\"")
  echo "Version set to ", newVer, " in lumber.nimble and src/lumber/version.nim"

task buildDev, "Build the CLI (debug, with stack traces)":
  exec "nim c --threads:on -o:lumber src/lumber/cli.nim"

task buildProd, "Build the CLI (optimized release)":
  exec "nim e --hints:off scripts/tests.nims build"
