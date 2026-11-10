#!/usr/bin/env bats
# .bun-version is the one Bun version CI installs, and the local Bun the gates run must match it.
#
# CI's setup-bun reads the file, so no workflow or action names a version of its own. Locally, Bun comes from Homebrew
# and moves with `brew upgrade`, so the last test fails the day the machine's Bun moves past the pin: that is the cue
# to bump .bun-version in its own PR. A machine whose Bun trails the pin upgrades Bun instead; the pin never goes down.
#
# Run: bats tests/bun-version-pin.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."

@test ".bun-version names one exact version" {
  [ -f "$ROOT/.bun-version" ]
  run cat "$ROOT/.bun-version"
  printf "%s\n" ".bun-version holds '$output'; it needs one X.Y.Z line, such as: printf '1.4.4\\n' > .bun-version"
  [[ $output =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "every setup-bun step reads .bun-version, and no workflow or action names a Bun version of its own" {
  local file steps pinned missing='' literal
  while IFS= read -r file; do
    steps=$(grep -c 'oven-sh/setup-bun@' "$file")
    pinned=$(grep -c 'bun-version-file: \.bun-version' "$file" || true)
    ((pinned >= steps)) || missing+="$file has $steps setup-bun step(s) and $pinned reading .bun-version"$'\n'
  done < <(grep -rl 'oven-sh/setup-bun@' "$ROOT/.github")
  literal=$(grep -rnE 'bun-version:|bun-download-url:' "$ROOT/.github" || true)
  if [[ -n $missing || -n $literal ]]; then
    printf '%s' "$missing"
    [[ -z $literal ]] || printf 'names a version of its own:\n%s\n' "$literal"
    echo "fix: give each setup-bun step 'bun-version-file: .bun-version' in place of any 'bun-version:'"
    false
  fi
}

@test "the local Bun is the pinned version" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local pinned local_version newer dev_pin
  pinned=$(cat "$ROOT/.bun-version")
  local_version=$(bun --version)
  [ "$local_version" = "$pinned" ] && return 0
  newer=$(printf '%s\n' "$pinned" "$local_version" | sort -V | tail -n 1)
  dev_pin=$(git -C "$ROOT" show origin/dev:.bun-version 2>/dev/null || true)
  if [ "$newer" = "$pinned" ]; then
    echo "bun-behind-pin: local bun $local_version ($(command -v bun)) trails .bun-version $pinned."
    echo "fix: brew upgrade oven-sh/bun/bun, then push again. Never lower .bun-version or install Bun another way."
  elif [ "$dev_pin" = "$local_version" ]; then
    echo "bun-pin-behind-dev: origin/dev already pins $local_version, and this branch has $pinned."
    echo "fix: git fetch origin, then merge or rebase this branch onto origin/dev, and push again."
  else
    echo "bun-ahead-of-pin: local bun $local_version is newer than .bun-version $pinned. CI is unaffected; local pushes"
    echo "stay blocked until dev pins $local_version."
    echo "fix: unless 'gh pr list --state open --search \"bun-version in:title\"' shows one already, open a PR that"
    echo "changes only .bun-version, on branch fix/bun-version-$local_version from origin/dev:"
    printf "  printf '%%s\\\\n' %s > .bun-version\n" "$local_version"
  fi
  false
}
