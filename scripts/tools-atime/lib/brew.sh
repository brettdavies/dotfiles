# Homebrew adapter. brew_rows() emits one row per `brew leaves` formula.
# RECLAIM includes the fixed-point closure of deps `brew autoremove` would
# cascade after the leaf is uninstalled.

[[ -n "${TOOLS_ATIME_BREW:-}" ]] && return 0
TOOLS_ATIME_BREW=1

declare -A _BREW_DEPS _BREW_USERS _BREW_SIZE_CACHE
_BREW_CELLAR=""

_brew_load_graph() {
  _BREW_CELLAR=$(brew --cellar)
  local json name full_name deps n d
  json=$(brew info --json=v2 --installed 2>/dev/null) || return 1
  while IFS=$'\t' read -r name full_name deps; do
    _BREW_DEPS[$name]="$deps"
  done < <(printf '%s' "$json" | jaq -r \
    '.formulae[] | "\(.name)\t\(.full_name)\t\(.dependencies // [] | join(" "))"')
  for n in "${!_BREW_DEPS[@]}"; do
    for d in ${_BREW_DEPS[$n]}; do
      _BREW_USERS[$d]="${_BREW_USERS[$d]:-} $n"
    done
  done
}

_brew_version_dir() {
  local bare=${1##*/} dir="$_BREW_CELLAR/$1"
  [[ -d "$dir" ]] || dir="$_BREW_CELLAR/$bare"
  [[ -d "$dir" ]] || return
  find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n1
}

_brew_size_kb() {
  local bare=${1##*/}
  if [[ -z "${_BREW_SIZE_CACHE[$bare]+x}" ]]; then
    local vd
    vd=$(_brew_version_dir "$1")
    _BREW_SIZE_CACHE[$bare]=$(size_kb_of_dir "$vd")
  fi
  printf '%s\n' "${_BREW_SIZE_CACHE[$bare]:-0}"
}

# Fixed-point closure: set of bare names that would be removed if leaf $1
# were uninstalled and `brew autoremove` then ran.
_brew_closure() {
  local leaf=${1##*/}
  local -A R TD
  R[$leaf]=1
  local queue=("$leaf") cur d
  while ((${#queue[@]} > 0)); do
    cur=${queue[0]}; queue=("${queue[@]:1}")
    for d in ${_BREW_DEPS[$cur]:-}; do
      [[ -n "${TD[$d]+x}" ]] && continue
      TD[$d]=1
      queue+=("$d")
    done
  done
  local changed=1 all_in u
  while ((changed)); do
    changed=0
    for d in "${!TD[@]}"; do
      [[ -n "${R[$d]+x}" ]] && continue
      all_in=true
      for u in ${_BREW_USERS[$d]:-}; do
        if [[ -z "${R[$u]+x}" ]]; then all_in=false; break; fi
      done
      if [[ "$all_in" == "true" ]]; then R[$d]=1; changed=1; fi
    done
  done
  for d in "${!R[@]}"; do printf '%s\n' "$d"; done
}

brew_actions() { echo "u:uninstall+autoremove"; }

# brew_act <formula> <action_key>. Honors $DRYRUN.
brew_act() {
  local formula=$1 action=$2
  case "$action" in
    u|uninstall)
      if [[ "${DRYRUN:-true}" == "true" ]]; then
        echo "DRY-RUN: brew uninstall $formula && brew autoremove"
        return 0
      fi
      brew uninstall "$formula" && brew autoremove
      ;;
    *) echo "brew_act: unknown action $action" >&2; return 1 ;;
  esac
}

brew_rows() {
  command -v brew >/dev/null || return 0
  command -v jaq  >/dev/null || { echo "brew adapter requires jaq" >&2; return 1; }
  _brew_load_graph || return 1

  local formula vd bin_dir atime hasbin own_kb reclaim_kb f
  while IFS= read -r formula; do
    vd=$(_brew_version_dir "$formula") || continue
    [[ -z "$vd" ]] && continue
    bin_dir="$vd/bin"
    if [[ -d "$bin_dir" ]]; then
      atime=$(max_atime_in_dir "$bin_dir")
      [[ -z "$atime" ]] && continue
      hasbin=1
    else
      atime=$(atime_of "$vd") || continue
      [[ -z "$atime" ]] && continue
      hasbin=0
    fi
    own_kb=$(_brew_size_kb "$formula")
    reclaim_kb=0
    while IFS= read -r f; do
      reclaim_kb=$(( reclaim_kb + $(_brew_size_kb "$f") ))
    done < <(_brew_closure "$formula")
    emit_row brew "$atime" "$formula" "$hasbin" "$own_kb" "$reclaim_kb"
  done < <(brew leaves)
}
