#!/usr/bin/env bash
# PreToolUse Bash hook: deny a command that deletes files for good, so they go
# to the trash instead, where they can be restored. The settings.json deny rules
# Bash(rm:*) and Bash(git rm:*) match the commands a call's line runs; a script
# that line hands to ssh or to another shell is one quoted word to them.
#
# Denied wherever the shell would run it as a command:
#   - rm, also written \rm or /bin/rm, or run through command, xargs, fd -x, or
#     a wrapper (sudo, env, timeout, gtimeout, nice, nohup, exec, time, gtime)
#   - git rm
#   - find or gfind with -delete, or with -exec, -execdir, -ok or -okdir
#     running rm
# Read as commands too: the script of bash -c, sh -c, zsh -c and dash -c, the
# remote command of ssh, the arguments of eval, a trap's command, and the body
# of a $( ) or backtick substitution, quoted or not.
# Passed: trash, and text that only names rm: a quoted string, a search
# pattern, a heredoc body, a comment, a commit or PR body.
#
# Where the tokenizer loses track of the quoting, because a quote, a
# substitution, a ${...}, a (( )) or an array literal runs to the end of the
# text, or a heredoc's delimiter never comes, the rest of that text is searched
# as written for rm or git rm at the start of a command, and a hit is denied.
# A false deny costs the caller one rewrite to trash; a false pass is the
# failure the guard is here to stop.
#
# The guard catches a habit, not a caller working around it, so these known
# forms pass: a script a shell reads from a file or stdin (`bash x.sh`,
# `bash <<EOF`, `... | sh`), a name the shell builds as it runs (`$RM`,
# `r''m`), `function f { rm x; }`, a $( ) inside ${...} or $(( )), a case
# statement inside a $( ), `((cd x && rm y))` that bash runs as two subshells,
# coproc, flock, setsid, sg, env -S, noglob, busybox, ssh -o RemoteCommand, and
# a git option that takes a value, such as --attr-source, before rm.
#
# The tokenizer is pr-draft-guard.sh's, carried here so this guard deploys as
# one file. It differs in these ways:
#   - a $( ) or backtick body, quoted or not, comes out as an X token to scan,
#     and a quoted `)` inside it does not end it; there a \" does not end a
#     string, and a quote with no partner is a literal
#   - a value keeps its newlines and tabs as \002 and \003, since a script word
#     needs them to split its commands
#   - a $'...' string is one quoted word with its \n and \t escapes read, and
#     $"..." is a double-quoted one
#   - (( )) is arithmetic and skipped, and an array literal stays inside its
#     assignment word, with the substitutions in it scanned
#   - a heredoc delimiter may be quoted in part or with a backslash, and only
#     <<- strips the tabs before the closing delimiter
#   - the command is read as one record, since joining it line by line takes
#     seconds on a command of a megabyte
#
# A deny names the reason (permanent-delete), each deletion, and a next_step:
# use-trash, with the command rebuilt with trash in place of each deletion when
# it can be, or ask-user for a git rm --cached or --dry-run, which deletes
# nothing on disk but is denied like every git rm.
#
# Protocol: exit 0 + JSON deny on stdout to block. Exit 0 + no output to allow.
# Exit 2 + JSON deny when the call cannot be checked: no JSON parser on PATH,
# or a failure inside this script.
set -Eeuo pipefail

readonly GUARD=rm-guard

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

readonly REASON=permanent-delete
# shellcheck disable=SC2088  # shown to the agent as a path, never expanded
readonly DOCS='~/.claude/CLAUDE.md § "CLI tools"'
# ssh's short options that take a value.
readonly SSH_VALUE=BbcDEeFIiJLlmOoPpQRSWw

INPUT=$(cat)

# Fast path: a deletion needs the word rm, or find's -delete, in the payload. In
# the JSON a newline or tab before the word is the two characters \n or \t.
case $INPUT in
  *[![:alnum:]_.-]rm[![:alnum:]_.-]* | *\\[nt]rm[![:alnum:]_.-]*) ;;
  *[![:alnum:]_.-]-delete[![:alnum:]_.-]* | *\\[nt]-delete[![:alnum:]_.-]*) ;;
  *) exit 0 ;;
