#!/usr/bin/env bats
# Tests for the tmuxinator project configs
#
# Run: bats tests/tmuxinator-configs.bats

CONFIG_DIR="$BATS_TEST_DIRNAME/../stow/tmuxinator/dot-config/tmuxinator"
STOW_DEPLOY="$BATS_TEST_DIRNAME/../scripts/stow-deploy"

# Read the `name:` field, trimming trailing space and surrounding quotes.
config_name() {
  sed -n 's/^name:[[:space:]]*//p' "$1" | head -1 |
    sed 's/[[:space:]]*$//; s/^"//; s/"$//'
}

# Session names appearing in `tmux resize-pane -t <session>:main.N` targets.
resize_targets() {
  sed -n 's/.*resize-pane -t "\{0,1\}\([^":]*\):main\.[0-9]*.*/\1/p' "$1"
}

# Render a config the way tmuxinator does (ERB before YAML), with RUBY_PLATFORM
# overridden so both platform branches are checkable from one machine.
render_as() {
  ruby -W0 -rerb -e '
    Object.send(:remove_const, :RUBY_PLATFORM)
    Object.const_set(:RUBY_PLATFORM, ARGV[0])
    puts ERB.new(File.read(ARGV[1])).result
  ' "$1" "$2"
}

# Parse a render_as result as YAML and print the first window's pane count and
# the start hook, one `key=value` per line.
render_fields() {
  render_as "$1" "$2" | ruby -W0 -ryaml -e '
    y = YAML.safe_load($stdin.read)
    puts "panes=#{y["windows"][0].values[0]["panes"].length}"
    puts "on_project_start=#{y["on_project_start"]}"
  '
}

# Run a rendered on_project_start hook the way tmuxinator does (inlined into a
# /bin/sh script ahead of the tmux commands), with a stub `zsh` on PATH that
# exits with the given status. Prints the sentinel only if the script got past
# the hook.
run_hook_with_zsh_exit() {
  local hook
  hook=$(render_fields arm64-darwin25 "$CONFIG_DIR/vault.yml" | sed -n 's/^on_project_start=//p')
  [ -n "$hook" ] || return 99
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit %s\n' "$1" >"$BATS_TEST_TMPDIR/bin/zsh"
  chmod +x "$BATS_TEST_TMPDIR/bin/zsh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" sh -c "$hook
echo reached-new-session"
}

# ---------------------------------------------------------------------------
# Config directory
# ---------------------------------------------------------------------------

