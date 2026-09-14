#!/usr/bin/env bats
# Tests for stow/local/dot-local/bin/gstack-config-apply
#
# Run: bats tests/gstack-config-apply.bats

SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/gstack-config-apply"
REAL_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/gstack/bin/gstack-config"
REAL_EGRESS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/gstack/bin/gstack-egress"

bats_require_minimum_version 1.5.0

# A fake Claude config dir holding a stub gstack-config that keeps key=value
# state in a file and records every `set` it receives.
setup() {
  FAKE="$(mktemp -d)"
  STATE="$FAKE/state"
  SETLOG="$FAKE/set.log"
  : >"$STATE"
  mkdir -p "$FAKE/skills/gstack/bin"
  cat >"$FAKE/skills/gstack/bin/gstack-config" <<EOF
#!/usr/bin/env bash
case "\$1" in
  get) grep -E "^\$2=" "$STATE" | tail -1 | cut -d= -f2- ;;
  set) printf '%s=%s\n' "\$2" "\$3" >>"$STATE"; printf 'set %s %s\n' "\$2" "\$3" >>"$SETLOG" ;;
esac
EOF
  chmod +x "$FAKE/skills/gstack/bin/gstack-config"
}

teardown() {
  rm -rf "$FAKE"
}

managed() { "$SCRIPT" --list; }

seed_all() {
  managed | while read -r k v; do printf '%s=%s\n' "$k" "$v" >>"$STATE"; done
}

apply() { run env CLAUDE_CONFIG_DIR="$FAKE" "$SCRIPT" "$@"; }

@test "gstack-config-apply passes shellcheck" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run "$BATS_TEST_DIRNAME/../scripts/lint-shell" stow/local/dot-local/bin/gstack-config-apply
  [ "$status" -eq 0 ]
}

@test "--list prints the managed table, one key and value per line" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run bash -c 'grep -vcE "^[a-z_]+ [a-z_]+$"' <<<"$output"
  [ "$output" = "0" ]
}

@test "an unknown flag is a usage error" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "exits 0 with no output when gstack is not installed" {
  run env CLAUDE_CONFIG_DIR="$FAKE/nowhere" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sets every managed key on a blank config" {
  apply
  [ "$status" -eq 0 ]
  managed | while read -r k v; do
    grep -qxF "set $k $v" "$SETLOG"
  done
  [ "$(wc -l <"$SETLOG" | tr -d ' ')" = "$(managed | wc -l | tr -d ' ')" ]
}

@test "writes nothing when every key already matches" {
  seed_all
  apply
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$SETLOG" ]
}

@test "writes only the keys that drifted" {
  seed_all
  printf 'telemetry=community\n' >>"$STATE"
  apply
  [ "$status" -eq 0 ]
  [ "$output" = "telemetry: community -> off" ]
  [ "$(cat "$SETLOG")" = "set telemetry off" ]
}

@test "--check reports drift without writing and exits 1" {
  seed_all
  printf 'codex_reviews=enabled\n' >>"$STATE"
  apply --check
  [ "$status" -eq 1 ]
  [ "$output" = "codex_reviews: enabled (want disabled)" ]
  [ ! -e "$SETLOG" ]
}

@test "--check exits 0 when converged" {
  seed_all
  apply --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Against the installed gstack (skipped where it is absent, e.g. CI)
# ---------------------------------------------------------------------------

@test "live: every key gstack-egress grants names is managed" {
  [ -x "$REAL_EGRESS" ] || skip "gstack not installed"
  run "$REAL_EGRESS" grants
  [ "$status" -eq 0 ]
  named=$(grep -oE 'config\.yaml \([a-z_]+\)' <<<"$output" | grep -oE '[a-z_]+\)' | tr -d ')' | sort -u)
  [ -n "$named" ]
  for k in $named; do
    managed | grep -qE "^$k " || { echo "unmanaged egress key: $k"; false; }
  done
}

# `gstack-config get` exits 1 on a key it has no default for, and 0 on every
# key it knows even when that default is empty; `list` omits several known
# keys, so it is not the registry.
@test "live: every managed key is one gstack-config knows" {
  [ -x "$REAL_CONFIG" ] || skip "gstack not installed"
  home="$(mktemp -d)"
  managed | while read -r k _; do
    GSTACK_HOME="$home" "$REAL_CONFIG" get "$k" >/dev/null || { echo "gstack-config does not know: $k"; exit 1; }
  done
  rm -rf "$home"
  run env GSTACK_HOME="$home" "$REAL_CONFIG" get definitely_not_a_key
  [ "$status" -eq 1 ]
}

@test "live: converges a fresh GSTACK_HOME and the values survive gstack's validators" {
  [ -x "$REAL_CONFIG" ] || skip "gstack not installed"
  home="$(mktemp -d)"
  run env GSTACK_HOME="$home" "$SCRIPT"
  [ "$status" -eq 0 ]
  managed | while read -r k v; do
    got=$(GSTACK_HOME="$home" "$REAL_CONFIG" get "$k")
    [ "$got" = "$v" ] || { echo "$k: got '$got', want '$v'"; exit 1; }
  done
  run env GSTACK_HOME="$home" "$SCRIPT" --check
  rm -rf "$home"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Wiring: settings.json runs it at session start
# ---------------------------------------------------------------------------

SETTINGS="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json"

# gstack rewrites ~/.gstack/config.yaml on its own (first-run answers,
# ./setup bookkeeping), so the wanted values are re-applied at every session
# start. The call is backgrounded and silenced: a SessionStart hook's stdout
# lands in the model's context and Claude Code waits on it, so a synchronous
# or chatty converge would cost every session a delay for a no-op.
@test "SessionStart converges the gstack config in the background" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  run jaq -r '.hooks.SessionStart[].hooks[].command' "$SETTINGS"
  [ "$status" -eq 0 ]
  run grep -F 'gstack-config-apply' <<<"$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"&"* ]]
  [[ "$output" == *">/dev/null 2>&1"* ]]
}