esac
JQ=$(command -v jaq || command -v jq) \
  || block 'blocked [json-parser-missing]: neither jaq nor jq is on PATH, so this call could not be checked. It did not run; install jaq, then rerun it.\ndocs: ~/dotfiles/BOOTSTRAP.md § \"Install Packages from Brewfile\"\nnext_step [install-jaq]:\nbrew install jaq' \
    'blocked the call: neither jaq nor jq is installed (brew install jaq)'

CMD=$("$JQ" -r '.tool_input.command // ""' <<<"$INPUT")
# The \n or \t before the word can also be an escape inside a $'...' script.
[[ $CMD =~ (^|[^[:alnum:]_.-]|\\[nt])(rm|-delete)([^[:alnum:]_.-]|$) ]] || exit 0

# One token per line: kind, start, end (0-based, exclusive), value. Kinds: W word
# (value with quotes removed), R redirection with its target, P pipe, L list
# operator, O group or process substitution opener, C closer, X the body of a
# $( ) or backtick substitution. A word holding a substitution or an array
# literal gets \001 in its value, since its expansion is unknown here.
# shellcheck disable=SC2016  # awk program; $0 and friends are awk's
TOKENIZE='
function emit(k, st, en, v) { gsub(/\n/, "\002", v); gsub(/\t/, "\003", v); printf "%s\t%d\t%d\t%s\n", k, st - 1, en - 1, v }
function word() { if (!have) { have = 1; wstart = i } }
function flush() {
  if (have) { if (rpend) { emit("R", rstart, i, ""); rpend = 0 } else emit("W", wstart, i, val) }
  have = 0; val = ""
}
function op(k, st, en, v) { flush(); if (rpend) { emit("R", rstart, ropend, ""); rpend = 0 } emit(k, st, en, v) }
function lost(at) { if (!lostat || at < lostat) lostat = at }
function parens(   st, d, ch) {
  st = i
  for (d = 0; i <= n; i++) { ch = substr(s, i, 1); if (ch == "(") d++; if (ch == ")" && --d == 0) return }
  lost(st)
}
# An array literal holds words, so only the substitutions in it run.
function array_literal(   st, d, ch, j) {
  st = i
  for (d = 0; i <= n; i++) {
    ch = substr(s, i, 1)
    if (ch == "\\") { i++; continue }
    if (ch == "\047" && (j = close_quote(i, ch))) { i = j; continue }
    if (ch == "`" || (ch == "$" && substr(s, i + 1, 1) == "(" && substr(s, i + 2, 1) != "(")) { body(ch); continue }
    if (ch == "(") d++
    if (ch == ")" && --d == 0) return
  }
  lost(st)
}
function close_quote(p, q,   ch) {
  for (p++; p <= n; p++) { ch = substr(s, p, 1); if (ch == q) return p; if (ch == "\\" && q == "\"") p++ }
  return 0
}
# A quote with no partner is taken as a literal: an apostrophe in a heredoc or
# comment inside the body is text to bash.
function body(open,   st, j, d, ch) {
  val = val "\001"
  if (open == "`") { st = i + 1; j = index(substr(s, st), "`"); i = j ? st + j - 1 : n + 1 }
  else {
    st = i + 2; d = 1
    for (i = st; i <= n; i++) {
      ch = substr(s, i, 1)
      if (ch == "\\") { i++; continue }
      if ((ch == "\047" || ch == "\"") && (j = close_quote(i, ch))) { i = j; continue }
      if (ch == "(") d++
      if (ch == ")" && --d == 0) break
    }
  }
  if (i > n) lost(st)
  emit("X", st, i, substr(s, st, i - st))
}
# Splits s from p at every character that can end or open a command, and emits
# a Z token for each piece that starts with rm or git rm.
function raw_scan(p,   m, k, F, seg, st) {
  m = split(substr(s, p), F, /[;&|({!`\n]/)
  for (k = 1; k <= m; k++) {
    if (F[k] ~ /^[ \t]*(\\|[^ \t<>]*\/)?(rm|git[ \t]+rm)([ \t]|$)/) {
      st = p + match(F[k], /[^ \t]/) - 1
      seg = F[k]; sub(/^[ \t]+/, "", seg); sub(/[ \t]+$/, "", seg)
      emit("Z", st, st + length(seg), seg)
    }
    p += length(F[k]) + 1
  }
}
function heredoc_bodies(   k, m, p, L, line, st, found) {
  st = i + 1
  m = split(substr(s, i + 1), L, "\n"); p = 1
  for (k = 1; k <= nhd; k++) {
    found = 0
    for (; p <= m; p++) {
      i += length(L[p]) + 1; line = L[p]
      if (hs[k]) sub(/^\t+/, "", line)
      if (line == hd[k]) { p++; found = 1; break }
    }
    if (!found) lost(st)
  }
  if (i > n) i = n
  nhd = 0
}
BEGIN { RS = "\001" }
{ s = (NR == 1 ? $0 : s "\001" $0) }
END {
  sub(/\n$/, "", s)
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1); nx = substr(s, i + 1, 1)
    if (c == "\047") { word(); j = index(substr(s, i + 1), "\047"); if (!j) { lost(i); j = n - i + 1 } val = val substr(s, i + 1, j - 1); i += j; continue }
    if (c == "\"") {
      word(); qs = i
      for (i++; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) { i++; val = val substr(s, i, 1); continue }
        if (c == "\"") break
        if (c == "`" || (c == "$" && substr(s, i + 1, 1) == "(" && substr(s, i + 2, 1) != "(")) { body(c); continue }
        val = val c
      }
      if (i > n) lost(qs)
      continue
    }
    if (c == "\\") { if (nx == "\n") { i++; continue } word(); if (i < n) { i++; val = val substr(s, i, 1) } continue }
    if (c == "#" && !have) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
    if (c == " " || c == "\t") { flush(); continue }
    if (c == "\n") { op("L", i, i + 1, "\n"); if (nhd) heredoc_bodies(); continue }
    if (c == ";") { op("L", i, i + 1, ";"); continue }
    if (c == "|") {
      if (nx == "|") op("L", i, i + 2, "||"); else op("P", i, i + (nx == "&" ? 2 : 1), "|")
      if (nx == "|" || nx == "&") i++
      continue
    }
    if (c == "&" && nx == "&") { op("L", i, i + 2, "&&"); i++; continue }
    if (c == "&" && nx == ">") { flush(); rstart = i; i++; if (substr(s, i + 1, 1) == ">") i++; rpend = 1; ropend = i + 1; continue }
    if (c == "&") { op("L", i, i + 1, "&"); continue }
    if (c == "$" && nx == "\047") {
      word(); qs = i
      for (i += 2; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) { i++; c = substr(s, i, 1); val = val (c == "n" ? "\n" : (c == "t" ? "\t" : c)); continue }
        if (c == "\047") break
        val = val c
      }
      if (i > n) lost(qs)
      continue
    }
    if (c == "$" && nx == "\"") continue
    if (c == "$" && nx == "{") { word(); j = index(substr(s, i), "}"); if (!j) { lost(i); j = n - i + 1 } val = val substr(s, i, j); i += j - 1; continue }
    if (c == "$" && nx == "(" && substr(s, i + 2, 1) == "(") { word(); val = val "\001"; parens(); continue }
    if (c == "$" && nx == "(") { word(); body(c); continue }
    if (c == "`") { word(); body(c); continue }
    if (c == "(" && have && val ~ /^[A-Za-z_][A-Za-z0-9_]*[+]?=$/) { val = val "\001"; array_literal(); continue }
    if (c == "(" && nx == "(") { flush(); parens(); continue }
    if (c == "(") { op("O", i, i + 1, "("); continue }
    if (c == ")") { op("C", i, i + 1, ")"); continue }
    if ((c == "<" || c == ">") && nx == "(") { op("O", i, i + 2, "("); i++; continue }
    if (c == "<" || c == ">") {
      if (have && val ~ /^[0-9]+$/) { rstart = wstart; have = 0; val = "" } else { flush(); rstart = i }
      if (c == "<" && nx == "<" && substr(s, i + 2, 1) != "<") {
        strip = substr(s, i + 2, 1) == "-"
        for (i += 2; substr(s, i, 1) ~ /[- \t]/; i++);
        d = ""; q = ""
        for (; i <= n; i++) {
          c = substr(s, i, 1)
          if (q != "") { if (c == q) q = ""; else d = d c; continue }
          if (c == "\047" || c == "\"") { q = c; continue }
          if (c == "\\") { i++; d = d substr(s, i, 1); continue }
          if (c ~ /[ \t\n;&|<>()]/) break
          d = d c
        }
        hd[++nhd] = d; hs[nhd] = strip; i--
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
  if (lostat) raw_scan(lostat)
}'

# The scripts to scan: text, its offset in CMD (-1 when it is not a verbatim
# slice of CMD, so no edit can be placed in it), and where it runs.
QT=("$CMD") QB=(0) QX=("")
# Each deletion: kind (rm, git-rm, find-delete, keep), its words, where it runs.
OK=() OT=() OX=()
# Each edit of CMD that puts trash in place of a deletion: start, end, text.
ES=() EE=() ER=()
UNBUILT=0
# Offsets in CMD of the deletions found as written, so a text and a body inside
# it that both lose track report each one once.
RAW_AT=" "

# Queues text $1, found at offset $2 of the text being scanned, with context $3.
queue() {
  local text=${1//$'\002'/$'\n'} base=-1
  text=${text//$'\003'/$'\t'}
  if ((BASE >= 0 && $2 >= 0)); then base=$((BASE + $2)); fi
  QT+=("$text") QB+=("$base") QX+=("$3")
}

# Queues the words WD[$1..$2] as the script that $3 runs: one word as its value,
# several joined by spaces, as ssh and eval join them.
queue_words() {
  local k t1=${WT[$1]} t2=${WT[$2]} text="" raw at=-1
  for ((k = $1; k <= $2; k++)); do
    if ((k > $1)); then text+=" "; fi
    text+=${WD[k]}
  done
  text=${text//$'\002'/$'\n'} text=${text//$'\003'/$'\t'}
  raw=${TX:S[t1]:E[t2]-S[t1]}
  if [[ $raw == "$text" ]]; then
    at=${S[t1]}
  elif (($1 == $2)) && [[ $raw == "'$text'" || $raw == "\"$text\"" ]]; then
    at=$((S[t1] + 1))
  fi
  queue "$text" "$at" "${CTX:+$CTX, }inside $3"
}

# Splits TX into tokens, queues the substitution bodies in it, and sets CF and
# CL to each simple command's first and last token. A `)` that closes no group
# ends a case pattern, so the words before it are no command.
tokenize() {
  local tokens k st en v t open=0 at_start=1 depth=0
  tokens=$(printf '%s\n' "$TX" | awk "$TOKENIZE")
  K=() S=() E=() V=() CF=() CL=()
  while IFS=$'\t' read -r k st en v; do
    K+=("$k") S+=("$st") E+=("$en") V+=("$v")
  done <<<"$tokens"
  for ((t = 0; t < ${#K[@]}; t++)); do
    k=${K[t]}
    if [[ $k == X ]]; then
      queue "${V[t]}" "${S[t]}" "$CTX"
      continue
    fi
    if [[ $k == Z ]]; then
      raw_hit "$t"
      continue
    fi
    if [[ $k == W && $at_start == 1 && (${V[t]} == "{" || ${V[t]} == "}") ]]; then
      if [[ ${V[t]} == "{" ]]; then k=O; else k=C; fi
    fi
    K[t]=$k
    case $k in
      O) depth=$((depth + 1)) open=0 at_start=1 ;;
      C)
        if ((depth > 0)); then
          depth=$((depth - 1))
        elif ((open)); then
          CF=("${CF[@]:0:${#CF[@]}-1}")
          CL=("${CL[@]:0:${#CF[@]}}")
        fi
        open=0 at_start=1
        ;;
      W | R)
        if ((open == 0)); then
          CF+=("$t")
          open=1
        fi
        CL[${#CF[@]} - 1]=$t
        if [[ $k == W ]]; then at_start=0; fi
        ;;
      *) open=0 at_start=1 ;;
    esac
  done
}

# Sets WD to the word values of command $1 and WT to their token indexes.
words_of() {
  local t
  WD=() WT=()
  for ((t = CF[$1]; t <= CL[$1]; t++)); do
    if [[ ${K[t]} == W ]]; then
      WD+=("${V[t]}")
      WT+=("$t")
    fi
  done
}

# Advances I past the options in WD[I..END): a long name listed in $1, or a
# bundle of short options ending on a letter in $2, takes the next word as its
# value. A -- is passed over and ends the options.
skip_opts() {
  local w rest c
  while ((I < END)); do
    w=${WD[I]}
    case $w in
      --)
        I=$((I + 1))
        return 0
        ;;
      --*=*) ;;
      --?*) if [[ $1 == *" $w "* ]]; then I=$((I + 1)); fi ;;
      -?*)
        rest=${w#-}
        while [[ -n $rest ]]; do
          c=${rest:0:1} rest=${rest:1}
          if [[ -n $2 && $2 == *"$c"* ]]; then
            if [[ -z $rest ]]; then I=$((I + 1)); fi
            break
          fi
        done
        ;;
      *) return 0 ;;
    esac
    I=$((I + 1))
  done
}

# Sets NI to the index of the command that WD[I..END) runs, past assignments,
# reserved words, and wrappers that run the words after them as a command; NI
# is END when it runs none, as for `command -v rm`.
resolve() {
  local w k
  NI=$END
  while ((I < END)); do
    w=${WD[I]}
    I=$((I + 1))
    case ${w##*/} in
      if | then | elif | else | do | while | until | '!' | '{' | builtin) ;;
      nohup) skip_opts '' '' ;;
      command)
        for ((k = I; k < END; k++)); do
          case ${WD[k]} in
            -*[vV]*) return 0 ;;
            -?*) ;;
            *) break ;;
          esac
        done
        skip_opts '' ''
        ;;
      exec) skip_opts '' a ;;
      sudo) skip_opts ' --user --group --prompt --close-from --chdir --role --type --other-user --command-timeout ' ugpCDrRtTU ;;
      env) skip_opts ' --unset --chdir --split-string ' uCS ;;
      timeout | gtimeout)
        skip_opts ' --signal --kill-after ' sk
        I=$((I + 1))
        ;;
      nice) skip_opts ' --adjustment ' n ;;
      time | gtime) skip_opts ' --format --output ' fo ;;
      xargs) skip_opts ' --arg-file --delimiter --max-args --max-procs --max-chars --process-slot-var ' adEIJLnPRSs ;;
      *)
        if [[ ! $w =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
          NI=$((I - 1))
          return 0
        fi
        ;;
    esac
  done
}

# Records a deletion of kind $1 shown as WD[$2..$3), and an edit putting $6 in
# place of WD[$4..$5] when $4 is given and TX is a verbatim slice of CMD.
# Records the rm or git rm that Z token $1 found as written; it is never rebuilt.
raw_hit() {
  local text=${TX:S[$1]:E[$1]-S[$1]} kind=rm
  if ((BASE >= 0)); then
    if [[ $RAW_AT == *" $((BASE + S[$1])) "* ]]; then return 0; fi
    RAW_AT+="$((BASE + S[$1])) "
  fi
  if [[ $text == git* ]]; then kind='git-rm'; fi
  OK+=("$kind") OT+=("$text") OX+=("${CTX:+$CTX, }past where the guard lost track of the quoting")
  UNBUILT=1
}

offend() {
  local from=${WT[$2]} to=${WT[$3 - 1]}
  OK+=("$1") OT+=("${TX:S[from]:E[to]-S[from]}") OX+=("$CTX")
  if [[ $1 == keep ]]; then return 0; fi
  if [[ -n ${4:-} ]] && ((BASE >= 0)); then
    from=${WT[$4]} to=${WT[$5]}
    ES+=($((BASE + S[from]))) EE+=($((BASE + E[to]))) ER+=("$6")
  else
    UNBUILT=1
  fi
}

# Records the rm at WD[$1], whose arguments end before WD[$2].
rm_at() {
  local j last=$1
  for ((j = $1 + 1; j < $2; j++)); do
    case ${WD[j]} in
      -?*) if [[ ${WD[j]} == -- ]]; then break; fi ;;
      *) break ;;
    esac
    last=$j
  done
  offend rm "$1" "$2" "$1" "$last" trash
}

