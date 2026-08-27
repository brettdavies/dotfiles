#!/usr/bin/env bats
# Tests for scripts/rust-home-consolidate.sh
#
# Run: bats tests/rust-home-consolidate.bats
#
# The script resolves rustup, trash, systemctl and pgrep from PATH, so every
# precondition is driven with a stub on a prepended PATH rather than with a
# test-only flag in the script itself.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/rust-home-consolidate.sh"

setup() {
  FIX="$BATS_TEST_TMPDIR/fix"
  STUB="$FIX/stub"
  TRASHED="$FIX/trashed"
  RUSTUP_SRC="$FIX/cache/rustup"
  RUSTUP_DST="$FIX/home/.rustup"
  CARGO_SRC="$FIX/cache/cargo"
  CARGO_DST="$FIX/home/.cargo"
  export RUSTUP_SRC RUSTUP_DST CARGO_SRC CARGO_DST

  mkdir -p "$STUB" "$TRASHED"
  mkdir -p "$RUSTUP_SRC/toolchains" "$RUSTUP_DST/toolchains"
  mkdir -p "$CARGO_SRC/bin" "$CARGO_DST/bin"

  # Source holds the three pinned toolchains plus a stale `stable` that must not
  # displace the newer one already at the destination.
  for tc in nightly-x86_64-unknown-linux-gnu \
    1.94.1-x86_64-unknown-linux-gnu \
    1.96.0-x86_64-unknown-linux-gnu \
    stable-x86_64-unknown-linux-gnu; do
    mkdir -p "$RUSTUP_SRC/toolchains/$tc"
    echo "$tc" >"$RUSTUP_SRC/toolchains/$tc/marker"
  done
  mkdir -p "$RUSTUP_DST/toolchains/stable-x86_64-unknown-linux-gnu"
  echo "newer" >"$RUSTUP_DST/toolchains/stable-x86_64-unknown-linux-gnu/marker"

  printf 'default_toolchain = "stable-x86_64-unknown-linux-gnu"\n\n[overrides]\n' \
    >"$RUSTUP_SRC/settings.toml"
  printf 'default_toolchain = "stable-x86_64-unknown-linux-gnu"\n\n[overrides]\n' \
    >"$RUSTUP_DST/settings.toml"

  # Unique user crates plus a rustup shim that exists on both sides.
  for b in bird cargo-deny vtracer xr rustup; do
    echo '#!/bin/sh' >"$CARGO_SRC/bin/$b"
    chmod +x "$CARGO_SRC/bin/$b"
  done
  for b in rustup cargo; do
    echo '#!/bin/sh' >"$CARGO_DST/bin/$b"
    chmod +x "$CARGO_DST/bin/$b"
  done
  echo 'src-registry' >"$CARGO_SRC/.crates.toml"
  echo 'src-config' >"$CARGO_SRC/config.toml"
  echo 'token' >"$CARGO_SRC/credentials.toml"
  chmod 600 "$CARGO_SRC/credentials.toml"
  echo 'stale-path' >"$CARGO_SRC/env"
  echo 'correct-path' >"$CARGO_DST/env"

  # rustup stub lists whatever actually sits at the destination, so the
  # post-migration assertion is a real check rather than a fixed string.
  cat >"$STUB/rustup" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "toolchain" ] && [ "$2" = "list" ]; then
  ls "$RUSTUP_DST/toolchains" 2>/dev/null
fi
exit 0
EOF
  cat >"$STUB/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$STUB/trash" <<'EOF'
#!/usr/bin/env bash
for p in "$@"; do mv "$p" "$TRASHED/$(basename "$p").$$" 2>/dev/null || true; done
EOF
  chmod +x "$STUB/rustup" "$STUB/cargo" "$STUB/trash"
  export TRASHED
  PATH="$STUB:$PATH"
  export PATH
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

@test "unknown flag exits with the usage code" {
  run "$SCRIPT" --nope
  [ "$status" -eq 2 ]
}

@test "--help exits zero and names the apply flag" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--apply"* ]]
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

@test "dry run reports the colliding stable toolchain as a skip" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip stable-x86_64-unknown-linux-gnu (destination exists)"* ]]
}

@test "dry run plans a move for each pinned toolchain" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"move nightly-x86_64-unknown-linux-gnu"* ]]
  [[ "$output" == *"move 1.94.1-x86_64-unknown-linux-gnu"* ]]
  [[ "$output" == *"move 1.96.0-x86_64-unknown-linux-gnu"* ]]
}

@test "dry run mutates nothing" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$RUSTUP_SRC/toolchains/nightly-x86_64-unknown-linux-gnu" ]
  [ -d "$RUSTUP_SRC/toolchains/stable-x86_64-unknown-linux-gnu" ]
  [ ! -d "$RUSTUP_DST/toolchains/nightly-x86_64-unknown-linux-gnu" ]
  [ -f "$CARGO_SRC/bin/bird" ]
  [ ! -f "$CARGO_DST/bin/bird" ]
  [ "$(cat "$RUSTUP_DST/toolchains/stable-x86_64-unknown-linux-gnu/marker")" = "newer" ]
}

@test "dry run reports the reclaimable byte count" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reclaimed by deleting both cache trees"* ]]
}

@test "dry run says how to make it real" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Re-run with --apply"* ]]
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

