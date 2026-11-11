#!/usr/bin/env bash
# PreToolUse Bash hook: deny a command that opens a pull request ready for
# review. A PR a session opens starts as a draft, and `gh pr ready` ends the
# draft once every review the PR needs is done.
#
# Denied:
#   - gh pr create (alias gh pr new) whose last --draft/-d is absent or false
#   - gh stack submit without --auto, or with --open: its interactive editor
#     creates PRs ready, --auto creates them as drafts, and --open marks new
#     and existing PRs ready
# Passed: every other command, any of these with -h/--help, and text that only
# names them (a quoted string, a heredoc body, a comment, a commit message).
# Only the typed command is read: a script that runs gh itself, a script inside
# `bash -c '...'`, and a `$( )` inside double quotes are each one word here.
#
# The command is split the way the shell splits it, and gh's flags are read the
# way its flag parser reads them: the last occurrence of a flag wins, a bundle
# such as -dt runs to its first flag that takes a value, and -- ends the flags.
#
# A deny names the reason (pr-not-draft, stack-submit-not-draft), and a
# next_step carrying the whole command rebuilt with the PR opened as a draft: a
# denied call ran none of its steps, so the rerun repeats all of them.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
# Exit 2 + JSON deny when the call cannot be checked: no JSON parser on PATH,
# or a failure inside this script.
set -euo pipefail

readonly GUARD=pr-draft-guard

# The deny is built from text already escaped for JSON, the guard's name, and a
# line number, so it needs no parser. Exit 2 blocks the call even where the
# harness does not read the JSON.
block() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s %s"},"systemMessage":"%s %s"}\n' \
    "$GUARD" "$1" "$GUARD" "$2"
  exit 2
}
trap 'block "failed [guard-internal-error] at line $LINENO, so this call did not run.\nnext_step [ask-user]: tell the user; bats tests/$GUARD.bats in the dotfiles repo shows what broke." "failed at line $LINENO and blocked the call"' ERR

# Byte offsets from awk index the command in bash substrings; both must count bytes.
export LC_ALL=C

# shellcheck disable=SC2088  # shown to the agent as a path, never expanded
readonly DOCS='~/.claude/guides/git-and-github.md § "Typical flow (PR body)"'

# Flags of each command that take a value, which the flag scan must not read as
# flags: long names between spaces, short letters in one string.
readonly PR_VALUE_LONG=' --assignee --attach --base --body --body-file --head --label --milestone --project --recover --reviewer --template --title --repo '
readonly PR_VALUE_SHORT=aBbFHlmprTtR
readonly STACK_VALUE_LONG=' --remote --repo '
readonly STACK_VALUE_SHORT=R

INPUT=$(cat)

# Fast path: every command this guard judges runs gh.
case "$INPUT" in *gh*) ;; *) exit 0 ;; esac
JQ=$(command -v jaq || command -v jq) \
  || block 'blocked [json-parser-missing]: neither jaq nor jq is on PATH, so this call could not be checked. It did not run; install jaq, then rerun it.\ndocs: ~/dotfiles/BOOTSTRAP.md § \"Install Packages from Brewfile\"\nnext_step [install-jaq]:\nbrew install jaq' \
    'blocked the call: neither jaq nor jq is installed (brew install jaq)'

CMD=$("$JQ" -r '.tool_input.command // ""' <<<"$INPUT")
[[ -n "$CMD" ]] || exit 0
# Every denied subcommand has one of these words in it.
case "$CMD" in *create* | *new* | *submit*) ;; *) exit 0 ;; esac
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

TOKENS=$(printf '%s\n' "$CMD" | awk "$TOKENIZE")
K=() S=() E=() V=()
while IFS=$'\t' read -r k st en v; do
  K+=("$k") S+=("$st") E+=("$en") V+=("$v")
done <<<"$TOKENS"
T=${#K[@]}

# NK: token kinds with `{` and `}` in command position as O and C. CF and CL
# hold each simple command's first and last token.
NK=() CF=() CL=()
open=0 at_start=1
for ((t = 0; t < T; t++)); do
  k=${K[t]}
  if [[ $k == W && $at_start == 1 && (${V[t]} == "{" || ${V[t]} == "}") ]]; then
    if [[ ${V[t]} == "{" ]]; then k=O; else k=C; fi
  fi
  NK[t]=$k
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

# Sets OPA and OPB to the first two words of gh's arguments that are not flags,
# and OP1 and OP2 to their indexes in WD (-1 when absent). The argument after
# -R or --repo is that flag's value.
read_ops() {
  local i
  OPA="" OPB="" OP1=-1 OP2=-1
  for ((i = $1 + 1; i < ${#WD[@]} && OP2 < 0; i++)); do
    case ${WD[i]} in
      -R | --repo) i=$((i + 1)) ;;
      -*) ;;
      *)
        if ((OP1 < 0)); then OPA=${WD[i]} OP1=$i; else OPB=${WD[i]} OP2=$i; fi
        ;;
    esac
  done
}

is_true() {
  case $1 in 1 | t | T | TRUE | true | True) return 0 ;; esac
  return 1
}

