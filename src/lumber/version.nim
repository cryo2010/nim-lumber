## The package version, exported through the lumber module and used by
## the CLI's --version output. Nimble requires its version field to be a
## string literal, so lumber.nimble duplicates this value; the test suite
## asserts they match.

const LumberVersion* = "0.1.0"
