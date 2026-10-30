#!/usr/bin/env bash
# PreToolUse Bash hook: deny a `git commit` whose output is piped when a later
# step in the same command deletes or moves the commit's message file.
#
# In `git commit --file f | tail -2 && trash f` the pipeline exits with tail's
# status, so trash runs even when the commit fails and the message is lost
# (docs/solutions/workflow-issues/chained-gate-and-commit-masks-failing-local-gate.md).
#
# The command is split the way the shell splits it, so quoted text, heredoc
# bodies, and comments never count. A commit is piped when its output reaches a
# `|` or `|&`, directly or through the group or command substitution around it.
# The later step is trash, trash-put, rm, or mv with an operand naming the
# commit's -F/--file path, compared after quote removal, after expanding the
# variables the command assigns literally, and as a glob. `set -o pipefail`
# before the commit, with only `&&` from the pipe to that step, passes: the
# commit's failure then reaches the step. A script inside `bash -c '...'` is one
# quoted word here and is not read.
#
# A deny names the reason (commit-status-masked-by-pipe), the piped commit, and
# a next_step (rerun-unpiped) carrying the command with the pipe removed.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
set -euo pipefail
# Byte offsets from awk index the command in bash substrings; both must count bytes.
export LC_ALL=C

readonly REASON=commit-status-masked-by-pipe
# shellcheck disable=SC2088  # shown to the agent as a path, never expanded
readonly DOCS='~/.claude/guides/git-and-github.md § "Authoring GitHub correspondence"'

INPUT=$(cat)

# Fast path: a denial needs both a commit and a pipe.
case "$INPUT" in *commit*) ;; *) exit 0 ;; esac
case "$INPUT" in *'|'*) ;; *) exit 0 ;; esac
command -v jaq >/dev/null 2>&1 || exit 0

CMD=$(jaq -r '.tool_input.command // ""' <<<"$INPUT")
[[ -n "$CMD" ]] || exit 0
CMD=$(printf '%s\n' "$CMD" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}')

