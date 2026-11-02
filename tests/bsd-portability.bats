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

# The claude package is shared, so its hooks fire on the Mac as well as in the Linux
# server's slots, and scripts/macos-* run only on the Mac. macOS realpath and readlink
# have no -m (checked on macOS 27: "illegal option -- m"); readlink -f works on both.
@test "code that runs on the Mac uses no GNU-only realpath -m or readlink -m" {
  local hits
  hits=$(cd "$REPO" && git ls-files -z -- 'stow/claude/dot-claude/*.sh' 'scripts/macos-*' \
    | xargs -0 rg -n --no-heading -P \
      '^(?!\s*#).*\b(realpath|readlink) (-[a-zA-Z]*m\b|--canonicalize-missing)' -- 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "GNU-only path call in code that runs on macOS:"
    echo "$hits"
    return 1
  fi
}
