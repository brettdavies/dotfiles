#!/usr/bin/env bash
# Claude hook that holds a slot's `git push` to the paths its brief declared. For the pane's top-level Claude in a slot's
# Claude session (see scripts/agent-slot/lib/hook.sh), which includes the calls of that Claude's subagents:
#   PreToolUse on Bash   when the command is a `git push`, lists the paths the slot's commits change against
#                        origin/<base> (`git diff --name-only --no-renames origin/<base>...HEAD`) and denies the push
#                        when any path
#                        matches none of the record's scope.touches git pathspec globs and no `scope-grant` ledger line
#                        for the slot covers it
#                      It also denies a push from a branch that shares no line of work with another of the slot's local
#                      branches: one session holds one task, and a new task starts a new session through agent-slot
#                      retask. Two branches share a line when one contains the other, when origin/<base> contains the
#                      other, or when one contains the other's pushed tip (origin/<branch>) and that tip holds a commit
#                      origin/<base> lacks, so a stack stays one line after its lower branch is rebased or merged onto a
#                      moved base, until that new tip is pushed; rebasing the upper branch onto it joins them again. A
#                      probe/ branch, and origin's default branch while origin's copy holds all its commits, are no
#                      second task.
# A `git push` named only inside quoted text that a search or print tool holds, such as an `rg` pattern, is no push
# (scope_mask_quotes).
# A record with no scope.touches passes the path check. Grants count from the task's start, so a new task, or a reused
# slot number, starts at none.
# Anywhere else, and on a payload, record, or base it cannot read, it prints nothing, so the call goes ahead. Always
# exits 0; failures go to the agent-slot hooks.log.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