# Records the value that flag $1 takes in WD[$3]: $2, parsed as a boolean. A
# word that sets a flag against the draft is queued in DEL, since a rebuilt
# command keeps it and the last occurrence wins.
note_flag() {
  local on=0 i=$3
  if is_true "$2"; then on=1; fi
  case $1 in
    --help) HELP=1 ;;
    --draft)
      DRAFT=$on WORD_DRAFT=${WD[i]}
      if ((on == 0)) && [[ $MODE == pr ]]; then
        case ${WD[i]%%=*} in --draft | -d) DEL+=("$i") ;; esac
      fi
      ;;
    --auto)
      AUTO=$on
      if ((on == 0)) && [[ $MODE == stack ]]; then DEL+=("$i"); fi
      ;;
    --open)
      OPEN=$on WORD_OPEN=${WD[i]}
      if ((on == 1)) && [[ $MODE == stack ]]; then DEL+=("$i"); fi
      ;;
  esac
}

# Reads the flags of the gh command in WD with the value-taking flags $1 (long)
# and $2 (short), leaving HELP, DRAFT, AUTO, and OPEN as the last occurrence of
# each sets them.
scan_flags() {
  local value_long=$1 value_short=$2 i w rest c v
  HELP=0 DRAFT=0 AUTO=0 OPEN=0 WORD_DRAFT="" WORD_OPEN="" DEL=()
  for ((i = NI + 1; i < ${#WD[@]}; i++)); do
    w=${WD[i]}
    case $w in
      --) break ;;
      --?*=*) note_flag "${w%%=*}" "${w#*=}" "$i" ;;
      --?*)
        if [[ $value_long == *" $w "* ]]; then i=$((i + 1)); else note_flag "$w" true "$i"; fi
        ;;
      -?*)
        rest=${w#-}
        while [[ -n $rest ]]; do
          c=${rest:0:1} rest=${rest:1}
          if [[ $value_short == *"$c"* ]]; then
            if [[ -z $rest ]]; then i=$((i + 1)); fi
            break
          fi
          v=true
          if [[ $rest == =* ]]; then v=${rest#=} rest=; fi
          case $c in
            d) note_flag --draft "$v" "$i" ;;
            h) HELP=1 ;;
          esac
        done
        ;;
    esac
  done
}

queue_insert() {
  local t=${WT[OP2]}
  QS+=("${E[t]}") QE+=("${E[t]}") QR+=("$1")
}

# Queues the removal of WD[$1], with the space before it.
queue_delete() {
  local t=${WT[$1]} s=${S[${WT[$1]}]}
  if ((s > 0)) && [[ ${CMD:s-1:1} == " " ]]; then s=$((s - 1)); fi
  QS+=("$s") QE+=("${E[t]}") QR+=("")
}

# Sets QS, QE, and QR to the edits, in command order, that insert $1 after the
# second subcommand word and remove the words in DEL.
build_edits() {
  local ins=$1 d done_ins=0
  QS=() QE=() QR=()
  [[ -n $ins ]] || done_ins=1
  for ((d = 0; d < ${#DEL[@]}; d++)); do
    if ((done_ins == 0 && DEL[d] > OP2)); then
      queue_insert "$ins"
      done_ins=1
    fi
    queue_delete "${DEL[d]}"
  done
  if ((done_ins == 0)); then queue_insert "$ins"; fi
}

GS=() GE=() GR=()
CODE="" WHAT=""
for ((j = 0; j < NC; j++)); do
  words_of "$j"
  resolve
  [[ $NAME == gh ]] || continue
  read_ops "$NI"
  case "$OPA $OPB" in
    'pr create' | 'pr new') MODE="pr" ;;
    'stack submit') MODE="stack" ;;
    *) continue ;;
  esac
  if [[ $MODE == pr ]]; then
    scan_flags "$PR_VALUE_LONG" "$PR_VALUE_SHORT"
  else
    scan_flags "$STACK_VALUE_LONG" "$STACK_VALUE_SHORT"
  fi
  ((HELP == 0)) || continue

  if [[ $MODE == pr ]]; then
    ((DRAFT == 0)) || continue
    code=pr-not-draft ins=" --draft"
    if [[ -n $WORD_DRAFT ]]; then
      what="\`gh pr $OPB $WORD_DRAFT\` opens the PR ready for review"
    else
      what="\`gh pr $OPB\` without --draft opens the PR ready for review"
    fi
  else
    ((AUTO == 0 || OPEN == 1)) || continue
    code=stack-submit-not-draft ins=""
    if ((AUTO == 0)); then ins=" --auto"; fi
    if ((OPEN == 1)); then
      what="\`gh stack submit $WORD_OPEN\` marks new and existing PRs ready for review"
    else
      what="\`gh stack submit\` without --auto opens an editor that creates PRs ready for review"
    fi
  fi

  build_edits "$ins"
  GS+=("${QS[@]}") GE+=("${QE[@]}") GR+=("${QR[@]}")
  [[ -n $CODE ]] || CODE=$code
  WHAT="${WHAT:+$WHAT; }$what"
done
[[ -n $CODE ]] || exit 0

# Apply the edits right to left, so each leaves the offsets before it valid.
out=$CMD
for ((e = ${#GS[@]} - 1; e >= 0; e--)); do
  out=${out:0:GS[e]}${GR[e]}${out:GE[e]}
done

text="pr-draft-guard denied [$CODE]: $WHAT. A pull request a session opens starts as a draft and stays one until every review it needs is done and its fixes are in.
next_step [rerun-as-draft]: rerun with every PR opened as a draft:
$out
Then, once every review the PR needs is done, its fixes are in, and each verdict is in a PR comment, mark it ready:
gh pr ready <number>
docs: $DOCS"

# shellcheck disable=SC2016  # jaq filter syntax; $text and friends are jaq variables
"$JQ" -n --arg text "$text" --arg code "$CODE" --arg what "$WHAT" '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $text
    },
    systemMessage: "pr-draft-guard denied [\($code)]: \($what)"
  }'
