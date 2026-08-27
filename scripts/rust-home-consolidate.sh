#!/usr/bin/env bash
set -euo pipefail

# Consolidate a split Rust installation onto the stock ~/.cargo and ~/.rustup.
#
# A host that exported CARGO_HOME/RUSTUP_HOME into the cache directory ends up
# with two toolchain trees and two binary directories: rustup-init and every
# bare launcher wrote the stock paths, while interactive shells read the cache
# paths. This moves the cache-side toolchains, binaries and install registry
# onto the stock homes, then deletes what remains of the cache trees.
#
# Dry-run is the default. Nothing is moved or deleted without --apply.
#
# Usage: scripts/rust-home-consolidate.sh [--apply] [--help]
#
# Paths are overridable for testing:
#   RUSTUP_SRC RUSTUP_DST CARGO_SRC CARGO_DST

# Exit codes — distinct values for automation/CI (all non-zero still indicate failure)
EXIT_USAGE=2      # Bad arguments or flags
EXIT_DEPENDENCY=3 # Missing required tools (rustup, trash)
EXIT_MISSING=4    # A source or destination home is absent
EXIT_DEVICE=5     # Homes span devices, so a move is a copy rather than a rename
EXIT_TIMER=6      # rustup-update.timer is active
EXIT_REGISTRY=7   # Destination already holds an install registry
EXIT_SETTINGS=8   # Source carries pin state that would be lost
EXIT_BUILD=9      # A cargo/rustc process is running
EXIT_VERIFY=10    # Post-migration assertion failed

XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
RUSTUP_SRC="${RUSTUP_SRC:-$XDG_CACHE_HOME/rustup}"
RUSTUP_DST="${RUSTUP_DST:-$HOME/.rustup}"
CARGO_SRC="${CARGO_SRC:-$XDG_CACHE_HOME/cargo}"
CARGO_DST="${CARGO_DST:-$HOME/.cargo}"

# Only toolchains a pinned repository references are carried over. Anything else
# under the source home is left behind and deleted with the cache tree; rustup
# re-downloads it if that turns out wrong.
#
# `stable` stays in the list so its existence guard fires and is reported: it is
# the one name present in both homes, and the destination copy is the newer tree
# that has to survive. The same set is what has to resolve from the destination
# once the migration is done, so it drives both the move loop and the final
# assertion.
MIGRATE_TOOLCHAINS=(stable nightly 1.94.1 1.96.0)

APPLY=false

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  local code=$1
  shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

# Prefix every mutating line so a dry-run transcript reads as the plan it is.
act() {
  if [[ "$APPLY" == true ]]; then
    "$@"
  else
    info "  would run: $*"
  fi
}

