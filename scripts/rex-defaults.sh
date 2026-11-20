#!/usr/bin/env bash
# One-shot configure script for Rex app preferences (com.superlogical.rex).
#
# Rex stores a setting only once it differs from the app default, so this list is the full set of choices. Window
# frames, activity history, sync state, and the rex.server.* keys stay out: they are per-machine runtime state.
#
# Idempotent; safe to re-run. Rex reads these at launch, so quit and reopen it after a run.
#
# Usage: bash scripts/rex-defaults.sh

set -euo pipefail

DOMAIN=com.superlogical.rex
FONT_NAME='MesloLGSDZ Nerd Font Mono'

if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOTE: the Rex app is macOS-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

if [ ! -d "/Applications/Rex.app" ]; then
  echo "ERROR: /Applications/Rex.app not found. Install Rex first, then re-run this script." >&2
  exit 1
fi

if ! compgen -G "$HOME/Library/Fonts/${FONT_NAME// /}-*" >/dev/null && ! compgen -G "/Library/Fonts/${FONT_NAME// /}-*" >/dev/null; then
  echo "WARNING: font '${FONT_NAME}' is not installed; Rex falls back to its default font." >&2
  echo "      Install:  brew install --cask font-meslo-lg-nerd-font" >&2
fi

# type|key|value
PREFS=$(
  cat <<EOF
string|Workspace.appearance|system
string|Workspace.darkThemeID|merino-dark
string|Workspace.lightThemeID|merino-light
string|Workspace.tabStyle|vertical
string|Workspace.tabIconTintMode|off
string|Workspace.sidebarPosition|left
bool|Workspace.sidebarShowsActivity|false
float|Workspace.sidebarTextPointSize|13
string|Workspace.activityGrouping|priority
bool|Workspace.showsActivePaneBorder|true
string|Workspace.activePaneBorderColor|yellow
float|Workspace.activePaneBorderOpacity|1
string|Workspace.inactivePaneFadeMode|both
bool|Workspace.usesStandardInactiveWindowPaneStyles|true
string|Workspace.terminalFontName|${FONT_NAME}
float|Workspace.terminalFontPointSize|12
float|Workspace.terminalCellHeightPercent|0
bool|Workspace.terminalAllowsLigatures|false
bool|Workspace.terminalFontSmoothing|true
bool|Workspace.terminalUsesDisplayP3|false
bool|Workspace.terminalImproveTextContrast|true
bool|Workspace.terminalCopyOnSelect|true
bool|Workspace.terminalSelectionRoundedCorners|true
bool|Workspace.terminalSmoothScrolling|true
bool|Workspace.smoothResizeEnabled|true
bool|Workspace.cursorShadersEnabled|false
bool|Workspace.prefersGeneratedTitles|true
string|Workspace.experiments.terminalGridAnchor|bottom
string|Workspace.sshAgentChoice|1password
bool|rex.agents.names-sessions|false
bool|rex.client.remoteControl|true
bool|rex.developer-mode-enabled|true
EOF
)

# Normalizes a value to the form `defaults read` prints it in: bools as 1/0, floats without trailing zeros.
expected_readback() {
  local type=$1 value=$2
  case "$type" in
    bool) [ "$value" = true ] && echo 1 || echo 0 ;;
    float) printf '%g\n' "$value" ;;
    *) echo "$value" ;;
  esac
}

echo "==> Writing Rex preferences"
while IFS='|' read -r type key value; do
  defaults write "$DOMAIN" "$key" "-$type" "$value"
done <<<"$PREFS"

echo "==> Verifying"
mismatches=0
while IFS='|' read -r type key value; do
  want=$(expected_readback "$type" "$value")
  got=$(defaults read "$DOMAIN" "$key" 2>/dev/null || echo "<unset>")
  if [ "$got" = "$want" ]; then
    echo "    ok    $key = $got"
  else
    echo "    FAIL  $key = $got (want $want)" >&2
    mismatches=$((mismatches + 1))
  fi
done <<<"$PREFS"

if [ "$mismatches" -gt 0 ]; then
  echo "ERROR: $mismatches Rex preference(s) did not stick." >&2
  exit 1
fi

if pgrep -xq Rex; then
  echo "Done. Quit and reopen Rex to load these."
else
  echo "Done."
fi
