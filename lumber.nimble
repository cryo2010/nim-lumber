# Package

import std/strutils

# Nimble requires a string literal here. Keep in sync with
# src/lumber/version.nim: run `nimble setVersion X.Y.Z` to update both;
# the test suite fails on drift.
version       = "0.1.0"
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

task test, "Run the test suite (set LUMBER_TEST_MM to test another memory manager, e.g. atomicArc)":
  let mm = getEnv("LUMBER_TEST_MM", "orc")
  for t in ["test_logger", "test_middleware", "test_threading", "test_streams", "test_cli"]:
    exec "nim c --mm:" & mm & " --hints:off --threads:on -r tests/" & t & ".nim"
  # Compile-time elimination needs its own binary with a raised threshold
  exec "nim c --mm:" & mm & " --hints:off --threads:on -d:lumberLevel=ERROR -r tests/test_compile_gate.nim"

task testValgrind, "Run the test suite under valgrind (Linux; set LUMBER_TEST_MM as with test)":
  ## -d:useMalloc routes Nim's allocator through malloc/free so valgrind
  ## sees every allocation; without it, leaks and invalid accesses hide
  ## inside Nim's own memory pools.
  let mm = getEnv("LUMBER_TEST_MM", "orc")
  let compile = "nim c --mm:" & mm & " -d:useMalloc --debugger:native --hints:off --threads:on "
  const vg = "valgrind --quiet --error-exitcode=1 --leak-check=full " &
             "--show-leak-kinds=definite --errors-for-leak-kinds=definite "
  for t in ["test_logger", "test_middleware", "test_threading", "test_streams", "test_cli"]:
    exec compile & "tests/" & t & ".nim"
    exec vg & "tests/" & t
  exec compile & "-d:lumberLevel=ERROR tests/test_compile_gate.nim"
  exec vg & "tests/test_compile_gate"

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
  exec "nim c -d:release --threads:on --opt:speed --hints:off -o:lumber src/lumber/cli.nim"