AS_HOME=$(readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")

# A git command that starts a command: after a separator, a newline, an opening brace or parenthesis, a backtick, or the
# quote that opens a `bash -c` script, past any assignments, wrappers (`time`, `timeout -k 30 600`, `env`, `sudo -u me`, `!`, and the
# like), and git's own options. It is a guard, not a trust boundary: a wrapper this does not list runs the command
# unjudged.
GIT_START=$'(^|[;&|({\n`]|(bash|sh|zsh|dash)[[:space:]]+-[a-z]*c[[:space:]]+["\'])[[:space:]]*((!|if|elif|then|do|else|while|until|time|command|exec|nohup|env|nice|sudo)[[:space:]]+'
GIT_START+=$'(-[A-Za-z]+[[:space:]]+[^-[:space:]][^[:space:]]*[[:space:]]+)?'
GIT_START+=$'|timeout[[:space:]]+(-[A-Za-z][^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)?'
GIT_START+=$'|--[a-z-]+(=[^[:space:]]*)?[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)?)*'
GIT_START+=$'[0-9.]+[smhd]?[[:space:]]+'
GIT_START+=$'|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(/[^[:space:]]*/)?git'
GIT_START+=$'([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--(git-dir|work-tree|namespace)[[:space:]]+[^[:space:]]+|--[^[:space:]]+|-[A-Za-z]+))*'
GIT_START+=$'[[:space:]]+'
PUSH_RE=$GIT_START$'push([[:space:]]|$|[;&|)}`"\'])'
# A git command that moves HEAD, so a push after it in the same command carries commits the hook has not seen.
MOVE_RE=$GIT_START$'(commit|merge|rebase|cherry-pick|revert|am|pull|reset|checkout|switch)([[:space:]]|$|[;&|)}`"\'])'
# A push that sends no commits.
PUSH_NOOP_RE='[[:space:]](--dry-run|--delete|-d)([[:space:]=]|$)'

# A quoted string is data only where a tool known to print or search it holds it: the first word of its simple command
# is `rg`, `grep`, `echo`, `printf`, `cat`, a `for` list, or `git commit`. This awk program replaces the separators,
# brackets, backticks, quote marks, and blanks inside such a string with `_`, so the start rules above cannot begin a
# command there. Every other string stays as written, since a shell, `eval`, `ssh`, `trap`, `git -c alias.x=`, or any
# other runner this list does not name may run it. A string inside parentheses or backticks stays as written too,
# since a substitution runs its command whatever starts the line around it. The program hands the command back whole
# at a pipe whose next stage is not a text filter, at a process substitution, which can feed a string to a shell, and
# when the pairing cannot be trusted: a heredoc, a comment, an `$'...'` string, a quote left open, and a
# double-quoted string with `$(`, a backtick, or `${`, from which on nothing is masked because quotes nested in a
# substitution pair up differently.
# shellcheck disable=SC2016 # an awk program
SCOPE_MASK_AWK='
BEGIN {
  SQ = "\047"; DQ = "\""; STRUCT = "[;&|(){}`\047\" \t\n]"
  DATA = "^[ \t{!]*(rg|grep|egrep|fgrep|echo|printf|cat|for|"
  DATA = DATA "git([ \t]+(-[cC][ \t]+[^ \t]+|--[^ \t]+|-[A-Za-z]+))*[ \t]+commit)[ \t]"
  STAGE = "^&?[ \t\n]*(rg|grep|egrep|fgrep|cut|head|tail|wc|sort|uniq|tr|jq|jaq|cat)([ \t\n;&|)]|$)"
}
function mask(s,   n, i, j, c, d, out, cs, inner, depth, bt) {
  n = length(s); out = ""; cs = 1; depth = 0; bt = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") { out = out substr(s, i, 2); i++; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) !~ /[${]/)) return s
    if ((c == "<" || c == ">") && substr(s, i + 1, 1) == "(") return s
    if (c == "<" && substr(s, i + 1, 1) == "<") {
      if (substr(s, i + 2, 1) != "<") return s
      out = out "<<<"; i += 2; continue
    }
    if (c == "|") {
      if (substr(s, i + 1, 1) == "|") {
        out = out "||"; i++
        if (!depth && !bt) cs = length(out) + 1
        continue
      }
      if (substr(s, i + 1) !~ STAGE) return s
    }
    if (c == "$" && substr(s, i + 1, 1) == SQ) return s
    if (c == SQ || c == DQ) {
      for (j = i + 1; j <= n; j++) {
        d = substr(s, j, 1)
        if (d == c) break
        if (d == "\\" && c == DQ) j++
      }
      if (j > n) return s
      inner = substr(s, i + 1, j - i - 1)
      if (c == DQ && inner ~ /\$\(|`|\$\{/) return out substr(s, i)
      if (!depth && !bt && substr(out, cs) ~ DATA) gsub(STRUCT, "_", inner)
      out = out c inner c; i = j; continue
    }
    out = out c
    if (c == "(") depth++
    else if (c == ")" && depth > 0) depth--
    else if (c == "`") bt = !bt
    else if (c ~ /[;&|\n]/ && !depth && !bt) cs = length(out) + 1
  }
  return out
}
{ s = (NR == 1 ? $0 : s "\n" $0) }
END { printf "%s", mask(s) }'

# Usage: scope_mask_quotes <command>; prints the command with its quoted data masked.
scope_mask_quotes() { LC_ALL=C awk "$SCOPE_MASK_AWK" <<<"$1"; }

# Usage: scope_deny_reason <repo> <n> <touches> <paths> <branch> <base>; <touches> is the comma-separated globs, <paths>
# one per line.
scope_deny_reason() {
  printf '%s' "Slot $1/$2 may change only: $3 (\`agent-slot whoami --output json\` shows the recorded scope). The \
commits on $5 against origin/$6 change paths outside that, and no scope grant covers them. The hook judges this \
slot's branch whatever the command pushes:
  ${4//$'\n'/$'\n'  }
Revert that change (\`git restore --source=origin/$6 --staged --worktree -- <path>\`, then commit), or record it \
under \"Not in scope\" in the PR body and send the coordinating session a request for a scope grant, naming the paths, \
as one \`SendMessage\`; the operator grants paths by running \`agent-slot grant-scope $1/$2 <pathspec>\` at a \
terminal, once per pathspec (a glob can cover several of the paths above), which you cannot run yourself. If your brief \
names no such session, leave the decision open in your plan and your report. If these paths come from a branch you \
built on, do not revert them; say so in that message. \
Keep working on what the push does not need."
}

# Usage: scope_bad_glob_reason <repo> <n> <glob>
scope_bad_glob_reason() {
  printf '%s' "Slot $1/$2 records the Touches: glob $3, which is not a git pathspec inside the repo, so the push cannot be \
checked against it. Send the coordinating session the glob as one \`SendMessage\` and ask for a corrected scope. If \
your brief names no such session, leave the decision open in your plan and your report."
}

# Usage: scope_chain_reason <repo> <n> <git subcommand>
scope_chain_reason() {
  printf '%s' "Slot $1/$2 limits its PR to the paths its brief declares, and this command runs \`git $3\` before it \
pushes, so the hook cannot judge the commits it would push. Run \`git $3\` as its own command first, then run \
\`git push\` as its own command."
}

# Usage: scope_command_facts <command>; sets SCOPE_REAL_PUSH to 1 when any git push in the command sends commits (a dry
# run or a branch deletion sends none, judged within its own segment of the line), and SCOPE_MOVER to the git
# subcommand before the first push that changes HEAD, else nothing.
SCOPE_REAL_PUSH=0 SCOPE_MOVER=
scope_command_facts() {
  local rest m seg before first=1 t
  SCOPE_REAL_PUSH=0 SCOPE_MOVER=
  rest=$(scope_mask_quotes "$1") || rest=$1
  while [[ $rest =~ $PUSH_RE ]]; do
    m=${BASH_REMATCH[0]}
    if ((first)); then
      first=0
      before=${rest%%"$m"*}
      if [[ $before =~ $MOVE_RE ]]; then
        t=${BASH_REMATCH[0]}
        t=${t%"${t##*[a-z]}"}
        SCOPE_MOVER=${t##*[[:space:]]}
      fi
    fi
    rest=${rest#*"$m"}
    seg=${rest%%[;&|$'\n']*}
    [[ " $seg" =~ $PUSH_NOOP_RE ]] || SCOPE_REAL_PUSH=1
  done
}

# Usage: scope_deny <reason>; prints the PreToolUse denial.
# shellcheck disable=SC2016 # a jaq program
scope_deny() {
  contract_json -n -c --arg m "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}'
}

# Usage: branch_decide <repo> <n>; RECORD holds the slot's record. Prints the denial, or nothing.
branch_decide() {
  local path base head other default pair tip rc
  path=$(slot_path "$1" "$2")
  base=$(contract_json -r '.base // empty' <<<"$RECORD")
  head=$(git -C "$path" symbolic-ref --short -q HEAD) || return 0
  [[ -n $base && $head != "$base" && $head != probe/* ]] || return 0
  # `git clone` leaves a local branch for origin's default, which holds no task while origin's copy has all its commits.
  default=$(git -C "$path" symbolic-ref -q refs/remotes/origin/HEAD) || default=
  default=${default#refs/remotes/origin/}
  while IFS= read -r other; do
    [[ $other != "$head" && $other != "$base" && $other != probe/* ]] || continue
    if [[ $other == "$default" ]]; then
      git -C "$path" merge-base --is-ancestor "$other" "origin/$default" 2>/dev/null && continue
    fi
    git -C "$path" merge-base --is-ancestor "$other" HEAD 2>/dev/null && continue
    git -C "$path" merge-base --is-ancestor HEAD "$other" 2>/dev/null && continue
    git -C "$path" merge-base --is-ancestor "$other" "origin/$base" 2>/dev/null && continue
    # A stack stays one line of work after its lower branch is rebased or merged onto a moved base: the upper branch still
    # holds the lower one's pushed tip. A tip the base already holds is in every branch cut from it, so it counts only
    # with a commit the base lacks. A missing ref or base is no ancestry, so nothing is skipped.
    for pair in "$other:HEAD" "$head:$other"; do
      tip=refs/remotes/origin/${pair%%:*}
      git -C "$path" rev-parse --verify -q "$tip" >/dev/null || continue
      rc=0
      git -C "$path" merge-base --is-ancestor "$tip" "refs/remotes/origin/$base" 2>/dev/null || rc=$?
      ((rc == 1)) || continue
      git -C "$path" merge-base --is-ancestor "$tip" "${pair#*:}" 2>/dev/null && continue 2
    done
    scope_deny "This push is from $head, but this slot's task is on $other, and they share no line of work. One session \
holds one task, so stop here and ask the session you report to to run \`agent-slot retask $1/$2 --task <name> \
--prompt-file <brief>\`, which starts the new task in a new session. If this is the same task, stack it on $other. A \
probe's branch goes under probe/."
    return 0
  done < <(git -C "$path" for-each-ref --format='%(refname:short)' refs/heads)
}

# Usage: scope_decide <repo> <n> <mover>; RECORD holds the slot's record. Prints the denial, or nothing. <mover> is the
# git subcommand that changes HEAD before the push, if any.
scope_decide() {
  local repo=$1 n=$2 mover=$3 path base since touches changed matched outside spec
  local -a specs=() grants=()
  contract_json -e '.scope.touches | type == "array"' <<<"$RECORD" >/dev/null || return 0
  [[ -z $mover ]] || {
    scope_deny "$(scope_chain_reason "$repo" "$n" "$mover")"
    return 0
  }
  path=$(slot_path "$repo" "$n")
  base=$(contract_json -r '.base // empty' <<<"$RECORD")
  since=$(contract_json -r '.task_started_at // .created_at // ""' <<<"$RECORD")
  [[ -n $base ]] || {
    hook_log "slot $repo/$n has no base in its record; push allowed"
    return 0
  }
  mapfile -t specs < <(contract_json -r '.scope.touches[]' <<<"$RECORD")
  # shellcheck disable=SC2016 # a jaq program
  touches=$(contract_json -r '.scope.touches | map("`\(.)`") | join(", ")' <<<"$RECORD")
  while IFS= read -r spec; do
    [[ -z $spec ]] || grants+=("$spec")
  done < <(scope_grants "$repo" "$n" "$since" || true)
  changed=$(git -C "$path" -c core.quotePath=false diff --name-only --no-renames "origin/$base...HEAD" 2>/dev/null \
    | sort -u) || {
    hook_log "slot $repo/$n: git diff origin/$base...HEAD failed; push allowed"
    return 0
  }
  for spec in "${specs[@]}"; do
    git -C "$path" ls-files -- "$spec" >/dev/null 2>&1 || {
      scope_deny "$(scope_bad_glob_reason "$repo" "$n" "$spec")"
      return 0
    }
  done
  for spec in "${grants[@]}"; do
    if git -C "$path" ls-files -- "$spec" >/dev/null 2>&1; then
      specs+=("$spec")
    else
      hook_log "slot $repo/$n: scope-grant pathspec $spec is not a git pathspec; skipped"
    fi
  done
  matched=
  if ((${#specs[@]} > 0)); then
    matched=$(git -C "$path" -c core.quotePath=false diff --name-only --no-renames "origin/$base...HEAD" -- \
      "${specs[@]}" 2>/dev/null | sort -u) || {
      hook_log "slot $repo/$n: git diff against the scope globs failed; push allowed"
      return 0
    }
  fi
  outside=$(comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$matched") | sed '/^$/d')
  [[ -n $outside ]] || return 0
  scope_deny "$(scope_deny_reason "$repo" "$n" "$touches" "$outside" "$(slot_review_key "$path")" "$base")"
}

scope_main() {
  local fields event tool command repo n
  hook_use_socket "${TMUX%%,*}" || return 0
  fields='"\(.hook_event_name // "")\u001f\(.tool_name // "")\u001f\(.tool_input.command // "" | gsub("\u001f"; " "))"'
  IFS=$'\x1f' read -r -d '' event tool command <<<"$(hook_field "$fields")" || true
  [[ $event == PreToolUse && $tool == Bash ]] || return 0
  scope_command_facts "$command"
  ((SCOPE_REAL_PUSH)) || return 0
  hook_pane && hook_claude_session && hook_top_level_claude || return 0
  read -r repo n <<<"$(hook_slot)"
  record_read "$repo" "$n" || {
    hook_log "slot $repo/$n has no readable record; push allowed"
    return 0
  }
  # A command that moves HEAD before it pushes pushes from a branch the hook cannot see yet; scope_decide refuses the chain.
  local denied=
  [[ -n $SCOPE_MOVER ]] || denied=$(branch_decide "$repo" "$n")
  if [[ -n $denied ]]; then
    printf '%s\n' "$denied"
    return 0
  fi
  scope_decide "$repo" "$n" "$SCOPE_MOVER"
}

HOOK_PAYLOAD_IN=$(cat)
[[ $HOOK_PAYLOAD_IN == *push* && -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0
(
  set -euo pipefail
  shopt -s inherit_errexit
  exec 2>/dev/null
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/hook.sh"
  hook_init slot-scope-guard "$AS_HOME"
  # shellcheck disable=SC2034 # read by hook.sh
  HOOK_PAYLOAD=$HOOK_PAYLOAD_IN
  out=$(scope_main)
  [[ -z $out ]] || printf '%s\n' "$out"
) </dev/null
exit 0
