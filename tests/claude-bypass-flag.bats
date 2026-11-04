#!/usr/bin/env bats
# Every session, prime and slot, starts Claude with --dangerously-skip-permissions. This sweep reads what the repo ships
# for a shell line that starts an interactive Claude without the flag, so a new way of starting one cannot arrive bare.
#
# Three kinds of start stay out of it on purpose. `claude -p` is a headless job bounded by its own --allowedTools, which
# the flag would widen. A subcommand such as `claude agents` starts no session. trust.sh runs "$AS_CLAUDE", a path it
# resolved rather than this literal word, on a private tmux socket, only to answer the trust dialog before it kills it.
#
# Run: bats tests/claude-bypass-flag.bats
# run-tests: parallel

REPO="$BATS_TEST_DIRNAME/.."
FLAG=--dangerously-skip-permissions

# What precedes `claude` when a line runs it: the line's start, a shell separator, exec, timeout, or a tmux send-keys.
START='(^|&&|\|\||;|\bexec|\bthen|\bdo|timeout +[^ ]+|send-keys .*)[ "'"'"']*claude( |"|'"'"'|$)'
# Past the subcommands, a case label reads as `claude | files | git)`.
NOT_A_SESSION='claude +(-p|--print|agents|model|mcp|plugin|config|doctor|update|install|--version|--help|\|)( |"|$)'

# bare_starts PATH...: prints each line under the paths that starts Claude without the flag, skipping comments and the
# pinned version list, whose lines are `<tool> <version>`.
bare_starts() {
  grep -rnHIE --exclude='*.md' --exclude='*.json' --exclude='*.tsv' --exclude=verified-versions "$START" "$@" |
    grep -vE '^[^:]+:[0-9]+: *#' |
    grep -vE "$NOT_A_SESSION" |
    grep -vF -- "$FLAG" || true
}

@test "the sweep catches each shape of a bare start and passes each exempt or flagged line" {
  local dir=$BATS_TEST_TMPDIR/planted
  mkdir -p "$dir"
  cat >"$dir/bad.sh" <<'EOF'
cd /x && claude
exec claude --resume id
timeout 5 claude
tmux send-keys -t x "claude" C-m
claude -n meum-api-prime
EOF
  cat >"$dir/good.sh" <<'EOF'
# cd /x && claude
claude agents --json
exec timeout 5 claude -p "$PROMPT"
SESSION_KINDS=(claude files git)
cd /x && claude --dangerously-skip-permissions
echo "claude agents --json failed"
  claude | files | git) ;;
EOF
  run bare_starts "$dir/bad.sh"
  [ "${#lines[@]}" -eq 5 ]
  run bare_starts "$dir/good.sh"
  [ -z "$output" ]
}

# agent-slot-rex's prime command and the start-up re-attach attach a tmux client and start no Claude, so a bare start
# reaching them shows up here.
@test "nothing the repo ships starts or tells anyone to start Claude without the flag" {
  run bare_starts "$REPO/scripts" "$REPO/stow" "$REPO/config" "$REPO/.githooks"
  [ -z "$output" ] || { printf 'bare start: %s\n' "${lines[@]}"; false; }
}

@test "a slot's Claude takes the flag from the one constant every session command is built on" {
  run grep -c "^SESSIONS_CLAUDE='claude $FLAG'$" "$REPO/scripts/agent-slot/lib/sessions.sh"
  [ "$output" = 1 ]
}