# Records a git rm in the git command at WD[$1..$2). git reads its options
# after the paths too. A git option before rm, such as -C, changes what its
# paths name, so that command is not rebuilt.
git_rm() {
  local i=$(($1 + 1)) j last global=0 keep=0 build=1 paths=0
  while ((i < $2)); do
    case ${WD[i]} in
      -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
    global=1
  done
  if [[ ${WD[i]:-} != rm ]]; then return 0; fi
  last=$i
  for ((j = i + 1; j < $2; j++)); do
    case ${WD[j]} in
      --) break ;;
      --cached | --dry-run) keep=1 ;;
      --pathspec-from-file*) build=0 ;;
      --?*) ;;
      -*n*) keep=1 ;;
      -?*) ;;
      *) paths=1 ;;
    esac
    if ((! paths)); then last=$j; fi
  done
  if ((keep)); then
    offend keep "$1" "$2"
  elif ((build && ! global)); then
    offend git-rm "$1" "$2" "$1" "$last" trash
  else
    offend git-rm "$1" "$2"
  fi
}

# Queues the -c script of the shell at WD[$1..$2).
shell_script() {
  local i=$(($1 + 1)) c=0 w
  while ((i < $2)); do
    w=${WD[i]}
    case $w in
      - | --)
        i=$((i + 1))
        break
        ;;
      --rcfile | --init-file) i=$((i + 1)) ;;
      --*) ;;
      [-+]?*)
        if [[ $w == ?*c* ]]; then c=1; fi
        if [[ $w == *[oO] ]]; then i=$((i + 1)); fi
        ;;
      *) break ;;
    esac
    i=$((i + 1))
  done
  if ((c && i < $2)); then queue_words "$i" "$i" "${WD[$1]##*/} -c"; fi
}

