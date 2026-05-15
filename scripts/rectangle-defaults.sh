#!/usr/bin/env bash
# One-shot configure script for Rectangle window-manager preferences.
#
# Enforces the "Recommended" shortcut preset (avoids Spectacle's ⌥⌘+arrow
# conflicts with system/app shortcuts), enables size-cycling on repeated
# presses (⌃⌥← twice → 2/3, three times → 1/3), and disables macOS native
# tiling so Rectangle is the sole snapper (no margins, no edge-drag preview
# overlay competing with Rectangle's hotkeys).
#
# Idempotent — safe to re-run. Rectangle's first-launch wizard sets these
# values when the user picks "Recommended"; this script makes them
# reproducible on a fresh machine bootstrap.
#
# Usage: bash scripts/rectangle-defaults.sh

set -euo pipefail

# --- macOS gate ---
if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOTE: Rectangle is macOS-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

# --- Verify Rectangle.app is installed (brew bundle should have placed it) ---
if [ ! -d "/Applications/Rectangle.app" ]; then
  echo "ERROR: /Applications/Rectangle.app not found." >&2
  echo "       Install first:  brew bundle --file=~/dotfiles/stow/brew/Brewfile" >&2
  echo "       Or directly:     brew install --cask rectangle" >&2
  exit 1
fi

# --- Rectangle preferences ---
echo "==> Writing Rectangle preferences"

# Recommended preset (⌃⌥+arrow halves, U/I/J/K quarters). Spectacle preset
# uses ⌥⌘+arrows which collide with browser tab nav and text cursor jumps.
defaults write com.knollsoft.Rectangle alternateDefaultShortcuts -int 1

# Cycle 1/2 → 2/3 → 1/3 on repeated presses of the same direction.
# Value 1 = cycle sizes; 0 = no special behavior on repeat.
defaults write com.knollsoft.Rectangle subsequentExecutionMode -int 1

# Brew handles updates — disable Rectangle's Sparkle auto-check.
defaults write com.knollsoft.Rectangle SUEnableAutomaticChecks -bool false

# --- macOS native tiling — disable so Rectangle owns snap behavior ---
echo "==> Disabling macOS native window tiling"

# Margin gap between tiled windows / from screen edge. Off → flush borders.
defaults write com.apple.WindowManager EnableTiledWindowMargins -bool false

# Drag a window to a screen edge → preview overlay + tile. Off → drag is
# just a move; only Rectangle hotkeys snap.
defaults write com.apple.WindowManager EnableTilingByEdgeDrag -bool false

# Hold ⌥ while dragging → tile preview. Off → ⌥-drag is just a move.
defaults write com.apple.WindowManager EnableTilingOptionAccelerator -bool false

# Drag to the top of the screen → maximize tile. Off → no top-edge maximize.
defaults write com.apple.WindowManager EnableTopTilingByEdgeDrag -bool false

# --- Flush preference cache + restart Rectangle to pick up new prefs ---
echo "==> Flushing preference cache (cfprefsd)"
killall cfprefsd 2>/dev/null || true

if pgrep -q Rectangle; then
  echo "==> Restarting Rectangle to apply new preferences"
  killall Rectangle 2>/dev/null || true
  sleep 1
  open -a Rectangle
fi

# --- Verify ---
echo ""
echo "==> Verifying applied settings"
echo "    Rectangle:"
for key in alternateDefaultShortcuts subsequentExecutionMode SUEnableAutomaticChecks; do
  v=$(defaults read com.knollsoft.Rectangle "$key" 2>/dev/null || echo "<unset>")
  echo "      $key = $v"
done
echo "    com.apple.WindowManager:"
for key in EnableTiledWindowMargins EnableTilingByEdgeDrag EnableTilingOptionAccelerator EnableTopTilingByEdgeDrag; do
  v=$(defaults read com.apple.WindowManager "$key" 2>/dev/null || echo "<unset>")
  echo "      $key = $v"
done

echo ""
echo "Done. Test with ⌃⌥← on any window. Re-launch is required for first-time"
echo "Accessibility grant — System Settings → Privacy & Security → Accessibility."