@test "homes on different devices exit with the device code" {
  [ -d /dev/shm ] || skip "no second device available (/dev/shm absent)"
  alt="/dev/shm/rust-home-consolidate-$$"
  mkdir -p "$alt/toolchains"
  run env RUSTUP_SRC="$alt" "$SCRIPT"
  rm -rf "$alt"
  [ "$status" -eq 5 ]
  [[ "$output" == *"different device"* ]]
}

@test "an active rustup-update.timer blocks the run" {
  cat >"$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB/systemctl"
  run "$SCRIPT"
  [ "$status" -eq 6 ]
  [[ "$output" == *"active"* ]]
}

@test "a running cargo process blocks the run" {
  cat >"$STUB/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "$2" = "cargo" ] && exit 0
exit 1
EOF
  chmod +x "$STUB/pgrep"
  run "$SCRIPT"
  [ "$status" -eq 9 ]
  [[ "$output" == *"cargo or rustc process is running"* ]]
}

@test "an install registry at the destination blocks the run" {
  echo 'dst-registry' >"$CARGO_DST/.crates.toml"
  run "$SCRIPT"
  [ "$status" -eq 7 ]
  [[ "$output" == *"would overwrite"* ]]
}

@test "a non-empty source override table blocks the run" {
  printf 'default_toolchain = "stable-x86_64-unknown-linux-gnu"\n\n[overrides]\n"/home/u/proj" = "1.94.1"\n' \
    >"$RUSTUP_SRC/settings.toml"
  run "$SCRIPT"
  [ "$status" -eq 8 ]
  [[ "$output" == *"overrides"* ]]
}

@test "a differing default toolchain blocks the run" {
  printf 'default_toolchain = "nightly-x86_64-unknown-linux-gnu"\n\n[overrides]\n' \
    >"$RUSTUP_SRC/settings.toml"
  run "$SCRIPT"
  [ "$status" -eq 8 ]
  [[ "$output" == *"default_toolchain differs"* ]]
}

@test "an empty override table does not block the run" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a missing home exits with the missing code" {
  run env CARGO_SRC="$FIX/nope" "$SCRIPT"
  [ "$status" -eq 4 ]
  [[ "$output" == *"not a directory"* ]]
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

@test "apply moves the pinned toolchains and leaves the newer stable in place" {
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ -d "$RUSTUP_DST/toolchains/nightly-x86_64-unknown-linux-gnu" ]
  [ -d "$RUSTUP_DST/toolchains/1.94.1-x86_64-unknown-linux-gnu" ]
  [ -d "$RUSTUP_DST/toolchains/1.96.0-x86_64-unknown-linux-gnu" ]
  [ "$(cat "$RUSTUP_DST/toolchains/stable-x86_64-unknown-linux-gnu/marker")" = "newer" ]
}

@test "apply moves unique binaries without overwriting the rustup shim" {
  cp "$CARGO_DST/bin/rustup" "$FIX/rustup-before"
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ -f "$CARGO_DST/bin/bird" ]
  [ -f "$CARGO_DST/bin/cargo-deny" ]
  [ -f "$CARGO_DST/bin/vtracer" ]
  [ -f "$CARGO_DST/bin/xr" ]
  run diff "$FIX/rustup-before" "$CARGO_DST/bin/rustup"
  [ "$status" -eq 0 ]
}

@test "apply moves the install registry and preserves the credentials mode" {
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ -f "$CARGO_DST/.crates.toml" ]
  [ -f "$CARGO_DST/config.toml" ]
  [ -f "$CARGO_DST/credentials.toml" ]
  mode=$(stat -f %Lp "$CARGO_DST/credentials.toml" 2>/dev/null || stat -c %a "$CARGO_DST/credentials.toml")
  [ "$mode" = "600" ]
}

@test "apply never overwrites the destination env file" {
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ "$(cat "$CARGO_DST/env")" = "correct-path" ]
}

@test "apply deletes both cache trees" {
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$RUSTUP_SRC" ]
  [ ! -d "$CARGO_SRC" ]
}

@test "apply fails verification when an expected toolchain is absent" {
  rm -rf "$RUSTUP_SRC/toolchains/1.96.0-x86_64-unknown-linux-gnu"
  run "$SCRIPT" --apply
  [ "$status" -eq 10 ]
  [[ "$output" == *"missing after migration"* ]]
}

# ---------------------------------------------------------------------------
# Resume after an interruption
# ---------------------------------------------------------------------------

@test "a toolchain already moved is skipped and the rest still migrate" {
  mv "$RUSTUP_SRC/toolchains/nightly-x86_64-unknown-linux-gnu" \
    "$RUSTUP_DST/toolchains/nightly-x86_64-unknown-linux-gnu"
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip nightly (absent from source)"* ]]
  [ -d "$RUSTUP_DST/toolchains/1.94.1-x86_64-unknown-linux-gnu" ]
  [ -d "$RUSTUP_DST/toolchains/1.96.0-x86_64-unknown-linux-gnu" ]
}

@test "a partially moved binary set completes on a re-run" {
  mv "$CARGO_SRC/bin/bird" "$CARGO_DST/bin/bird"
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ -f "$CARGO_DST/bin/cargo-deny" ]
  [ -f "$CARGO_DST/bin/vtracer" ]
  [ -f "$CARGO_DST/bin/xr" ]
}

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------

@test "rust-home-consolidate.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "$SCRIPT"
  [ "$status" -eq 0 ]
}
