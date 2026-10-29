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
# A process belongs to the slot's own panes when it descends from one, or when it is powerlevel10k's gitstatusd and its
# environment names the slot tmux server and one of the slot's panes. The prompt starts gitstatusd under a subshell that
# init adopts, so no pane is above it, and it holds the slot's git pack open. Every process a pane starts inherits the
# same TMUX and TMUX_PANE, a job left running after its command ended included, so the environment alone admits only
# gitstatusd.
#
# Only idle and absent let a slot be torn down. The inputs are read once per invocation by agentstate_load and shared
# by every slot a command looks at.

AGENTS_OK=0
AGENTS_JSON='[]'
AGENT_STATE=
AGENT_DETAIL=
AGENT_PIDS=
AGENT_HOLDERS=()
declare -gA _AGENT_PPID=() _AGENT_PANES=() _AGENT_PANE_IDS=()
_AGENT_UNDER=
_AGENT_SCAN_PID=

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

  # The parent map is read on both sides of the scan for processes under the slots, so a child the scan lists keeps its
  # parent even when it was started after the first read and exits before anything looks at it.
  _AGENT_PPID=()
  _agent_read_parents
  _AGENT_UNDER=$(
    printf '%s\n' "$BASHPID"
    find /proc/[0-9]*/cwd /proc/[0-9]*/fd -maxdepth 1 -lname "$AS_ROOT_REAL/*" -printf '%p\t%l\n' 2>/dev/null || true
  )
  _agent_read_parents
  _AGENT_SCAN_PID=${_AGENT_UNDER%%$'\n'*}
  _AGENT_UNDER=${_AGENT_UNDER#"$_AGENT_SCAN_PID"}
  _AGENT_UNDER=${_AGENT_UNDER#$'\n'}
}

# Usage: _agent_read_parents; adds each live process's parent to the map, keeping the parent already read for a pid.
_agent_read_parents() {
  local pid ppid
  while read -r pid ppid; do
    [[ -z $pid || -n ${_AGENT_PPID[$pid]:-} ]] || _AGENT_PPID[$pid]=$ppid
  done < <(cat /proc/[0-9]*/stat 2>/dev/null | awk '{ pid = $1; sub(/^.*\) /, ""); print pid, $2 }')
}

# Usage: agentstate_descendants <pid...>; prints every process below the given ones, from the map agentstate_load read.
agentstate_descendants() {
  local -a queue=("$@")
  local pid child
  while ((${#queue[@]} > 0)); do
    pid=${queue[0]}
    queue=("${queue[@]:1}")
    for child in "${!_AGENT_PPID[@]}"; do
      [[ ${_AGENT_PPID[$child]} == "$pid" ]] || continue
      queue+=("$child")
      printf '%s\n' "$child"
    done
  done
}

# Usage: _agent_below <pid> <pids>; true when the pid is one of the space-separated pids or descends from one.
_agent_below() {
  local pid=$1 pids=" $2 " hops=0
  while [[ -n $pid && $pid != 0 && $pid != 1 ]] && ((hops++ < 64)); do
    [[ $pids == *" $pid "* ]] && return 0
    pid=${_AGENT_PPID[$pid]:-}
  done
  return 1
}

# Usage: agentstate_inside_agent; after agentstate_of, true when this process descends from the slot's Claude. Claude
# Code starts every Bash tool command, foreground or background, as a child of its own process, so a command the
# slot's agent runs descends from it from any working directory, and a command started anywhere else never does.
agentstate_inside_agent() {
  [[ -n $AGENT_PIDS ]] && _agent_below "$$" "$AGENT_PIDS"
}

# Usage: agentstate_jobs; after agentstate_of, prints "<pid> <command>" for each Bash tool command the slot's Claude
# still runs, other than the one this process runs in. Claude's hooks, status line, and plugin updates are its children
# too, so only a Bash tool command's shape counts (_agent_command).
agentstate_jobs() {
  local claude pid cmd
  for claude in $AGENT_PIDS; do
    for pid in "${!_AGENT_PPID[@]}"; do
      [[ ${_AGENT_PPID[$pid]} == "$claude" ]] || continue
      ! _agent_below "$$" "$pid" || continue
      cmd=$(_agent_command "$pid" tool) || continue
      printf '%s %s\n' "$pid" "${cmd:0:200}"
    done
  done | sort -n
}

# Usage: _agent_command <pid> [tool]; prints the process's command on one line, or fails once it has exited. A Bash
# tool command is a shell given -c a script that ends by writing its working directory to a claude-<hex>-cwd file, and
# shows as the command the agent wrote, unquoted from the script's eval '...'. With tool, any other process fails.
_agent_command() {
  local cmd shape='&& pwd -P >\| [^[:space:]]*/claude-[0-9a-f]+-cwd$'
  local -a argv=()
  mapfile -d '' argv 2>/dev/null <"/proc/$1/cmdline" || return 1
  ((${#argv[@]} > 0)) || return 1
  if ((${#argv[@]} >= 3)) && [[ ${argv[1]} == -c && ${argv[2]} =~ $shape ]]; then
    cmd=${argv[2]}
    if [[ $cmd == *"eval '"* ]]; then
      cmd=${cmd#*"eval '"}
      cmd=${cmd%" && pwd -P >| "*}
      cmd=${cmd%" < /dev/null"}
      cmd=${cmd%"'"}
      cmd=${cmd//"'\"'\"'"/"'"}
    fi
  elif [[ ${2:-} == tool ]]; then
    return 1
  else
    cmd=${argv[*]}
  fi
  printf '%s\n' "${cmd//[$'\n\t']/ }"
}

# Usage: _agent_pane_daemon <pid> <pane ids>; true when the process is gitstatusd and its environment names the slot
# tmux server and one of the space-separated panes. The kernel cuts comm to 15 characters, so gitstatusd-linux-x86_64
# reads as gitstatusd-linu.
_agent_pane_daemon() {
  local comm environ tmux_var pane
  read -r comm 2>/dev/null <"/proc/$1/comm" || return 1
  [[ $comm == gitstatusd* ]] || return 1
  environ=$(tr '\0' '\n' 2>/dev/null <"/proc/$1/environ") || return 1
  tmux_var=$(sed -n 's/^TMUX=//p' <<<"$environ")
  pane=$(sed -n 's/^TMUX_PANE=//p' <<<"$environ")
  tmux_var=${tmux_var%%,*}
  [[ -n $pane && ${tmux_var##*/} == "$AS_TMUX_SOCKET" && " $2 " == *" $pane "* ]]
}

# Usage: _agent_holder <pid> <pids>; prints the pid's oldest ancestor among the space-separated pids, which use the slot.
# A loop outside the panes that keeps starting short-lived children under the slot is then named once, by the loop that
# lives on, rather than by whichever child the scan caught, which has exited by the time anyone reads its pid.
_agent_holder() {
  local pid=$1 pids=" $2 " parent hops=0
  while ((hops++ < 64)); do
    parent=${_AGENT_PPID[$pid]:-}
    [[ -n $parent && $pids == *" $parent "* ]] || break
    pid=$parent
  done
  printf '%s\n' "$pid"
}

# Usage: _agent_described <pid>; prints "<pid> <command>" with the command cut to 80 characters, or the pid alone once
# the process has exited.
_agent_described() {
  local cmd
  cmd=$(_agent_command "$1") || cmd=
  printf '%s\n' "$1${cmd:+ ${cmd:0:80}}"
}

# Usage: agentstate_of <repo> <n>
# Sets AGENT_STATE, AGENT_DETAIL (why, for unknown), AGENT_HOLDERS ("<pid> <command>" for each process outside the
# slot's panes that holds the slot, named by _agent_holder), and AGENT_PIDS (the Claude processes under the slot).
agentstate_of() {
  local repo=$1 n=$2 path name panes='' ids='' kind sessions count entry pid target comm users=' ' holder held=''
  local -a outside=()
  path=$AS_ROOT_REAL/$repo/$n
  for kind in "${SLOT_SESSION_KINDS[@]}"; do
    name=$(slot_session "$repo" "$n" "$kind")
    panes+=${_AGENT_PANES[$name]:-}
    ids+=${_AGENT_PANE_IDS[$name]:-}
  done
  AGENT_STATE='' AGENT_DETAIL='' AGENT_PIDS='' AGENT_HOLDERS=()

  sessions=$(contract_json -c --arg p "$path" '[.[] | select(.cwd == $p or (.cwd | startswith($p + "/")))]' \
    <<<"$AGENTS_JSON")
  count=$(contract_json 'length' <<<"$sessions")
  AGENT_PIDS=$(contract_json -r '[.[].pid] | map(tostring) | join(" ")' <<<"$sessions")

  while IFS=$'\t' read -r entry target; do
    [[ -n $entry ]] || continue
    [[ $target == "$path" || $target == "$path"/* ]] || continue
    pid=${entry#/proc/}
    pid=${pid%%/*}
    # The scan's subshell expands the /proc glob itself, so a scan run from inside the slot lists its own cwd and fds.
    [[ $pid == "$$" || $pid == "$BASHPID" || $pid == "$_AGENT_SCAN_PID" ]] && continue
    [[ $users == *" $pid "* ]] || users+="$pid "
    if _agent_below "$pid" "$panes"; then
      comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
      if [[ $comm == claude && " $AGENT_PIDS " != *" $pid "* ]] && ((count == 0)); then
        AGENT_DETAIL="claude process $pid under the slot has no session in claude agents"
      fi
      continue
    fi
    _agent_pane_daemon "$pid" "$ids" && continue
    outside+=("$pid")
  done <<<"$_AGENT_UNDER"

  if ((AGENTS_OK == 0)); then
    AGENT_DETAIL="claude agents --json failed"
  elif ((count > 1)); then
    AGENT_DETAIL="$count Claude sessions run under the slot"
  elif ((${#outside[@]} > 0)); then
    mapfile -t AGENT_HOLDERS < <(for pid in "${outside[@]}"; do _agent_holder "$pid" "$users"; done | sort -un \
      | while read -r pid; do _agent_described "$pid"; done)
    for holder in "${AGENT_HOLDERS[@]}"; do
      [[ $holder != *" "* ]] || holder="${holder%% *} (${holder#* })"
      held+="${held:+, }$holder"
    done
    AGENT_DETAIL="processes outside the slot's tmux panes use the slot: $held"
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
