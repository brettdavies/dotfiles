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
  run "$SCRIPT"
  [[ "$output" == *"==> Stowing secrets"* ]]
  [[ "$output" == *"==> Stowing shell"* ]]
  [[ "$output" == *"==> Stowing claude"* ]]
  [[ "$output" == *"==> Stowing brew"* ]]
}

@test "explicit args extend SHARED_PACKAGES" {
  run "$SCRIPT" ghostty
  [[ "$output" == *"==> Stowing secrets"* ]]
  [[ "$output" == *"==> Stowing ghostty"* ]]
}

@test "local package is not rejected" {
  run "$SCRIPT" local
  [[ "$output" != *"rejected"* ]]
  [[ "$output" == *"==> Stowing local"* ]]
}

# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

@test "duplicate packages are deduplicated" {
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
