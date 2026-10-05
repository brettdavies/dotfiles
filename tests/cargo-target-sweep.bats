#!/usr/bin/env bats
# cargo-target-sweep deletes Rust build output no build has used in DAYS days.
#
# cargo-sweep does the unit-level pass and is stubbed here; the script's own
# passes (orphaned example binaries, idle incremental crate directories, idle
# semver-checks workspaces) run against a fabricated target tree whose access
# times are set with `touch -a`. The script reads only metadata, so nothing it
# does moves those times.
#
# Run: bats tests/cargo-target-sweep.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
CARGO_PKG_DIR="$REPO_ROOT/stow/cargo"
SCRIPT="$CARGO_PKG_DIR/dot-local/bin/cargo-target-sweep"
SERVICE="$CARGO_PKG_DIR/dot-config/systemd/user/cargo-target-sweep.service"
TIMER="$CARGO_PKG_DIR/dot-config/systemd/user/cargo-target-sweep.timer"
BREWFILE="$REPO_ROOT/stow/brew/Brewfile"

LIVE=aaaaaaaaaaaaaaaa
GONE=bbbbbbbbbbbbbbbb

setup() {
  ROOT="$BATS_TEST_TMPDIR/dev"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  SWEEP_ARGS="$BATS_TEST_TMPDIR/cargo-sweep.args"
  export SWEEP_ARGS
  mkdir -p "$STUBS"
  cat >"$STUBS/cargo-sweep" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$SWEEP_ARGS"
EOF
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/cargo"
  chmod +x "$STUBS/cargo-sweep" "$STUBS/cargo"

  T="$ROOT/proj/target"
  _cargo_target "$T"
  mkdir -p "$T/debug/.fingerprint/pkg-$LIVE" "$T/debug/examples"
  : >"$T/debug/.fingerprint/pkg-$LIVE/lib-pkg"
  : >"$T/debug/examples/demo"
  : >"$T/debug/examples/demo-$LIVE"
  : >"$T/debug/examples/demo-$GONE"
  : >"$T/debug/examples/demo-$GONE.d"
  _file "$T/debug/incremental/old_crate-0abc/s-1/dep-graph.bin" 20
  _file "$T/debug/incremental/new_crate-0def/s-2/dep-graph.bin" 0
  _file "$T/x86_64-pc-windows-gnu/debug/incremental/win_crate-0ghi/s-3/dep-graph.bin" 20
  _file "$T/semver-checks/local-old/target/debug/lib.rlib" 20
  _file "$T/semver-checks/local-new/target/debug/lib.rlib" 0
}

# A target directory cargo created: it carries cargo's CACHEDIR.TAG.
_cargo_target() {
  mkdir -p "$1"
  printf 'Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n' >"$1/CACHEDIR.TAG"
}

# _file PATH DAYS: create PATH, last accessed DAYS days ago. `touch -d` is GNU
# only, so the stamp for `touch -t` comes from BSD date's -v, else GNU date's -d.
_file() {
  local stamp
  mkdir -p "$(dirname "$1")"
  : >"$1"
  stamp=$(date -v-"$2"d +%Y%m%d%H%M.%S 2>/dev/null || date -d "$2 days ago" +%Y%m%d%H%M.%S)
  touch -a -t "$stamp" "$1"
}

# stow-deploy installs the script on Linux only, and it sizes what it removes
# with GNU `du -b`, which BSD du rejects.
_sweep() {
  [ "$(uname -s)" = Linux ] || skip "cargo-target-sweep runs on Linux only"
  PATH="$STUBS:$PATH" run "$SCRIPT" "$@"
}

@test "removes example binaries whose unit is gone, keeping live and unhashed ones" {
  _sweep "$ROOT"
  [ "$status" -eq 0 ]
  [ -e "$T/debug/examples/demo" ]
  [ -e "$T/debug/examples/demo-$LIVE" ]
  [ ! -e "$T/debug/examples/demo-$GONE" ]
  [ ! -e "$T/debug/examples/demo-$GONE.d" ]
  [[ "$output" == *"removed 2 example binaries"* ]]
}

