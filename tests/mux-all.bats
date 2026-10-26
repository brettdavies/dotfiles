#!/usr/bin/env bats
# Tests for the mux-all helper in config/shell/tmuxinator.sh
#
# Run: bats tests/mux-all.bats
#
# `tmuxinator` and `tmux` are replaced by scripts on PATH: the real ones would
# start sessions on the machine running the tests. The fixture config dir holds
# the two `name:` shapes mux-all has to read — a display name that differs from
# the filename, and one that matches.

TMUXINATOR_SH="$BATS_TEST_DIRNAME/../config/shell/tmuxinator.sh"

setup() {
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  export FIXTURES="$BATS_TEST_TMPDIR/configs"
  export TMUXINATOR_LOG="$BATS_TEST_TMPDIR/tmuxinator.log"
  mkdir -p "$FAKE_BIN" "$FIXTURES"

  printf 'name: Alpha Session\nroot: ~/\n' >"$FIXTURES/alpha.yml"
  printf 'name: beta\nroot: ~/\n' >"$FIXTURES/beta.yml"

  # Fails the project named in START_FAILS, succeeds otherwise.
  cat >"$FAKE_BIN/tmuxinator" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXINATOR_LOG"
[ "$1" = start ] || exit 0
[ "$2" = "${START_FAILS:-}" ] && exit 1
exit 0
STUB

  # Reports the session named in RUNNING as existing. Compared whole: a
  # display name legitimately contains spaces.
  cat >"$FAKE_BIN/tmux" <<'STUB'
#!/bin/sh
[ "$1" = has-session ] || exit 0
[ -n "${RUNNING:-}" ] || exit 1
[ "$3" = "=${RUNNING}" ]
STUB
  chmod +x "$FAKE_BIN/tmuxinator" "$FAKE_BIN/tmux"
}

# mux-all reads TMUXINATOR_CONFIG, which the file sets to the repo when that
# path exists; the fixture assignment has to land after sourcing.
mux_all_with() {
  PATH="$FAKE_BIN:$PATH"
  # shellcheck disable=SC1090
  . "$TMUXINATOR_SH"
  export TMUXINATOR_CONFIG="$FIXTURES"
  mux-all
}

starts_attempted() {
  [ -f "$TMUXINATOR_LOG" ] || {
    echo 0
    return
  }
  # grep -c prints its 0 and then exits 1, which would append a second count.
  grep -c '^start ' "$TMUXINATOR_LOG" || true
}

# ---------------------------------------------------------------------------
# Counts
# ---------------------------------------------------------------------------

@test "every configured project is started" {
  run mux_all_with
  [ "$status" -eq 0 ]
  [ "$(starts_attempted)" -eq 2 ]
  [[ "$output" == *"started 2"* ]]
  [[ "$output" == *"skipped 0"* ]]
  [[ "$output" == *"failed 0"* ]]
}

# The session name comes from the config's `name:` field, which is free to
# differ from the filename mux-all starts by.
@test "a running session is skipped rather than started again" {
  RUNNING="Alpha Session" run mux_all_with
  [ "$status" -eq 0 ]
  [ "$(starts_attempted)" -eq 1 ]
  [[ "$output" == *"started 1"* ]]
  [[ "$output" == *"skipped 1"* ]]
}

# ---------------------------------------------------------------------------
# Failed starts
#
# A project whose on_project_start hook fails never creates its session, so
# counting it as started reports sessions that do not exist.
# ---------------------------------------------------------------------------

@test "a project that fails to start is counted as failed, not started" {
  START_FAILS=beta run mux_all_with
  [ "$(starts_attempted)" -eq 2 ]
  [[ "$output" == *"started 1"* ]]
  [[ "$output" == *"failed 1"* ]]
}

@test "a failed start names the project" {
  START_FAILS=beta run mux_all_with
  [[ "$output" == *"beta failed to start"* ]]
}

@test "a failed start makes mux-all exit non-zero" {
  START_FAILS=beta run mux_all_with
  [ "$status" -eq 1 ]
}

@test "a failed start does not stop the remaining projects" {
  START_FAILS=alpha run mux_all_with
  [ "$(starts_attempted)" -eq 2 ]
  [[ "$output" == *"started 1"* ]]
  [[ "$output" == *"failed 1"* ]]
}
