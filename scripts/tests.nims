## Test-suite entry points, invoked as `nim e scripts/tests.nims <mode>`
## from the repository root, with LUMBER_TEST_MM selecting the memory
## manager (default orc).
##
## CI calls this file directly instead of the nimble tasks: nimble 0.22
## exits 0 when a task fails (exec failure and quit alike), which would
## silently green-light broken runs. The nimble tasks wrap these modes
## for local convenience; `nim e` propagates failure properly.

const allTests = ["test_logger", "test_middleware", "test_threading",
                  "test_streams", "test_cli"]
const threadedTests = ["test_threading", "test_streams"]

let mm = getEnv("LUMBER_TEST_MM", "orc")

proc valgrindCompile(): string =
  ## -d:useMalloc routes Nim's allocator through malloc/free so valgrind
  ## sees every allocation; without it, leaks and invalid accesses hide
  ## inside Nim's own memory pools.
  "nim c --mm:" & mm & " -d:useMalloc --debugger:native --hints:off --threads:on "

proc dockerFallback(mode: string) =
  ## No valgrind on this machine (it does not exist for macOS): rerun in
  ## a Linux container, where the native branch runs. The image is amd64,
  ## so Apple Silicon emulates it; expect a few minutes.
  if findExe("docker").len == 0:
    quit("mode " & mode & " needs valgrind (Linux) or docker to provide it; neither was found")
  echo "valgrind not found; running in a Linux container via Docker"
  exec "docker run --rm --platform linux/amd64 -e LUMBER_TEST_MM=" & mm &
       " -v \"$PWD\":/work -w /work nimlang/nim:2.2.10 bash -c \"" &
       "apt-get update -qq > /dev/null && apt-get install -y -qq valgrind > /dev/null && " &
       "nimble install -y --depsOnly > /dev/null && nim e scripts/tests.nims " & mode & "\""

proc runTests() =
  for t in allTests:
    exec "nim c --mm:" & mm & " --hints:off --threads:on -r tests/" & t & ".nim"
  # Compile-time elimination needs its own binary with a raised threshold
  exec "nim c --mm:" & mm & " --hints:off --threads:on -d:lumberLevel=ERROR -r tests/test_compile_gate.nim"

proc runValgrind() =
  if findExe("valgrind").len == 0:
    dockerFallback("valgrind")
    return
  let compile = valgrindCompile()
  const vg = "valgrind --quiet --error-exitcode=1 --leak-check=full " &
             "--show-leak-kinds=definite --errors-for-leak-kinds=definite "
  for t in allTests:
    exec compile & "tests/" & t & ".nim"
    exec vg & "tests/" & t
  exec compile & "-d:lumberLevel=ERROR tests/test_compile_gate.nim"
  exec vg & "tests/test_compile_gate"

proc runHelgrind() =
  ## Data-race detection. Only the multi-threaded binaries are worth the
  ## tool's slowdown; the single-threaded tests cannot race.
  if findExe("valgrind").len == 0:
    dockerFallback("helgrind")
    return
  let compile = valgrindCompile()
  const hg = "valgrind --tool=helgrind --quiet --error-exitcode=1 " &
             "--suppressions=scripts/helgrind.supp "
  for t in threadedTests:
    exec compile & "tests/" & t & ".nim"
    exec hg & "tests/" & t

proc buildCli() =
  exec "nim c -d:release --threads:on --opt:speed --hints:off -o:lumber src/lumber/cli.nim"

case paramStr(paramCount())
of "test": runTests()
of "valgrind": runValgrind()
of "helgrind": runHelgrind()
of "build": buildCli()
else:
  quit("usage: nim e scripts/tests.nims {test|valgrind|helgrind|build}")
