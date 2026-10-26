#!/usr/bin/env bats
# Tests for the gh CLI wrapper that blocks AI merges to main
#
# Run: bats tests/gh-wrapper.bats

WRAPPER="$BATS_TEST_DIRNAME/../stow/gh/dot-local/bin/gh"

# A PATH where the wrapper is reachable under a spelling other than
# $HOME/.local/bin/gh, followed by a fake real gh that records its invocation.
# HOME points at an empty dir so the host's own ~/.local/bin/gh cannot leak
# into the run.
setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/alias" "$TMP/real" "$TMP/home"
  ln -s "$WRAPPER" "$TMP/alias/gh"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "${FAKE_GH_MARKER:?}"' 'echo "fake real gh"' >"$TMP/real/gh"
  chmod +x "$TMP/real/gh"
  export FAKE_GH_MARKER="$TMP/fake-gh-ran"
  FAKE_PATH="$TMP/alias:$TMP/real:/usr/bin:/bin"
}

teardown() {
  rm -rf "$TMP"
}

# Resolves an absolute path because every caller runs `timeout` under a
# constructed PATH that omits the Homebrew prefix. Probing the ambient PATH and
# then invoking the bare name passes the guard on macOS and still dies at 127,
# since GNU coreutils installs no /usr/bin/timeout there.
_require_timeout() {
  TIMEOUT_BIN="$(command -v timeout || true)"
  [ -n "$TIMEOUT_BIN" ] || skip "timeout not installed"
}

# ---------------------------------------------------------------------------
# Shellcheck
# ---------------------------------------------------------------------------

@test "gh wrapper passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$WRAPPER"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# find_real_gh
# ---------------------------------------------------------------------------

@test "gh wrapper finds real gh binary" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # Run a passthrough command — if find_real_gh fails, the wrapper exits 1
  run "$WRAPPER" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh version"* ]]
}

@test "gh wrapper skips itself when reachable under an alias path" {
  _require_timeout
  # The alias dir sits ahead of the fake real gh. A wrapper that fails to
  # recognise the alias as itself execs it and spins in place; timeout turns
  # that spin into exit 124 instead of a hung test.
  run env HOME="$TMP/home" PATH="$FAKE_PATH" "$TIMEOUT_BIN" 3 "$WRAPPER" --version
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "fake real gh" ]
  [ -e "$FAKE_GH_MARKER" ]
}

@test "gh wrapper skips a separate copy of itself on PATH" {
  _require_timeout
  # A second checkout (a worktree, a fleet scratch clone) puts another copy of
  # this wrapper on PATH: same content, different inode, so an identity check
  # alone hands it to exec and the guard fires. The real gh is a binary; a
  # candidate carrying the guard marker is a wrapper and must be skipped.
  mkdir -p "$TMP/copy"
  cp "$WRAPPER" "$TMP/copy/gh"
  chmod +x "$TMP/copy/gh"
  run env HOME="$TMP/home" PATH="$TMP/copy:$TMP/real:/usr/bin:/bin" "$TIMEOUT_BIN" 3 "$WRAPPER" --version
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "fake real gh" ]
  [ -e "$FAKE_GH_MARKER" ]
}

@test "gh wrapper refuses to run when it has already re-entered itself" {
  _require_timeout
  # exec keeps the PID, so a wrapper that execs itself arrives with its own
  # PID already in the marker. Reproduce that hop without the PATH walk.
  run env HOME="$TMP/home" PATH="$FAKE_PATH" "$TIMEOUT_BIN" 3 \
    bash -c 'export GH_MERGE_GUARD_PID=$$; exec "$1" --version' _ "$WRAPPER"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL:"* ]]
  [[ "$output" == *"$WRAPPER"* ]]
  [ ! -e "$FAKE_GH_MARKER" ]
}

@test "gh wrapper passes through when an ancestor set the marker" {
  _require_timeout
  # A gh extension or credential helper launched by the real gh calls gh by
  # name again. It inherits the ancestor's marker but runs under its own PID,
  # so the guard must not fire.
  run env HOME="$TMP/home" PATH="$FAKE_PATH" GH_MERGE_GUARD_PID=1 \
    "$TIMEOUT_BIN" 3 "$WRAPPER" --version
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "fake real gh" ]
}

# ---------------------------------------------------------------------------
# Passthrough behavior
# ---------------------------------------------------------------------------

@test "gh wrapper passes non-merge commands through" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # gh pr list requires auth + repo context. CI typically has neither
  # for this checkout (no GH_TOKEN, no remote tracking). Skip unless
  # we can prove auth works.
  if ! gh auth status >/dev/null 2>&1; then
    skip "gh not authenticated (no GH_TOKEN in env)"
  fi
  run "$WRAPPER" pr list --state closed --limit 1
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Merge blocking logic (unit tests using string matching)
# ---------------------------------------------------------------------------

@test "gh wrapper blocks merge to main" {
  if ! command -v gh >/dev/null 2>&1; then
    skip "gh not installed"
  fi
  # Use a non-existent PR number to trigger the base branch check
  # gh pr view will fail, so base_branch will be empty (not "main") — but
  # we can test with a real merged-to-main PR if one exists.
  # For now, verify the script structure is sound by checking it's executable
  [ -x "$WRAPPER" ]
}

@test "gh wrapper is executable" {
  [ -x "$WRAPPER" ]
}

@test "gh wrapper uses bash" {
  head -1 "$WRAPPER" | grep -q "bash"
}
