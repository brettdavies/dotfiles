# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# The symlinks under the home directory that resolve into slots, from one bounded scan shared by every slot a command
# checks. The scan covers bounded roots, where a link into a slot is plausible: a tool linked into ~/.local/bin, a
# config, or a skill. A scan that times out, fails, or finds no link at all proves nothing, so it counts as incomplete
# and blocks teardown.
#
# Env: AGENT_SLOT_HOME_SCAN_ROOTS  space-separated <dir>:<depth> roots (the defaults below)
#      AGENT_SLOT_HOME_SCAN_TIMEOUT seconds the scan may take (20)

HOME_SCAN_OK=0
HOME_SCAN_LINKS=

# Prints "<link>\t<resolved target>" for every symlink under the given <dir>:<depth> roots.
_home_scan_walk() {
  local spec dir targets links link target
  links=$(mktemp) targets=$(mktemp)
  for spec in "$@"; do
    dir=${spec%:*}
    [[ -d $dir ]] && find "$dir" -maxdepth "${spec##*:}" -type l -print0 2>/dev/null
  done >"$links"
  xargs -0 -r realpath -m -z -- <"$links" >"$targets"
  while IFS= read -r -d '' link <&3 && IFS= read -r -d '' target <&4; do
    printf '%s\t%s\n' "$link" "$target"
  done 3<"$links" 4<"$targets"
  rm -f "$links" "$targets"
}

home_scan_load() {
  local -a roots
  local out
  read -r -a roots <<<"${AGENT_SLOT_HOME_SCAN_ROOTS:-$HOME:1 $HOME/.local/bin:1 $HOME/.config:3 $HOME/.claude:3 $HOME/.agents:3 $HOME/dev:2 $HOME/bin:1}"
  HOME_SCAN_OK=0 HOME_SCAN_LINKS=
  if bounded out home-scan "${AGENT_SLOT_HOME_SCAN_TIMEOUT:-20}" bash -c "$(declare -f _home_scan_walk); _home_scan_walk \"\$@\"" \
    _ "${roots[@]}" && [[ -n $out ]]; then
    HOME_SCAN_OK=1 HOME_SCAN_LINKS=$out
  fi
}

# Usage: home_links_into <slot realpath>; prints the links that resolve into the slot, one per line.
home_links_into() {
  awk -F '\t' -v p="$1" '$2 == p || index($2, p "/") == 1 { print $1 }' <<<"$HOME_SCAN_LINKS"
}