@test "config directory exists and holds projects" {
  [ -d "$CONFIG_DIR" ]
  run bash -c "ls '$CONFIG_DIR'/*.yml | wc -l"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Required fields
# ---------------------------------------------------------------------------

@test "every config declares name and root" {
  failures=()
  for cfg in "$CONFIG_DIR"/*.yml; do
    base=$(basename "$cfg")
    [ -n "$(config_name "$cfg")" ] || failures+=("$base: missing 'name:'")
    grep -q '^root:[[:space:]]*[^[:space:]]' "$cfg" || failures+=("$base: missing 'root:'")
  done
  [ "${#failures[@]}" -eq 0 ] || printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Session-name consistency
#
# `tmuxinator copy` duplicates a config verbatim, leaving the source project's
# `name:` and resize targets behind. A mismatched target silently resizes a
# different session, or nothing at all.
# ---------------------------------------------------------------------------

@test "resize targets reference each config's own session name" {
  failures=()
  for cfg in "$CONFIG_DIR"/*.yml; do
    base=$(basename "$cfg")
    name=$(config_name "$cfg")
    [ -n "$name" ] || continue
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      [ "$target" = "$name" ] ||
        failures+=("$base: resize target '$target' does not match name '$name'")
    done < <(resize_targets "$cfg")
  done
  [ "${#failures[@]}" -eq 0 ] || printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
}

@test "session names are unique across configs" {
  run bash -c "
    for cfg in '$CONFIG_DIR'/*.yml; do
      sed -n 's/^name:[[:space:]]*//p' \"\$cfg\" | head -1 | sed 's/[[:space:]]*\$//; s/^\"//; s/\"\$//'
    done | sort | uniq -d
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Platform-conditional roots
#
# vault.yml serves both machines by branching on RUBY_PLATFORM; the file's own
# comment explains the topology behind that.
# ---------------------------------------------------------------------------

@test "vault.yml roots at the Taildrive mount on macOS" {
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  run render_as arm64-darwin25 "$CONFIG_DIR/vault.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"root: /Volumes/vault"* ]]
  [[ "$output" == *"taildrive-mount vault"* ]]
  [[ "$output" != *"- lazygit"* ]]
}

@test "vault.yml roots at the server checkout on Linux" {
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  run render_as x86_64-linux "$CONFIG_DIR/vault.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"root: ~/obsidian-vault"* ]]
  [[ "$output" != *"taildrive-mount"* ]]
  [[ "$output" == *"- lazygit"* ]]
}

# The first-start hook resizes `Vault:main.3`, so dropping lazygit on macOS
# must leave an empty third pane behind rather than a two-pane window.
@test "vault.yml renders to valid YAML with three panes on both platforms" {
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  failures=()
  for platform in arm64-darwin25 x86_64-linux; do
    run render_fields "$platform" "$CONFIG_DIR/vault.yml"
    if [ "$status" -ne 0 ] || [[ "$output" != *"panes=3"* ]]; then
      failures+=("$platform: $output")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
}

# tmuxinator ignores hook exit codes, so the hook has to end the start script
# itself when the mount fails.
@test "the macOS start hook stops the start script when taildrive-mount fails" {
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  run run_hook_with_zsh_exit 1
  [ "$status" -eq 1 ]
  [[ "$output" != *"reached-new-session"* ]]
}

@test "the macOS start hook lets the start script continue when taildrive-mount succeeds" {
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  run run_hook_with_zsh_exit 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"reached-new-session"* ]]
}

# render_as uses stdlib ERB; tmuxinator renders through Erubi, whose trim
# handling differs. This checks the config against the script tmuxinator
# actually executes, where the hook also has to survive YAML parsing.
@test "tmuxinator renders vault.yml to a script that mounts before it starts tmux" {
  command -v tmuxinator >/dev/null 2>&1 || skip "tmuxinator not installed"
  TMUXINATOR_CONFIG="$CONFIG_DIR" run tmuxinator debug vault
  [ "$status" -eq 0 ]
  # tmuxinator renders with the host's own ruby, so the branch under test is
  # the host's platform; the server gets the checkout, with no hook at all.
  if [ "$(uname -s)" != "Darwin" ]; then
    [[ "$output" != *"taildrive-mount"* ]]
    [[ "$output" == *"lazygit"* ]]
    return 0
  fi
  [[ "$output" == *"zsh -c 'taildrive-mount vault' || exit 1"* ]]
  hook_line=$(printf '%s\n' "$output" | grep -n 'taildrive-mount' | cut -d: -f1)
  # tmuxinator emits the create branch or the attach branch depending on
  # whether the session is already running; the hook precedes either.
  session_line=$(printf '%s\n' "$output" |
    grep -nE 'tmux .*(new-session|attach-session|switch-client)' | head -1 | cut -d: -f1)
  [ -n "$session_line" ]
  [ "$hook_line" -lt "$session_line" ]
}

# ---------------------------------------------------------------------------
# Single source of truth
#
# tmuxinator searches ~/.config/tmuxinator in `start`/`stop` but not in `list`,
# so a config deployed there shadows the repo: it runs but never shows up.
# TMUXINATOR_CONFIG points at the repo directly, so nothing is stowed.
# ---------------------------------------------------------------------------

@test "tmuxinator is not a stow package" {
  run grep -E '^SHARED_PACKAGES=' "$STOW_DEPLOY"
  [ "$status" -eq 0 ]
  [[ "$output" != *" tmuxinator "* ]]
}

@test "no shadow configs at the XDG default path" {
  if [ ! -d "$HOME/.config/tmuxinator" ]; then
    skip "XDG tmuxinator directory does not exist"
  fi
  run bash -c "ls '$HOME/.config/tmuxinator'/*.yml 2>/dev/null | wc -l"
  [ "$output" -eq 0 ]
}
