#!/usr/bin/env bats
# skill-listing-refresh lists skills no session used within a rolling window by name only, in settings.json.
#
# Run: bats tests/skill-listing-refresh.bats
# run-tests: parallel

setup() {
  T=$BATS_TEST_TMPDIR
  SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/skill-listing-refresh"
  export CLAUDE_CONFIG_DIR=$T/claude
  SETTINGS=$CLAUDE_CONFIG_DIR/settings.json
  local skill
  for skill in called typed aged idle retired pinned 1password named back; do
    mkdir -p "$CLAUDE_CONFIG_DIR/skills/$skill"
    echo "name: $skill" >"$CLAUDE_CONFIG_DIR/skills/$skill/SKILL.md"
  done
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/p/subagents"
  printf '{"type":"tool_use","name":"Skill","input":{"skill":"called"}}\n' >"$CLAUDE_CONFIG_DIR/projects/p/recent.jsonl"
  printf '<command-name>/typed</command-name>\n' >"$CLAUDE_CONFIG_DIR/projects/p/subagents/agent.jsonl"
  printf '{"name":"Skill","input":{"skill":"back"}}\n' >>"$CLAUDE_CONFIG_DIR/projects/p/recent.jsonl"
  printf '{"name":"Skill","input":{"skill":"aged"}}\n' >"$CLAUDE_CONFIG_DIR/projects/p/old.jsonl"
  touch -t 202001010000 "$CLAUDE_CONFIG_DIR/projects/p/old.jsonl"
  echo 'Run `/named` first.' >"$CLAUDE_CONFIG_DIR/CLAUDE.md"
  printf '{\n  "model": "x",\n  "skillOverrides": {\n    "retired": "off",\n    "pinned": "on",\n    "back": "name-only"\n  }\n}\n' >"$SETTINGS"
}

override() { jaq -r --arg k "$1" '.skillOverrides[$k] // "none"' "$SETTINGS"; }

@test "a skill no session used goes name-only, and a skill used again comes back" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(override idle)" = name-only ]
  [ "$(override back)" = none ]
  [ "$(override called)" = none ]
  [ "$(override typed)" = none ]
}

@test "the window rolls: an old transcript counts only inside a window that reaches it" {
  "$SCRIPT"
  [ "$(override aged)" = name-only ]
  "$SCRIPT" --window-days 100000
  [ "$(override aged)" = none ]
}

@test "off and on entries, the always-described skill, and a skill CLAUDE.md names stay as they are" {
  "$SCRIPT"
  [ "$(override retired)" = off ]
  [ "$(override pinned)" = on ]
  [ "$(override 1password)" = none ]
  [ "$(override named)" = none ]
}

@test "a skill already hidden from the listing gets no entry, since an override would change nothing" {
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/hidden"
  printf -- '---\nname: hidden\ndisable-model-invocation: true\n---\n' >"$CLAUDE_CONFIG_DIR/skills/hidden/SKILL.md"
  "$SCRIPT"
  [ "$(override hidden)" = none ]
}

@test "a scan that finds no use refuses, so a moved transcript store can't hide every description" {
  before=$(cat "$SETTINGS")
  mv "$CLAUDE_CONFIG_DIR/projects" "$CLAUDE_CONFIG_DIR/moved"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *'no skill use found'* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "a window that isn't a whole number of days is a usage error, and settings stay as they were" {
  before=$(cat "$SETTINGS")
  run "$SCRIPT" --window-days soon
  [ "$status" -eq 2 ]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "a dry run changes nothing and names what would change" {
  before=$(cat "$SETTINGS")
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *idle* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "a run with nothing to change leaves the file alone" {
  "$SCRIPT"
  touch -t 202001010000 "$SETTINGS"
  "$SCRIPT"
  [ "$(stat -c %Y "$SETTINGS")" = "$(date -d '2020-01-01 00:00' +%s)" ]
}

@test "settings reached through a link stay a link, with the real file rewritten" {
  mv "$SETTINGS" "$T/real.json"
  ln -s "$T/real.json" "$SETTINGS"
  "$SCRIPT"
  [ -L "$SETTINGS" ]
  [ "$(jaq -r '.skillOverrides.idle' "$T/real.json")" = name-only ]
}

@test "a plain pull still lands when upstream changes the file the script rewrote" {
  local g=(git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false)
  "${g[@]}" init -q -b dev "$T/upstream"
  cp "$SETTINGS" "$T/upstream/settings.json"
  "${g[@]}" -C "$T/upstream" add settings.json
  "${g[@]}" -C "$T/upstream" commit -q -m base
  "${g[@]}" clone -q "$T/upstream" "$T/live"
  rm "$SETTINGS"
  ln -s "$T/live/settings.json" "$SETTINGS"
  "$SCRIPT"
  sed -i 's/"model": "x"/"model": "y"/' "$T/upstream/settings.json"
  "${g[@]}" -C "$T/upstream" commit -q -am upstream
  "${g[@]}" -C "$T/live" pull -q --no-edit
  [ "$(jaq -r .model "$T/live/settings.json")" = y ]
  [ "$(jaq -r '.skillOverrides.idle' "$T/live/settings.json")" = name-only ]
}