usage() {
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit "$EXIT_USAGE"
      ;;
  esac
done

# device_of: st_dev for a path. A rename is atomic only within one device; across
# devices `mv` degrades to copy-then-delete, which can half-move a toolchain.
device_of() {
  stat -f %d "$1" 2>/dev/null || stat -c %d "$1" 2>/dev/null
}

size_kb() {
  [[ -d "$1" ]] || {
    echo 0
    return
  }
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

human_kb() { awk -v kb="${1:-0}" 'BEGIN { printf "%.1f GB", kb / 1048576 }'; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

command -v rustup >/dev/null 2>&1 || die "$EXIT_DEPENDENCY" "rustup not found on PATH"
if [[ "$APPLY" == true ]] && ! command -v trash >/dev/null 2>&1; then
  die "$EXIT_DEPENDENCY" "trash not found on PATH (the repo forbids rm)"
fi

for d in "$RUSTUP_SRC" "$RUSTUP_DST" "$CARGO_SRC" "$CARGO_DST"; do
  [[ -d "$d" ]] || die "$EXIT_MISSING" "not a directory: $d"
done

src_dev=$(device_of "$RUSTUP_SRC")
for d in "$RUSTUP_DST" "$CARGO_SRC" "$CARGO_DST"; do
  [[ "$(device_of "$d")" == "$src_dev" ]] \
    || die "$EXIT_DEVICE" "$d is on a different device than $RUSTUP_SRC; every move would be a copy"
done

# systemd user units never source the shell chain, so the timer has been driving
# the destination tree. Starting a move under it races the update it runs.
if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user is-active --quiet rustup-update.timer 2>/dev/null \
    || systemctl --user is-active --quiet rustup-update.service 2>/dev/null; then
    die "$EXIT_TIMER" "rustup-update.timer/.service is active; stop it before migrating"
  fi
fi

# A wholesale registry move would overwrite a destination registry and silently
# de-register every crate it lists.
for registry in .crates.toml .crates2.json; do
  [[ -e "$CARGO_DST/$registry" ]] \
    && die "$EXIT_REGISTRY" "$CARGO_DST/$registry exists; the registry move would overwrite it"
done

# Toolchain directories carry no pin state. `default_toolchain` and the
# per-directory [overrides] table live in settings.toml and do not travel with a
# move, so a non-empty source table would be lost silently.
src_settings="$RUSTUP_SRC/settings.toml"
dst_settings="$RUSTUP_DST/settings.toml"
if [[ -f "$src_settings" ]]; then
  if awk '/^\[overrides\]/ { inside = 1; next }
          /^\[/ { inside = 0 }
          inside && NF && $0 !~ /^[[:space:]]*#/ { found = 1 }
          END { exit !found }' "$src_settings"; then
    die "$EXIT_SETTINGS" "$src_settings has a non-empty [overrides] table; migrate those pins by hand first"
  fi
  src_default=$(awk -F'"' '/^default_toolchain/ { print $2 }' "$src_settings")
  dst_default=""
  [[ -f "$dst_settings" ]] && dst_default=$(awk -F'"' '/^default_toolchain/ { print $2 }' "$dst_settings")
  if [[ -n "$src_default" && -n "$dst_default" && "$src_default" != "$dst_default" ]]; then
    die "$EXIT_SETTINGS" "default_toolchain differs (source '$src_default', destination '$dst_default'); reconcile by hand first"
  fi
fi

# A build running during the cutover can write into a tree mid-move. The whole
# migration is one session, so a live cargo/rustc is the realistic way that
# happens.
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -x cargo >/dev/null 2>&1 || pgrep -x rustc >/dev/null 2>&1; then
    die "$EXIT_BUILD" "a cargo or rustc process is running; finish or stop the build first"
  fi
fi

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

info "=== Snapshot ==="
info "rustup toolchain list:"
rustup toolchain list 2>&1 | sed 's/^/  /'
info "cargo install --list:"
cargo install --list 2>/dev/null | sed 's/^/  /' || info "  (unavailable)"
for d in "$RUSTUP_SRC" "$RUSTUP_DST" "$CARGO_SRC" "$CARGO_DST"; do
  info "  $(human_kb "$(size_kb "$d")")  $d"
done
if [[ -f "$CARGO_SRC/credentials.toml" ]]; then
  info "  credentials.toml mode: $(stat -f %Lp "$CARGO_SRC/credentials.toml" 2>/dev/null \
    || stat -c %a "$CARGO_SRC/credentials.toml" 2>/dev/null)"
fi
info ""

# ---------------------------------------------------------------------------
# Move toolchains
# ---------------------------------------------------------------------------

# `mv` into an existing directory nests rather than fails, and a nested toolchain
# is invisible to `rustup toolchain list` while a directory count still looks
# right. Each move is guarded on the destination not existing.
info "=== Toolchains ==="
for tc in "${MIGRATE_TOOLCHAINS[@]}"; do
  matched=false
  for src in "$RUSTUP_SRC/toolchains/$tc"*; do
    [[ -d "$src" ]] || continue
    matched=true
    name=$(basename "$src")
    dst="$RUSTUP_DST/toolchains/$name"
    if [[ -e "$dst" ]]; then
      info "  skip $name (destination exists)"
      continue
    fi
    info "  move $name"
    act mv "$src" "$dst"
  done
  [[ "$matched" == true ]] || info "  skip $tc (absent from source)"
done
info ""

# ---------------------------------------------------------------------------
# Move binaries and the install registry
# ---------------------------------------------------------------------------

# Both bin directories hold rustup shims. An unguarded move would overwrite the
# rustup binary the timer invokes by absolute path, so only names unique to the
# source move across.
info "=== Binaries ==="
if [[ -d "$CARGO_SRC/bin" ]]; then
  act mkdir -p "$CARGO_DST/bin"
  for src in "$CARGO_SRC/bin"/*; do
    [[ -e "$src" ]] || continue
    name=$(basename "$src")
    dst="$CARGO_DST/bin/$name"
    if [[ -e "$dst" ]]; then
      info "  skip $name (destination exists)"
      continue
    fi
    info "  move $name"
    act mv "$src" "$dst"
  done
else
  info "  (no source bin directory)"
fi
info ""

# `env` is deliberately excluded: the destination copy already carries the
# correct path, and the source copy would install a stale absolute one.
info "=== Registry and config ==="
for f in .crates.toml .crates2.json config.toml credentials.toml; do
  src="$CARGO_SRC/$f"
  dst="$CARGO_DST/$f"
  [[ -e "$src" ]] || continue
  if [[ -e "$dst" ]]; then
    info "  skip $f (destination exists)"
    continue
  fi
  # A same-device rename preserves mode atomically and never leaves a second
  # copy of the crates.io token on disk.
  info "  move $f"
  act mv "$src" "$dst"
done
info ""

# ---------------------------------------------------------------------------
# Enumerate and delete the cache trees
# ---------------------------------------------------------------------------

# This is the irreversible step, so it is gated on an explicit enumeration rather
# than folded into the moves above. Recovery is a re-download.
info "=== Remaining under the cache paths ==="
reclaim_kb=0
for d in "$RUSTUP_SRC" "$CARGO_SRC"; do
  [[ -d "$d" ]] || continue
  kb=$(size_kb "$d")
  reclaim_kb=$((reclaim_kb + ${kb:-0}))
  info "  $(human_kb "$kb")  $d"
  find "$d" -mindepth 1 -maxdepth 2 2>/dev/null | sed 's/^/    /'
done
info ""
info "Reclaimed by deleting both cache trees: $(human_kb "$reclaim_kb")"

# No symlinks are left behind. Anything still resolving through the old paths
# afterwards is a stale consumer, and surfacing it is the point.
for d in "$RUSTUP_SRC" "$CARGO_SRC"; do
  [[ -d "$d" ]] || continue
  info "  delete $d"
  act trash "$d"
done
info ""

# ---------------------------------------------------------------------------
# Post-assertions
# ---------------------------------------------------------------------------

if [[ "$APPLY" != true ]]; then
  info "Dry run. Re-run with --apply to perform the migration."
  exit 0
fi

# Assert on the toolchain name set rather than a directory count: a nested
# toolchain still counts as a directory but resolves for nothing.
info "=== Verification ==="
listed=$(rustup toolchain list 2>/dev/null)
missing=()
for tc in "${MIGRATE_TOOLCHAINS[@]}"; do
  grep -q "^$tc" <<<"$listed" || missing+=("$tc")
done
if ((${#missing[@]})); then
  printf '%s\n' "$listed" | sed 's/^/  /' >&2
  die "$EXIT_VERIFY" "toolchains missing after migration: ${missing[*]}"
fi
printf '%s\n' "$listed" | sed 's/^/  /'
info "All expected toolchains resolve from $RUSTUP_DST."
