#!/usr/bin/env bats
# A slot's Claude starts on a lean profile: the skills and plugins slots never use are off, and the four tools they
# never call are dropped, in every mode that starts Claude. The profile is one inline --settings object that merges
# with the user's settings.json, so a skill that file lists by name only stays that way. A Cloudflare repo keeps the
# cloudflare plugin.
#
# Run: bats tests/agent-slot-profile.bats
#
# Fixtures only: tmux is a stub that records the line typed into a session. Claude is a shell function that records its
# arguments, except in the one test that runs the typed line through the real binary against a port nothing listens on.
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  export AGENT_SLOT_CLAUDE_PROJECTS=$T/projects AGENT_SLOT_LOCK_WAIT=2 AGENT_SLOT_TRUST_TIMEOUT=3
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS"
  prime repoa
  local n
  for n in 1 2 3; do trusted "$(realpath -m "$AGENT_SLOT_ROOT/repoa/$n")"; done
  WORDS=()
}

teardown() {
  stop_spawned
  assert_no_leaks
}

launch() {
  local model=(--model opus)
  [[ " $* " != *" --model "* ]] || model=()
  run --separate-stderr "$AGENT_SLOT" launch repoa "$@" "${model[@]}" --output json
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
}

typed() { cat "$STUBS/typed-repoa-${1:-1}"; }

# words N: the arguments Claude receives from the line typed into slot N's session, one per element of WORDS.
words() {
  bash -c 'claude() { printf "%s\0" "$@"; }; eval "$1"' _ "$(typed "$1")" >"$T/words"
  mapfile -d '' -t WORDS <"$T/words"
}

# word_after FLAG: the argument that follows FLAG in WORDS.
word_after() {
  local i
  for i in "${!WORDS[@]}"; do
    if [[ ${WORDS[i]} == "$1" ]]; then
      printf '%s' "${WORDS[i + 1]}"
      return 0
    fi
  done
  return 1
}

# wrangler PATH: a Cloudflare config file in the prime, which the next slot's clone carries.
wrangler() {
  origin_file repoa "$1" '{}'
  git -C "$AGENT_SLOT_DEV/repoa" pull -q origin main
}

# plugins: the enabledPlugins object of slot 1's settings argument.
plugins() {
  words 1
  word_after --settings | jaq -c '.enabledPlugins'
}

CLOUDFLARE='cloudflare@claude-plugins-official'
OBSIDIAN='obsidian@obsidian-skills'

@test "a launch starts Claude on the slot profile, between the bypass flag and the model" {
  launch --request-id r1
  local session
  session=$(jaq -r .session_id <<<"$output")
  [ "$(typed)" = "claude --dangerously-skip-permissions $(slot_profile_args) --model claude-opus-5-5 --effort xhigh --session-id $session -n repoa-1" ]
}

@test "the settings argument reaches Claude as one JSON object that keeps idle compaction off" {
  launch --request-id r1
  words 1
  word_after --settings | jaq -e 'type == "object" and .idleCompaction == false'
}

@test "the profile turns skills off and never sets one by name only or on, so the listing refresh keeps its entries" {
  launch --request-id r1
  words 1
  word_after --settings | jaq -e '(.skillOverrides | length) > 0 and ([.skillOverrides[]] | all(. == "off"))'
  word_after --settings | jaq -e '.skillOverrides | has("loop") and has("schedule") and has("code-review")
    and has("update-config") and has("claude-api") and has("artifact-design")'
}

@test "the skills slots rely on stay on" {
  launch --request-id r1
  words 1
  local skill
  word_after --settings | jaq -e '(.skillOverrides | length) > 0' >/dev/null
  for skill in agent-slot unslop devex-review plan-eng-review plan-devex-review 1password qmd investigate \
    prose-check cso impeccable last30days browse optimize-builds-and-tests homebrew-tap-publish write-skill test-audit; do
    word_after --settings | jaq -e --arg s "$skill" '.skillOverrides | has($s) | not' >/dev/null || {
      echo "the profile turns off $skill"
      false
    }
  done
}

@test "the obsidian and cloudflare plugins are off when the repo has no Cloudflare config" {
  launch --request-id r1
  [ "$(plugins)" = "{\"$OBSIDIAN\":false,\"$CLOUDFLARE\":false}" ]
}

@test "every plugin the profile turns off is one the user's settings enable, under the same id" {
  local id
  for id in "$OBSIDIAN" "$CLOUDFLARE"; do
    jaq -e --arg id "$id" '.enabledPlugins | has($id)' "$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json" >/dev/null || {
      echo "settings.json enables no plugin $id"
      false
    }
  done
}