# One token per line: kind, start, end (0-based, exclusive), value. Kinds: W word
# (value with quotes removed), R redirection with its target, P pipe, L list
# operator, O group or substitution opener, C closer. A word glued to a `$(` or
# a backtick gets \001 in its value, since its expansion is unknown here.
# shellcheck disable=SC2016  # awk program; $0 and friends are awk's
TOKENIZE='
function emit(k, st, en, v) { gsub(/[\t\n]/, " ", v); printf "%s\t%d\t%d\t%s\n", k, st - 1, en - 1, v }
function word() { if (!have) { have = 1; wstart = i } }
function flush() {
  if (have) { if (rpend) { emit("R", rstart, i, ""); rpend = 0 } else emit("W", wstart, i, val) }
  have = 0; val = ""
}
function op(k, st, en, v) { flush(); if (rpend) { emit("R", rstart, ropend, ""); rpend = 0 } emit(k, st, en, v) }
function heredoc_bodies(   k, e, line) {
  for (k = 1; k <= nhd; k++)
    while (i < n) {
      e = index(substr(s, i + 1), "\n"); line = e ? substr(s, i + 1, e - 1) : substr(s, i + 1)
      i += e ? e : length(line); sub(/^[ \t]+/, "", line)
      if (line == hd[k] || !e) break
    }
  nhd = 0
}
{ s = (NR == 1 ? $0 : s "\n" $0) }
END {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1); nx = substr(s, i + 1, 1)
    if (c == "\047") { word(); j = index(substr(s, i + 1), "\047"); if (!j) j = n - i + 1; val = val substr(s, i + 1, j - 1); i += j; continue }
    if (c == "\"") {
      word()
      for (i++; i <= n; i++) { c = substr(s, i, 1); if (c == "\\" && i < n) { i++; val = val substr(s, i, 1); continue } if (c == "\"") break; val = val c }
      continue
    }
    if (c == "\\") { word(); if (i < n) { i++; val = val substr(s, i, 1) } continue }
    if (c == "#" && !have) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
    if (c == " " || c == "\t") { flush(); continue }
    if (c == "\n") { op("L", i, i + 1, "\n"); heredoc_bodies(); continue }
    if (c == ";") { op("L", i, i + 1, ";"); continue }
    if (c == "|") {
      if (nx == "|") op("L", i, i + 2, "||"); else op("P", i, i + (nx == "&" ? 2 : 1), "|")
      if (nx == "|" || nx == "&") i++
      continue
    }
    if (c == "&" && nx == "&") { op("L", i, i + 2, "&&"); i++; continue }
    if (c == "&" && nx == ">") { flush(); rstart = i; i++; if (substr(s, i + 1, 1) == ">") i++; rpend = 1; ropend = i + 1; continue }
    if (c == "&") { op("L", i, i + 1, "&"); continue }
    if (c == "$" && nx == "{") { word(); j = index(substr(s, i), "}"); if (!j) j = n - i + 1; val = val substr(s, i, j); i += j - 1; continue }
    if (c == "$" && nx == "(" && substr(s, i + 2, 1) == "(") {
      word(); val = val "\001"
      for (d = 0; i <= n; i++) { c = substr(s, i, 1); if (c == "(") d++; if (c == ")" && --d == 0) break }
      continue
    }
    if (c == "$" && nx == "(") { if (have) val = val "\001"; op("O", i, i + 2, "$("); i++; continue }
    if (c == "`") { word(); val = val "\001"; j = index(substr(s, i + 1), "`"); i += j ? j : n - i; continue }
    if (c == "(") { op("O", i, i + 1, "("); continue }
    if (c == ")") { op("C", i, i + 1, ")"); continue }
    if ((c == "<" || c == ">") && nx == "(") { op("O", i, i + 2, "("); i++; continue }
    if (c == "<" || c == ">") {
      if (have && val ~ /^[0-9]+$/) { rstart = wstart; have = 0; val = "" } else { flush(); rstart = i }
      if (c == "<" && nx == "<" && substr(s, i + 2, 1) != "<") {
        for (i += 2; substr(s, i, 1) ~ /[- \t]/; i++);
        q = substr(s, i, 1); if (q == "\047" || q == "\"") i++; else q = ""
        for (d = ""; i <= n && (c = substr(s, i, 1)) !~ (q != "" ? q : "[ \t\n;&|<>()]"); i++) d = d c
        hd[++nhd] = d; if (q == "") i--
        emit("R", rstart, i + 1, ""); continue
      }
      while (substr(s, i + 1, 1) ~ /[<>|]/) i++
      if (substr(s, i + 1, 1) == "&") {
        i++
        if (match(substr(s, i + 1), /^([0-9]+-?|-)/)) { i += RLENGTH; emit("R", rstart, i + 1, ""); continue }
      }
      rpend = 1; ropend = i + 1; continue
    }
    word(); val = val c
  }
  flush(); if (rpend) emit("R", rstart, ropend, "")
}'

K=() S=() E=() V=()
while IFS=$'\t' read -r k st en v; do
  K+=("$k") S+=("$st") E+=("$en") V+=("$v")
