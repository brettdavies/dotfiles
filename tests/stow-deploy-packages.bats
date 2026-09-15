#!/usr/bin/env bats
# Tests for stow-deploy package sets, expansion, and deduplication
#
# Run: bats tests/stow-deploy-packages.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/stow-deploy"
STOW_DIR="$BATS_TEST_DIRNAME/../stow"

# Every case that runs the script gets a per-test sandbox target. The isolation
# lives here, not in the skips below: a worktree or second clone must never
# re-point the live $HOME symlinks at itself.
setup() {
  export STOW_DEPLOY_TARGET="$BATS_TEST_TMPDIR/home"
  mkdir -p "$STOW_DEPLOY_TARGET"
}

# stow-deploy exits before naming any package when this checkout's git-crypt
# files are still ciphertext (fresh clone, CI), so only an unlocked checkout can
# exercise the deploy loop.
_require_unlocked_checkout() {
  grep -qI '' "$STOW_DIR/secrets/dot-secrets" 2>/dev/null \
    || skip "git-crypt locked in this checkout — stow-deploy bails before printing pkg names"
}

# ---------------------------------------------------------------------------
# Package set contents
# ---------------------------------------------------------------------------

@test "SHARED_PACKAGES contains expected packages" {
  shared=$(grep '^SHARED_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  [[ "$shared" == *"secrets"* ]]
  [[ "$shared" == *"shell"* ]]
  [[ "$shared" == *"git"* ]]
  [[ "$shared" == *"ssh"* ]]
  [[ "$shared" == *"claude"* ]]
  [[ "$shared" == *"local"* ]]
  [[ "$shared" == *"brew"* ]]
  [[ "$shared" == *"opendataloader-pdf"* ]]
  [[ "$shared" == *"codex-proxy"* ]]
}

@test "every SHARED_PACKAGES entry exists as a stow package" {
  # A name left in the list after its package directory is deleted makes stow
  # fail at deploy time, on whichever machine runs it next rather than here.
  shared=$(grep '^SHARED_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  missing=""
  for pkg in $shared; do
    [ -d "$STOW_DIR/$pkg" ] || missing="$missing $pkg"
  done
  [ -z "$missing" ] || {
    echo "SHARED_PACKAGES names packages with no stow/ directory:$missing"
    false
  }
}

@test "Linux-only case block covers expected packages" {
  # qmd is absent from this list because file-level OS gating via STOW_FLAGS
  # --ignore drops its Linux-only systemd units on macOS while its
  # cross-platform content still deploys. See docs/solutions/
  # architecture-patterns/cross-platform-stow-package-gating-2026-05-17.md.
  #
  # codex-proxy stays Linux-only: the proxy runs only on the brain host; macOS
  # clients reach it over the tailnet, so they need neither its config nor units.
  #
  # cargo is Linux-only because Rust toolchains are: the workstation carries no
  # cargo, so a config telling it how to fetch git dependencies has no reader.
  #
  # cswap ships systemd units only; macOS schedules the same rotation check
  # through the launchagent package instead.
  grep -qE 'rclone *\| *obsidian *\| *opendataloader-pdf *\| *codex-proxy *\| *cargo *\| *cswap *\)' "$SCRIPT"
}

@test "STOW_FLAGS always ignores .DS_Store" {
  # Finder turds should never be symlinked across any package on any OS.
  grep -q "STOW_FLAGS+=(--ignore='\\\\.DS_Store\$')" "$SCRIPT"
}

@test "STOW_FLAGS ignores systemd units on macOS only" {
  # Linux .service/.timer files scattered inside otherwise-shared packages
  # (stow/local, stow/rclone, stow/rust, stow/obsidian,
  # stow/opendataloader-pdf) must not symlink to ~/.config/systemd/user/
  # on a Mac. File-extension regex is required because stow's --ignore
  # filters file basenames, not directory names. The pattern lives inside
  # an explicit Darwin gate.
  grep -q 'if \[ "\$(uname -s)" = "Darwin" \]; then' "$SCRIPT"
  grep -q "STOW_FLAGS+=(--ignore='\\\\.(service|timer)\$')" "$SCRIPT"
}

@test "DESKTOP_PACKAGES contains expected packages" {
  desktop=$(grep '^DESKTOP_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  [[ "$desktop" == *"ghostty"* ]]
  [[ "$desktop" == *"cursor"* ]]
  [[ "$desktop" == *"launchagent"* ]]
}

@test "all SHARED_PACKAGES have stow directories" {
  shared=$(grep '^SHARED_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  for pkg in $shared; do
    [ -d "$STOW_DIR/$pkg" ] || {
      echo "Missing stow directory for shared package: $pkg" >&2
      return 1
    }
  done
}

@test "all DESKTOP_PACKAGES have stow directories" {
  desktop=$(grep '^DESKTOP_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  for pkg in $desktop; do
    [ -d "$STOW_DIR/$pkg" ] || {
      echo "Missing stow directory for desktop package: $pkg" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Every stow package is accounted for
#
# The checks above prove each listed name has a directory. This proves the
# reverse: a directory added under stow/ but named in no package set is never
# reached by `scripts/stow-deploy` or `--all`, so it lands in the real home only
# if someone stows it by hand on one machine. That deploys fine there and is
# silently absent on the next host, with no error to trace it back from.
#
# A package that genuinely cannot be deployed belongs in NOT_DEPLOYED with the
# reason, so the exemption is a decision on the record rather than an omission.
# ---------------------------------------------------------------------------

# tmuxinator — configs resolve through TMUXINATOR_CONFIG straight from the repo.
#   A copy under ~/.config/tmuxinator shadows it for `start`/`stop` but not
#   `list`, so nothing is stowed (see tests/tmuxinator-configs.bats).
# ollama — ships a drop-in under systemd/system/, a root-owned path stow cannot
#   write. It is installed with sudo and documented in stow/ollama/README.md.
NOT_DEPLOYED=(tmuxinator ollama)

@test "every stow package is deployed or explicitly exempt" {
  shared=$(grep '^SHARED_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  desktop=$(grep '^DESKTOP_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  accounted=" $shared $desktop ${NOT_DEPLOYED[*]} "

  orphans=""
  for dir in "$STOW_DIR"/*/; do
    pkg=$(basename "$dir")
    case "$accounted" in
      *" $pkg "*) ;;
      *) orphans="$orphans $pkg" ;;
    esac
  done

  [ -z "$orphans" ] || {
    echo "stow/ directories in no package set and not exempt:$orphans" >&2
    echo "Add each to SHARED_PACKAGES or DESKTOP_PACKAGES in scripts/stow-deploy," >&2
    echo "or to NOT_DEPLOYED above with the reason it cannot be deployed." >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Package expansion
# ---------------------------------------------------------------------------

@test "no args deploys SHARED_PACKAGES" {
  _require_unlocked_checkout
  run "$SCRIPT"
  [[ "$output" == *"==> Stowing secrets"* ]]
  [[ "$output" == *"==> Stowing shell"* ]]
  [[ "$output" == *"==> Stowing claude"* ]]
  [[ "$output" == *"==> Stowing brew"* ]]
}

@test "explicit args extend SHARED_PACKAGES" {
  _require_unlocked_checkout
  run "$SCRIPT" ghostty
  [[ "$output" == *"==> Stowing secrets"* ]]
  # ghostty is in DESKTOP_PACKAGES (macOS-only). On Darwin it stows;
  # on Linux it hits the platform guard and emits a WARNING. Either
  # output proves the explicit arg made it through expansion into the
  # per-package loop, which is what this test is asserting.
  [[ "$output" == *"==> Stowing ghostty"* || "$output" == *"WARNING: ghostty is macOS-only"* ]]
}

@test "local package is not rejected" {
  _require_unlocked_checkout
  run "$SCRIPT" local
  [[ "$output" != *"rejected"* ]]
  [[ "$output" == *"==> Stowing local"* ]]
}

# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

@test "duplicate packages are deduplicated" {
  _require_unlocked_checkout
  run "$SCRIPT" git ssh git ssh
  git_count=$(echo "$output" | grep -c "^==> Stowing git$" || true)
  ssh_count=$(echo "$output" | grep -c "^==> Stowing ssh$" || true)
  [ "$git_count" -eq 1 ]
  [ "$ssh_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Tree-fold target mapping
# ---------------------------------------------------------------------------

@test "get_fold_target maps known packages" {
  grep -q 'claude).*\$TARGET/.claude' "$SCRIPT"
  grep -q 'codex).*\$TARGET/.codex' "$SCRIPT"
  grep -q 'git).*\$TARGET/.config/git' "$SCRIPT"
  grep -q 'opencode).*\$TARGET/.config/opencode' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Post-deploy systemd --user timer recovery
# ---------------------------------------------------------------------------

@test "redeploys reset and restart the systemd timers a package ships" {
  # stow -R can race systemd during the unlink-relink and leave a timer failed
  # (no auto-recover); the deploy must reload + reset + restart the timers it
  # (re)deployed so the schedule cannot silently die.
  grep -qF 'dot-config/systemd/user/*.timer' "$SCRIPT"
  grep -qF 'systemctl --user daemon-reload' "$SCRIPT"
  grep -qF 'systemctl --user reset-failed' "$SCRIPT"
  grep -qF 'systemctl --user restart' "$SCRIPT"
}

@test "systemd timer recovery is guarded to a real Linux \$HOME deploy" {
  # Must not touch the live user manager from a sandboxed test target or on
  # macOS (launchd); guard requires Linux AND TARGET == HOME.
  grep -qF '[ "$(uname -s)" = "Linux" ] && [ "$TARGET" = "$HOME" ]' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Target isolation
# ---------------------------------------------------------------------------

@test "deploy target defaults to \$HOME when STOW_DEPLOY_TARGET is unset" {
  grep -qF 'TARGET="${STOW_DEPLOY_TARGET:-$HOME}"' "$SCRIPT"
}

@test "sandboxed deploy writes only under STOW_DEPLOY_TARGET" {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  # A copy of the script inside a fixture tree: one marker file per shared
  # package and no git-crypt gated file, so the deploy loop runs on any host.
  fixture="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$fixture/scripts"
  cp "$SCRIPT" "$fixture/scripts/stow-deploy"
  shared=$(grep '^SHARED_PACKAGES=' "$SCRIPT" | sed 's/.*(\(.*\))/\1/')
  for pkg in $shared; do
    mkdir -p "$fixture/stow/$pkg"
    echo "$pkg" >"$fixture/stow/$pkg/dot-stow-sandbox-$pkg"
  done

  run "$fixture/scripts/stow-deploy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> Stowing shell"* ]]
  [ -L "$STOW_DEPLOY_TARGET/.stow-sandbox-shell" ]
  [ "$(cat "$STOW_DEPLOY_TARGET/.stow-sandbox-shell")" = "shell" ]
  [ -z "$(compgen -G "$HOME/.stow-sandbox-*")" ]
}