# Queues the remote command of the ssh at WD[$1..$2). ssh reads options on both
# sides of the destination.
remote_command() {
  I=$(($1 + 1)) END=$2
  skip_opts '' "$SSH_VALUE"
  if ((I >= END)); then return 0; fi
  I=$((I + 1))
  skip_opts '' "$SSH_VALUE"
  if ((I < END)); then queue_words "$I" $((END - 1)) ssh; fi
}

# Records the -delete of the find at WD[$1..$2), and checks each command its
# -exec, -execdir, -ok and -okdir run.
find_actions() {
  local i j
  for ((i = $1 + 1; i < $2; i++)); do
    case ${WD[i]} in
      -delete) offend find-delete "$1" "$2" "$i" "$i" '-exec trash {} + -prune' ;;
      -exec | -execdir | -ok | -okdir)
        for ((j = i + 1; j < $2; j++)); do
          if [[ ${WD[j]} == ';' || ${WD[j]} == + ]]; then break; fi
        done
        check $((i + 1)) "$j"
        i=$j
        ;;
    esac
  done
}

# Checks each command the fd at WD[$1..$2) runs with -x, -X, --exec or
# --exec-batch, which take the words up to a `;` or the end.
fd_exec() {
  local i j
  for ((i = $1 + 1; i < $2; i++)); do
    case ${WD[i]} in
      -x | -X | --exec | --exec-batch)
        for ((j = i + 1; j < $2; j++)); do
          if [[ ${WD[j]} == ';' ]]; then break; fi
        done
        check $((i + 1)) "$j"
        i=$j
        ;;
    esac
  done
}

