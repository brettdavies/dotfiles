#!/usr/bin/env bats
# Tests for stow-deploy package sets, expansion, and deduplication
#
# Run: bats tests/stow-deploy-packages.bats

SCRIPT="$BATS_TEST_DIRNAME/../scripts/stow-deploy"
STOW_DIR="$BATS_TEST_DIRNAME/../stow"

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
  [[ "$shared" == *"gbrain"* ]]
  [[ "$shared" == *"codex-proxy"* ]]
}

@test "Linux-only case block covers expected packages" {
  # qmd and gbrain were both removed from this list when they became
  # cross-platform: file-level OS gating via STOW_FLAGS --ignore drops their
  # Linux-only systemd units on macOS while their cross-platform content still
  # deploys. See docs/solutions/architecture-patterns/
  # cross-platform-stow-package-gating-2026-05-17.md.
  #
  # codex-proxy stays Linux-only: the proxy runs only on the brain host; macOS
  # clients reach it over the tailnet, so they need neither its config nor units.
  grep -q 'rclone|obsidian|opendataloader-pdf|codex-proxy)' "$SCRIPT"
}

@test "gbrain ships cross-platform config (deploys on macOS, not Linux-only)" {
  # gbrain became cross-platform: its dot-gbrain/ config deploys on every OS as
  # the thin-client brain, while its systemd units (gbrain-sync/dream,
  # claude-code-archive) drop on macOS via the Darwin --ignore. It must NOT
  # appear in any Linux-only skip case.
  [ -f "$STOW_DIR/gbrain/dot-gbrain/config.json" ]
  ! grep -qE '\|gbrain\||\|gbrain\)' "$SCRIPT"
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
# Package expansion
# ---------------------------------------------------------------------------

@test "no args deploys SHARED_PACKAGES" {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed — stow-deploy bails before printing pkg names"
  run "$SCRIPT"
  [[ "$output" == *"==> Stowing secrets"* ]]
  [[ "$output" == *"==> Stowing shell"* ]]
  [[ "$output" == *"==> Stowing claude"* ]]
  [[ "$output" == *"==> Stowing brew"* ]]
}

@test "explicit args extend SHARED_PACKAGES" {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed — stow-deploy bails before printing pkg names"
  run "$SCRIPT" ghostty
  [[ "$output" == *"==> Stowing secrets"* ]]
  # ghostty is in DESKTOP_PACKAGES (macOS-only). On Darwin it stows;
  # on Linux it hits the platform guard and emits a WARNING. Either
  # output proves the explicit arg made it through expansion into the
  # per-package loop, which is what this test is asserting.
  [[ "$output" == *"==> Stowing ghostty"* || "$output" == *"WARNING: ghostty is macOS-only"* ]]
}

@test "local package is not rejected" {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed — stow-deploy bails before printing pkg names"
  run "$SCRIPT" local
  [[ "$output" != *"rejected"* ]]
  [[ "$output" == *"==> Stowing local"* ]]
}

# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

@test "duplicate packages are deduplicated" {
  [ -L "$HOME/.profile" ] || skip "dotfiles not deployed — stow-deploy bails before printing pkg names"
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
  grep -q 'claude).*\$HOME/.claude' "$SCRIPT"
  grep -q 'codex).*\$HOME/.codex' "$SCRIPT"
  grep -q 'git).*\$HOME/.config/git' "$SCRIPT"
  grep -q 'opencode).*\$HOME/.config/opencode' "$SCRIPT"
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