@test "the four tools the profile drops are dropped by name, and nothing else" {
  launch --request-id r1
  words 1
  local i start=-1 dropped=()
  for i in "${!WORDS[@]}"; do [[ ${WORDS[i]} == --disallowedTools ]] && start=$i; done
  ((start >= 0))
  for ((i = start + 1; i < ${#WORDS[@]}; i++)); do
    [[ ${WORDS[i]} == -* ]] && break
    dropped+=("${WORDS[i]}")
  done
  [ "${dropped[*]}" = "Artifact AskUserQuestion ScheduleWakeup ReportFindings" ]
}

@test "a Sonnet slot gets the profile and keeps Opus as its advisor" {
  launch --request-id r1 --model sonnet
  local session
  session=$(jaq -r .session_id <<<"$output")
  [ "$(typed)" = "CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL=1 claude --dangerously-skip-permissions $(slot_profile_args) --model claude-sonnet-5-5 --effort xhigh --advisor opus --session-id $session -n repoa-1" ]
}

@test "resuming a dormant slot restarts Claude on the profile" {
  slot repoa 1 '{"session_id": "aaaaaaaa-1111-2222-3333-444444444444", "task": "fix-login"}'
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS/-srv-slots-repoa-1"
  : >"$AGENT_SLOT_CLAUDE_PROJECTS/-srv-slots-repoa-1/aaaaaaaa-1111-2222-3333-444444444444.jsonl"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  [ "$(typed)" = "claude --dangerously-skip-permissions $(slot_profile_args) --model claude-opus-5-5 --effort xhigh --resume aaaaaaaa-1111-2222-3333-444444444444 -n fix-login" ]
}

@test "a Cloudflare config at the repo root keeps the cloudflare plugin on" {
  wrangler wrangler.jsonc
  launch --request-id r1
  [ "$(plugins)" = "{\"$OBSIDIAN\":false}" ]
  [ "$(typed)" = "claude --dangerously-skip-permissions $(slot_profile_args cloudflare) --model claude-opus-5-5 --effort xhigh --session-id $(jaq -r .session_id <<<"$output") -n repoa-1" ]
}

@test "a wrangler.jsonc two directories down keeps the plugin on" {
  wrangler apps/web/wrangler.jsonc
  launch --request-id r1
  [ "$(plugins)" = "{\"$OBSIDIAN\":false}" ]
}

@test "a wrangler.toml two directories down keeps the plugin on" {
  wrangler apps/api/wrangler.toml
  launch --request-id r1
  [ "$(plugins)" = "{\"$OBSIDIAN\":false}" ]
}

@test "a wrangler.json one directory down keeps the plugin on" {
  wrangler site/wrangler.json
  launch --request-id r1
  [ "$(plugins)" = "{\"$OBSIDIAN\":false}" ]
}

@test "a config three directories down, in node_modules, or under another name does not keep the plugin" {
  wrangler a/b/c/wrangler.toml
  wrangler node_modules/pkg/wrangler.jsonc
  wrangler wrangler.yaml
  launch --request-id r1
  [ "$(plugins)" = "{\"$OBSIDIAN\":false,\"$CLOUDFLARE\":false}" ]
}

@test "resuming a Cloudflare slot keeps the plugin on" {
  slot repoa 1 '{"session_id": "aaaaaaaa-1111-2222-3333-444444444444", "task": "fix-login"}'
  printf '{}\n' >"$AGENT_SLOT_ROOT/repoa/1/wrangler.jsonc"
  run --separate-stderr "$AGENT_SLOT" resume repoa/1 --output json
  [ "$status" -eq 0 ]
  [ "$(plugins)" = "{\"$OBSIDIAN\":false}" ]
}

@test "the profile line does not depend on the IFS of the shell that builds it" {
  local line
  line=$(bash -c 'IFS=:; source "$1"; profile_args /nonexistent' _ "$BATS_TEST_DIRNAME/../scripts/agent-slot/lib/profile.sh")
  [ "$line" = "$(slot_profile_args)" ]
}

@test "the real Claude accepts the typed line: its flags and its settings JSON parse before the first request" {
  local real
  real=$(command -v claude || true)
  [ -n "$real" ] || skip "Claude Code is not installed"
  launch --request-id r1
  (
    cd "$AGENT_SLOT_ROOT/repoa/1" || exit 1
    # shellcheck disable=SC2329 # the eval below calls it
    claude() { "$real" -p "$@"; }
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR CLAUDE_CODE_SSE_PORT TMUX TMUX_PANE
    export CLAUDE_CONFIG_DIR=$T/claude-config ANTHROPIC_API_KEY=sk-ant-test ANTHROPIC_BASE_URL=http://127.0.0.1:9
    export CLAUDE_CODE_MAX_RETRIES=0 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1
    mkdir -p "$CLAUDE_CONFIG_DIR"
    eval "$(typed) 'say ok'" </dev/null >"$T/real-claude.out" 2>&1 || true
  )
  ! grep -q 'Invalid JSON\|unknown option' "$T/real-claude.out" || {
    cat "$T/real-claude.out"
    false
  }
  grep -q 'ECONNREFUSED\|Connection refused' "$T/real-claude.out" || {
    cat "$T/real-claude.out"
    false
  }
}
