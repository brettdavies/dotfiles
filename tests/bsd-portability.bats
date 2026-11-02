#!/usr/bin/env bats
# Static checks for commands whose BSD form on macOS rejects what GNU on Linux accepts.
# CI runs only on Linux, so a GNU-only invocation passes there and fails only in the
# Mac's pre-push; reading the source is the one check both run.
#
# Run: bats tests/bsd-portability.bats

REPO="$BATS_TEST_DIRNAME/.."

# BSD paste requires a file operand: `paste -sd ' '` reading stdin prints a usage error
# and exits 1, where GNU paste reads stdin. The portable form names stdin as `-`.
@test "every paste -s names its input, - for stdin" {
  local hits
  hits=$(cd "$REPO" && git ls-files -z -- '*.sh' '*.bash' '*.bats' 'scripts/*' 'stow/*' '.githooks/*' \
    | xargs -0 rg -n --no-heading -P \
      "\\bpaste -s[a-z]*d?(\\S*|'[^']*'|\\s+('[^']*'|\"[^\"]*\"))\\s*(\\)|\\||;|\$)" -- 2>/dev/null \
    | rg -v '^tests/bsd-portability\.bats:' || true)
  if [ -n "$hits" ]; then
    echo "paste -s without a file operand (add - to read stdin):"
    echo "$hits"
    return 1
  fi
}
