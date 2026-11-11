# shellcheck shell=bash
# The canary the shell-shape suites read for the whole config/shell layer: UV_MALWARE_CHECK comes from a file gated on
# `command -v uv`, so it proves PATH was assembled before the sourcing loop ran, not merely by the end of the file. An
# unconditional export would pass with the loop ahead of PATH, the very bug those suites exist to catch.

# Skips a test on a host where the canary cannot be set: no uv, or a uv older than the file's own version gate.
skip_unless_canary() {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  (
    unset UV_MALWARE_CHECK
    # shellcheck source=/dev/null
    . "$BATS_TEST_DIRNAME/../config/shell/supply-chain.sh"
    [ -n "${UV_MALWARE_CHECK:-}" ]
  ) || skip "this uv is older than supply-chain.sh's gate"
}