done < <(printf '%s\n' "$CMD" | awk "$TOKENIZE")
T=${#K[@]}

# NK: token kinds with `{` and `}` in command position as O and C. AD: depth
# outside each token, so an opener and its closer share one depth. CF and CL
# hold each simple command's first and last token.
NK=() AD=() CF=() CL=()
depth=0 at_start=1 open=0
for ((t = 0; t < T; t++)); do
  k=${K[t]}
  if [[ $k == W && $at_start == 1 && (${V[t]} == "{" || ${V[t]} == "}") ]]; then
    if [[ ${V[t]} == "{" ]]; then k=O; else k=C; fi
  fi
  [[ $k == C ]] && depth=$((depth - 1))
  NK[t]=$k AD[t]=$depth
  [[ $k == O ]] && depth=$((depth + 1))
  case $k in
    W | R)
      if ((open == 0)); then
        CF+=("$t")
        open=1
      fi
      CL[${#CF[@]} - 1]=$t
      [[ $k == W ]] && at_start=0
      ;;
    *) open=0 at_start=1 ;;
  esac
done
NC=${#CF[@]}
((NC > 0)) || exit 0

# Sets WD to the word values of command $1 and WT to their token indexes.
words_of() {
  local t
  WD=() WT=()
  for ((t = CF[$1]; t <= CL[$1]; t++)); do
    if [[ ${NK[t]} == W ]]; then
      WD+=("${V[t]}")
      WT+=("$t")
    fi
  done
}

# Sets NAME to the command's name and NI to its index in WD, past assignments,
# reserved words, and wrappers that run the next word as the command.
resolve() {
  local i=0 wrapped=0 w
  NAME="" NI=${#WD[@]}
  while ((i < ${#WD[@]})); do
    w=${WD[i]}
    case $w in
      if | then | elif | else | do | while | until | '!' | time | command | builtin | exec | nohup | sudo | env) wrapped=1 ;;
      -*) ((wrapped)) || break ;;
      *)
        [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || break
        ;;
    esac
    i=$((i + 1))
  done
  ((i < ${#WD[@]})) || return 0
  NAME=${WD[i]##*/} NI=$i
}

AN=() AV=()
# Expands $NAME and ${NAME} from the literal assignments in AN/AV; an unknown
# variable stays as $NAME, so two spellings of one variable still compare equal.
expand() {
  local s=$1 out="" rest name val k
  while [[ $s == *'$'* ]]; do
    out+=${s%%\$*}
    rest=${s#*\$}
    if [[ $rest =~ ^\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ || $rest =~ ^([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
      name=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]} val="\$$name"
      for ((k = 0; k < ${#AN[@]}; k++)); do [[ ${AN[k]} == "$name" ]] && val=${AV[k]}; done
      out+=$val
    else
      out+='$'
    fi
    s=$rest
  done
  printf '%s' "$out$s"
}

# Prints the -F/--file path of a `git commit` whose arguments start at WD[$1].
message_file() {
  local i=$1 w rest c out=""
  while ((i < ${#WD[@]})); do
    w=${WD[i]}
    case $w in
      --) break ;;
      --file=*) out=${w#--file=} ;;
      --file)
        out=${WD[i + 1]:-}
        i=$((i + 1))
        ;;
      --message | --template | --author | --date | --reuse-message | --reedit-message | --fixup | --squash | --trailer | --cleanup | --pathspec-from-file) i=$((i + 1)) ;;
      --*) ;;
      -?*)
        rest=${w#-}
        while [[ -n $rest ]]; do
          c=${rest:0:1} rest=${rest:1}
          case $c in
            F)
              if [[ -n $rest ]]; then out=$rest; else
                out=${WD[i + 1]:-}
                i=$((i + 1))
              fi
              break
              ;;
            m | C | c | t)
              [[ -n $rest ]] || i=$((i + 1))
              break
              ;;
            S | u) break ;;
          esac
        done
        ;;
    esac
    i=$((i + 1))
  done
  [[ $out == - ]] || printf '%s' "$out"
}

# Prints the pipe that carries the output of the command ending at token $1:
# its own pipeline's, or that of a group or substitution enclosing it.
piped_at() {
  local t floor=${AD[$1]} ended=0
  for ((t = $1 + 1; t < T; t++)); do
    case ${NK[t]} in
      C) if ((AD[t] < floor)); then floor=${AD[t]} ended=0; fi ;;
      P) if ((AD[t] == floor && ended == 0)); then
        echo "$t"
        return 0
      fi ;;
      L) if ((AD[t] == floor)); then
        ((floor > 0)) || return 1
        ended=1
      fi ;;
    esac
  done
  return 1
}

# Prints the token that ends the pipeline holding pipe $1, or T at the end.
pipe_end() {
  local t
  for ((t = $1 + 1; t < T; t++)); do
    if [[ (${NK[t]} == C && ${AD[t]} -lt ${AD[$1]}) || (${NK[t]} == L && ${AD[t]} -eq ${AD[$1]}) ]]; then break; fi
  done
  echo "$t"
}

names_file() {
  [[ $1 == "$2" ]] && return 0
  [[ $1 != *$'\001'* && $2 != *$'\001'* ]] || return 1
  # shellcheck disable=SC2053  # the operand is a glob, as the shell would expand it
  [[ $2 == $1 ]]
}

# Pass 1: name each command, and keep the literal assignments and the pipefail
# setting in force at each one.
NAMES=() NIS=() PF=()
pipefail=0
for ((j = 0; j < NC; j++)); do
  words_of "$j"
  resolve
  NAMES[j]=$NAME NIS[j]=$NI PF[j]=$pipefail
  if [[ -z $NAME || $NAME == export ]]; then
    for ((i = 0; i < ${#WD[@]}; i++)); do
      if [[ ${WD[i]} =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        name=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
        val=$(expand "$val")
        AN+=("$name") AV+=("$val")
      fi
    done
  elif [[ $NAME == set ]]; then
    for ((i = NI + 1; i < ${#WD[@]}; i++)); do
      [[ ${WD[i + 1]:-} == pipefail ]] || continue
      [[ ${WD[i]} =~ ^-[a-zA-Z]*o$ ]] && pipefail=1
      [[ ${WD[i]} =~ ^\+[a-zA-Z]*o$ ]] && pipefail=0
    done
  fi
done

# Pass 2: find a piped commit and a later step that removes its message file.
found=0
for ((j = 0; j < NC; j++)); do
  [[ ${NAMES[j]} == git ]] || continue
  words_of "$j"
  i=$((NIS[j] + 1))
  while ((i < ${#WD[@]})); do
    case ${WD[i]} in
      -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [[ ${WD[i]:-} == commit ]] || continue
  msg=$(message_file $((i + 1)))
  [[ -n $msg ]] || continue
  msg=$(expand "$msg")
  commit_tok=${WT[NIS[j]]}
  p=$(piped_at "${CL[j]}") || continue
  q=$(pipe_end "$p")
  for ((d = j + 1; d < NC; d++)); do
    ((CF[d] > p)) || continue
    case ${NAMES[d]} in trash | trash-put | rm | mv) ;; *) continue ;; esac
    words_of "$d"
    for ((i = NIS[d] + 1; i < ${#WD[@]}; i++)); do
      names_file "$(expand "${WD[i]}")" "$msg" || continue
      found=1
      break 3
    done
  done
done
((found)) || exit 0

if ((PF[j])); then
  only_and=1
  for ((t = q; t < CF[d]; t++)); do
    if [[ ${NK[t]} == L && ${V[t]} != '&&' ]]; then only_and=0; fi
  done
  ((only_and == 0)) || exit 0
fi

# Rebuild right to left, so each edit leaves the offsets before it valid:
# connectors from the pipeline to the step become &&, the pipe stages go, and so
# does a 2>&1 on the commit that only fed the pipe.
out=$CMD
for ((t = CF[d] - 1; t >= q; t--)); do
  [[ ${NK[t]} == L && ${AD[t]} -le ${AD[p]} ]] || continue
  case ${V[t]} in
    ';') rep=' &&' ;;
    ' ') rep=$' &&\n' ;;
    '||') rep='&&' ;;
    *) continue ;;
  esac
  out=${out:0:S[t]}$rep${out:E[t]}
done
qs=${#CMD}
((q < T)) && qs=${S[q]}
left=${out:0:S[p]} right=${out:qs}
left=${left%"${left##*[![:space:]]}"}
right=${right#"${right%%[![:space:]]*}"}
if [[ -z $right || $right == ')'* ]]; then out=$left$right; else out="$left $right"; fi
for ((t = p - 1; t >= CF[j]; t--)); do
  [[ ${NK[t]} == R && ${CMD:S[t]:E[t]-S[t]} == '2>&1' ]] || continue
  left=${out:0:S[t]}
  out=${left%"${left##*[![:space:]]}"}${out:E[t]}
done

offending=${CMD:S[commit_tok]:qs-S[commit_tok]}
offending=${offending%"${offending##*[![:space:]]}"}
last=pipe
for ((k = 0; k < NC; k++)); do
  if ((CF[k] > p && CF[k] < q)) && [[ -n ${NAMES[k]} ]]; then last=${NAMES[k]}; fi
done
step_tok=${WT[NIS[d]]}
step=${CMD:S[step_tok]:E[CL[d]]-S[step_tok]}

text="piped-commit-guard denied [$REASON]: \`$offending\` exits with the status of \`$last\`, not of git commit, so \`$step\` runs even when the commit fails and the message file is lost.
next_step [rerun-unpiped]: rerun with the commit unpiped, so the step after it waits on the commit's own status:
$out
docs: $DOCS"

# shellcheck disable=SC2016  # jaq filter syntax; $text and friends are jaq variables
jaq -n --arg text "$text" --arg reason "$REASON" --arg offending "$offending" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $text
    },
    systemMessage: "piped-commit-guard denied [\($reason)]: \($offending)"
  }'