# Queues the command of the trap at WD[$1..$2); an option, an empty command, or
# `-` sets none.
trap_command() {
  local i=$(($1 + 1))
  if [[ ${WD[i]:-} == -- ]]; then i=$((i + 1)); fi
  case ${WD[i]:-} in
    '' | -*) return 0 ;;
  esac
  if ((i < $2)); then queue_words "$i" "$i" trap; fi
}

# Records each deletion that WD[$1..$2) runs, and queues each script it hands on.
check() {
  local at end=$2 from
  I=$1 END=$2
  resolve
  if ((NI >= end)); then return 0; fi
  at=$NI
  case ${WD[at]##*/} in
    rm) rm_at "$at" "$end" ;;
    git) git_rm "$at" "$end" ;;
    bash | sh | zsh | dash) shell_script "$at" "$end" ;;
    ssh) remote_command "$at" "$end" ;;
    eval)
      from=$((at + 1))
      if [[ ${WD[from]:-} == -- ]]; then from=$((from + 1)); fi
      if ((from < end)); then queue_words "$from" $((end - 1)) eval; fi
      ;;
    trap) trap_command "$at" "$end" ;;
    find | gfind) find_actions "$at" "$end" ;;
    fd | fdfind) fd_exec "$at" "$end" ;;
  esac
}