@test "removes incremental crate directories no file of which was used in DAYS days" {
  _sweep "$ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$T/debug/incremental/old_crate-0abc" ]
  [ ! -e "$T/x86_64-pc-windows-gnu/debug/incremental/win_crate-0ghi" ]
  [ -e "$T/debug/incremental/new_crate-0def/s-2/dep-graph.bin" ]
}

@test "removes semver-checks workspaces no file of which was used in DAYS days" {
  _sweep "$ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$T/semver-checks/local-old" ]
  [ -e "$T/semver-checks/local-new/target/debug/lib.rlib" ]
}

@test "CARGO_TARGET_SWEEP_DAYS sets the window" {
  CARGO_TARGET_SWEEP_DAYS=30 _sweep "$ROOT"
  [ "$status" -eq 0 ]
  [ -e "$T/debug/incremental/old_crate-0abc/s-1/dep-graph.bin" ]
  grep -qx 30 "$SWEEP_ARGS"
}

@test "--dry-run reports and removes nothing" {
  _sweep --dry-run "$ROOT"
  [ "$status" -eq 0 ]
  [ -e "$T/debug/examples/demo-$GONE" ]
  [ -e "$T/debug/incremental/old_crate-0abc/s-1/dep-graph.bin" ]
  [ -e "$T/semver-checks/local-old/target/debug/lib.rlib" ]
  [[ "$output" == *"would remove 2 example binaries"* ]]
  [[ "$output" == *"would remove 2 incremental crate directories"* ]]
  grep -qx -- --dry-run "$SWEEP_ARGS"
}

@test "hands cargo-sweep the root with --recursive and --time DAYS" {
  _sweep "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(paste -sd' ' "$SWEEP_ARGS")" = "sweep --recursive --time 14 $ROOT" ]
}

@test "leaves hidden directories and target directories cargo did not create alone" {
  _file "$ROOT/.hidden/target/debug/incremental/c-0abc/s-1/f" 20
  _cargo_target "$ROOT/.hidden/target"
  _file "$ROOT/other/target/debug/incremental/c-0abc/s-1/f" 20
  _sweep "$ROOT"
  [ "$status" -eq 0 ]
  [ -e "$ROOT/.hidden/target/debug/incremental/c-0abc/s-1/f" ]
  [ -e "$ROOT/other/target/debug/incremental/c-0abc/s-1/f" ]
}

@test "rejects a window that is not a positive whole number of days" {
  CARGO_TARGET_SWEEP_DAYS=two _sweep "$ROOT"
  [ "$status" -eq 2 ]
  CARGO_TARGET_SWEEP_DAYS=0 _sweep "$ROOT"
  [ "$status" -eq 2 ]
}

@test "the service runs the script with cargo and Homebrew on PATH" {
  grep -q '^ExecStart=%h/.local/bin/cargo-target-sweep$' "$SERVICE"
  grep -qE '^Environment=PATH=.*%h/\.cargo/bin' "$SERVICE"
  grep -qE '^Environment=PATH=.*/home/linuxbrew/\.linuxbrew/bin' "$SERVICE"
  grep -q '^Type=oneshot$' "$SERVICE"
}

@test "the timer fires weekly, randomized, catching up after downtime" {
  grep -qE '^OnCalendar=(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \*-\*-\* [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$TIMER"
  grep -qE '^RandomizedDelaySec=' "$TIMER"
  grep -q '^Persistent=true$' "$TIMER"
  grep -q '^WantedBy=timers.target$' "$TIMER"
}

@test "the Brewfile installs cargo-sweep on Linux" {
  grep -qE '^brew "cargo-sweep" if OS\.linux\?$' "$BREWFILE"
}
