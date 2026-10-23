# shellcheck shell=bash
# Linux gate for a suite whose code under test cannot run anywhere else. Call it
# from setup_file, where a skip covers every test in the file.
#
# There is deliberately no macOS counterpart: CI runs only on Linux, so a suite
# gated to macOS would never run there. Mac-side code is tested through uname
# stubs, and a check that needs a real Mac tool skips that one test when the
# tool is missing (`command -v plutil || skip`).
#
# Usage: require_linux <why the code cannot run elsewhere>
require_linux() {
  [ "$(uname -s)" = Linux ] || skip "Linux only: $1"
}