for ((q = 0; q < ${#QT[@]}; q++)); do
  TX=${QT[q]} BASE=${QB[q]} CTX=${QX[q]}
  tokenize
  for ((j = 0; j < ${#CF[@]}; j++)); do
    words_of "$j"
    check 0 ${#WD[@]}
  done
done
((${#OK[@]} > 0)) || exit 0

# A deletion found as written is often found again by the scan of the body it
# sits in, so each text is listed once.
list="" keep=0 git=0 shown=$'\001'
for ((k = 0; k < ${#OK[@]}; k++)); do
  case ${OK[k]} in
    keep) keep=1 ;;
    git-rm) git=1 ;;
  esac
  if [[ $shown == *$'\001'"${OT[k]}"$'\001'* ]]; then continue; fi
  shown+=${OT[k]}$'\001'
  list+=$'\n'"  ${OT[k]}${OX[k]:+ (${OX[k]})}"
done

# Apply the edits right to left, so each one leaves the offsets before it valid.
out=$CMD
for ((n = ${#ES[@]}; n > 0; n--)); do
  top=0
  for ((k = 1; k < n; k++)); do
    if ((ES[k] > ES[top])); then top=$k; fi
  done
  out=${out:0:ES[top]}${ER[top]}${out:EE[top]}
  last=$((n - 1))
  ES[top]=${ES[last]} EE[top]=${EE[last]} ER[top]=${ER[last]}
done

text="$GUARD denied [$REASON]: this command deletes for good, where trash would let the files be restored:$list"
if ((git)); then
  text+=$'\n'"git rm also stages the deletion; after trash, \`git add -- <path>\` stages it."
fi
if ((keep)); then
  text+=$'\n'"next_step [ask-user]: git rm --cached and git rm --dry-run delete nothing on disk, but every git rm is denied here, so ask the user to run the command."
elif ((UNBUILT)); then
  text+=$'\n'"next_step [use-trash]: rerun it with trash in place of each deletion above; the command could not be rebuilt here, so edit it by hand."
else
  text+=$'\n'"next_step [use-trash]: rerun it with trash in place of each deletion:"$'\n'"$out"
fi
text+=$'\n'"docs: $DOCS"

# The text carries the whole command, and Linux caps one argument at 128 KiB,
# so the long values go in as files.
# shellcheck disable=SC2016  # jaq filter syntax; $text and friends are jaq variables
"$JQ" -n --rawfile text <(printf '%s' "$text") --arg reason "$REASON" --rawfile offending <(printf '%s' "${OT[0]}") '
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $text
    },
    systemMessage: "rm-guard denied [\($reason)]: \($offending)"
  }'
