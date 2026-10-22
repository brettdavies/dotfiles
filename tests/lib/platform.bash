# shellcheck shell=bash
# Platform gate for a suite whose code under test cannot run on the other OS.
# Call it from setup_file, where a skip covers every test in the file.
#
# A suite that stubs uname to simulate a platform runs everywhere and must not
# use this: CI runs only on Linux, so gating such a suite to macOS would leave
# the Mac-side code it covers with no CI run at all.
#
# Usage: require_os <Linux|Darwin> <why the code cannot run elsewhere>
require_os() {
  [ "$(uname -s)" = "$1" ] || skip "$1 only: $2"
}
