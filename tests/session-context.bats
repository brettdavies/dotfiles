#!/usr/bin/env bats
# stow/claude/dot-claude/session-context.sh reports the host's tools, so nothing it starts needs the session's working
# directory, which can be a tree nobody has reviewed: a Bun-run tool such as qmd runs the preload a bunfig.toml there names.
#
# Run: bats tests/session-context.bats
# run-tests: parallel

setup() {
  T=$BATS_TEST_TMPDIR
  HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/session-context.sh"
  # An empty HOME, so the hook's listing of ~/.cargo has nothing to walk.
  export HOME=$T/home
  export XDG_CACHE_HOME=$T/cache
  INVENTORY=$XDG_CACHE_HOME/claude/tool-inventory.cache
  mkdir -p "$HOME" "$T/bin" "$T/tree"
  local tool
  for tool in brew pipx qmd uv; do
    printf '#!/bin/sh\necho "%s $PWD" >>"%s/calls"\n' "$tool" "$T" >"$T/bin/$tool"
    chmod +x "$T/bin/$tool"
  done
  echo 'echo a-tap/tap/formula-one' >>"$T/bin/brew"
  echo 'echo "app-one 1.2.3"' >>"$T/bin/pipx"
  printf 'echo "uv-package v1.2.3"\necho "- uv-command"\n' >>"$T/bin/uv"
  PATH=$T/bin:$PATH
}

@test "the hook starts its tools outside the working directory it runs in" {
  (cd "$T/tree" && "$HOOK" >/dev/null)
  grep -qx 'qmd /' "$T/calls"
  grep -qx 'uv /' "$T/calls"
}

@test "the hook still reports qmd's collections" {
  printf '#!/bin/sh\necho "the collections"\n' >"$T/bin/qmd"
  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ $output == *'--- qmd collections ---'*'the collections'* ]]
}

@test "the hook prints the tools as one line of bare names" {
  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ $output == *$'\nInstalled CLI tools: app-one formula-one uv-command\n'* ]]
}

@test "a fresh inventory is reused and a stale one is rebuilt" {
  "$HOOK" >/dev/null
  "$HOOK" >/dev/null
  [ "$(grep -c '^brew ' "$T/calls")" -eq 1 ]
  touch -t 202001010000 "$INVENTORY"
  "$HOOK" >/dev/null
  [ "$(grep -c '^brew ' "$T/calls")" -eq 2 ]
}
