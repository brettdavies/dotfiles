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

# Cycle 1/2 → 2/3 → 1/3 on repeated presses of the same direction
# (Spectacle-style resize). Rectangle's SubsequentExecutionMode enum:
#   0 = resize          ← Spectacle-style size cycling (what we want)
#   1 = acrossMonitor   ← Rectangle Recommended preset default (moves to next display)
#   2 = none
#   3 = acrossAndResize
#   4 = cycleMonitor
#   5 = resizeAndCycleQuadrants
# Source: github.com/rxhanson/Rectangle Rectangle/SubsequentExecutionMode.swift
defaults write com.knollsoft.Rectangle subsequentExecutionMode -int 0

# Brew handles updates — disable Rectangle's Sparkle auto-check.
defaults write com.knollsoft.Rectangle SUEnableAutomaticChecks -bool false

# Repurpose ⌃⌥C: bind centerHalf (centered vertical column, cycles 1/2 →
# 2/3 → 1/3 on repeat — picked up automatically from subsequentExecutionMode=0)
# instead of the default `center` action (translate-only, no resize, no
# cycling). Same chord, more useful behavior.
#
# Modifier math: control (1<<18 = 0x40000) + option (1<<19 = 0x80000)
#                = 0xC0000 = 786432.
# keyCode 8 = 'C' (HIToolbox/Events.h).
# Source: Rectangle WindowAction.name + ShortcutManager.swift use MASShortcut
# dicts under each action's case-name as the UserDefaults key.
defaults write com.knollsoft.Rectangle centerHalf '{keyCode = 8; modifierFlags = 786432;}'

# Clear the default `center` binding so it doesn't fight `centerHalf` on
# the same chord. MASShortcut.isValid returns `keyCode >= 0 && keyCode !=
# NSNotFound`, so any negative keyCode is treated as "no shortcut" and
# won't bind. keyCode=0 would NOT work here — that's the 'A' key on macOS
# HIToolbox (which I learned the hard way; bound bare-A to `center` once).
defaults write com.knollsoft.Rectangle center '{keyCode = -1; modifierFlags = 0;}'

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
echo "    Rectangle shortcuts (overridden from preset defaults):"
for key in centerHalf center; do
  v=$(defaults read com.knollsoft.Rectangle "$key" 2>/dev/null | tr -d '\n' || echo "<default>")
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
