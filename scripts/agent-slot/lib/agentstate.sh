# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Agent state for a slot, from `claude agents --json` joined on a working directory under the slot path:
#
#   idle     one session, at its prompt
#   busy     one session, mid-turn
#   waiting  one session, at a permission prompt or a question
#   absent   no session, and no process under the slot except the slot's own tmux panes
#   unknown  the lookup failed, more than one session matched, a claude process under the slot has no session, or a
#            process outside the slot's own panes has its working directory or an open file under the slot
#
# A process belongs to the slot's own panes when it descends from one, or when its environment names the slot tmux
# server and one of the slot's panes. The second covers a daemon a pane's shell started and let go of, such as
# powerlevel10k's gitstatusd, which is reparented to init but keeps the TMUX and TMUX_PANE it inherited.
#
# Only idle and absent let a slot be torn down. The inputs are read once per invocation by agentstate_load and shared
# by every slot a command looks at.

AGENTS_OK=0
AGENTS_JSON='[]'
AGENT_STATE=
AGENT_DETAIL=
AGENT_PIDS=
declare -gA _AGENT_PPID=() _AGENT_PANES=() _AGENT_PANE_IDS=()
_AGENT_UNDER=

agentstate_load() {
  local out line session pid id
  AGENTS_OK=1
  if ! bounded out claude-agents 15 "$AS_CLAUDE" agents --json \
    || ! AGENTS_JSON=$(contract_json -c 'if type == "array" then . else error("not an array") end' <<<"$out" 2>/dev/null); then
    AGENTS_OK=0 AGENTS_JSON='[]'
  fi

  _AGENT_PANES=() _AGENT_PANE_IDS=()
  if slot_tmux out 5 list-panes -a -F '#{session_name} #{pane_pid} #{pane_id}'; then
    while read -r session pid id; do
      [[ -n $session ]] || continue
      _AGENT_PANES[$session]+=" $pid"
      _AGENT_PANE_IDS[$session]+=" $id"
    done <<<"$out"
  fi

  _AGENT_PPID=()
  while read -r pid line; do
    [[ -n $pid ]] && _AGENT_PPID[$pid]=$line
  done < <(cat /proc/[0-9]*/stat 2>/dev/null | awk '{ pid = $1; sub(/^.*\) /, ""); print pid, $2 }')

  _AGENT_UNDER=$(find /proc/[0-9]*/cwd /proc/[0-9]*/fd -maxdepth 1 -lname "$AS_ROOT_REAL/*" -printf '%p\t%l\n' \
    2>/dev/null || true)
}

_agent_from_panes() {
  local pid=$1 panes=" $2 " hops=0
  while [[ -n $pid && $pid != 0 && $pid != 1 ]] && ((hops++ < 64)); do
    [[ $panes == *" $pid "* ]] && return 0
    pid=${_AGENT_PPID[$pid]:-}
  done
  return 1
}

_agent_env_in_panes() {
  local environ tmux_var pane
  environ=$(tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null) || return 1
  tmux_var=$(sed -n 's/^TMUX=//p' <<<"$environ")
  pane=$(sed -n 's/^TMUX_PANE=//p' <<<"$environ")
  tmux_var=${tmux_var%%,*}
  [[ -n $pane && ${tmux_var##*/} == "$AS_TMUX_SOCKET" && " $2 " == *" $pane "* ]]
}

# Usage: agentstate_of <repo> <n>
# Sets AGENT_STATE, AGENT_DETAIL (why, for unknown), and AGENT_PIDS (the Claude processes under the slot).
agentstate_of() {
  local repo=$1 n=$2 path base panes='' ids='' suffix sessions count entry pid target comm
  local -a outside=()
  path=$AS_ROOT_REAL/$repo/$n
  base=$(slot_session "$repo" "$n")
  for suffix in '' -files -git; do
    panes+=${_AGENT_PANES[$base$suffix]:-}
    ids+=${_AGENT_PANE_IDS[$base$suffix]:-}
  done
  AGENT_STATE='' AGENT_DETAIL='' AGENT_PIDS=''

  sessions=$(contract_json -c --arg p "$path" '[.[] | select(.cwd == $p or (.cwd | startswith($p + "/")))]' \
    <<<"$AGENTS_JSON")
  count=$(contract_json 'length' <<<"$sessions")
  AGENT_PIDS=$(contract_json -r '[.[].pid] | map(tostring) | join(" ")' <<<"$sessions")

  while IFS=$'\t' read -r entry target; do
    [[ -n $entry ]] || continue
    [[ $target == "$path" || $target == "$path"/* ]] || continue
    pid=${entry#/proc/}
    pid=${pid%%/*}
    [[ $pid == "$$" || $pid == "$BASHPID" ]] && continue
    if _agent_from_panes "$pid" "$panes"; then
      comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
      if [[ $comm == claude && " $AGENT_PIDS " != *" $pid "* ]] && ((count == 0)); then
        AGENT_DETAIL="claude process $pid under the slot has no session in claude agents"
      fi
      continue
    fi
    _agent_env_in_panes "$pid" "$ids" && continue
    outside+=("$pid")
  done <<<"$_AGENT_UNDER"

  if ((AGENTS_OK == 0)); then
    AGENT_DETAIL="claude agents --json failed"
  elif ((count > 1)); then
    AGENT_DETAIL="$count Claude sessions run under the slot"
  elif ((${#outside[@]} > 0)); then
    AGENT_DETAIL="processes outside the slot's tmux panes use the slot: $(printf '%s\n' "${outside[@]}" | sort -un | paste -sd ' ')"
  fi
  if [[ -n $AGENT_DETAIL ]]; then
    AGENT_STATE=unknown
  elif ((count == 0)); then
    AGENT_STATE=absent
  else
    AGENT_STATE=$(contract_json -r '.[0].status // "unknown"' <<<"$sessions")
    case $AGENT_STATE in
      idle | busy | waiting) ;;
      *)
        AGENT_DETAIL="claude agents reported status $AGENT_STATE"
        AGENT_STATE=unknown
        ;;
    esac
  fi
}
