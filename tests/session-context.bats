#!/usr/bin/env bats
# stow/claude/dot-claude/session-context.sh reports the host's tools, so nothing it starts needs the session's working
# directory, which can be a tree nobody has reviewed: a Bun-run tool such as qmd runs the preload a bunfig.toml there names.
#
# Run: bats tests/session-context.bats
# run-tests: parallel

setup() {
  T=$BATS_TEST_TMPDIR
  HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/session-context.sh"
  # An empty HOME, so the hook's listings of ~/.cargo, ~/.bun, and the npm cache have nothing to walk.
  export HOME=$T/home
  export XDG_CACHE_HOME=$T/cache
  INVENTORY=$XDG_CACHE_HOME/claude/tool-inventory.cache
  mkdir -p "$HOME" "$T/bin" "$T/tree"
  local tool
  for tool in brew qmd uv; do
    printf '#!/bin/sh\necho "%s $PWD" >>"%s/calls"\n' "$tool" "$T" >"$T/bin/$tool"
    chmod +x "$T/bin/$tool"
  done
  echo 'echo a-formula' >>"$T/bin/brew"
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

@test "the hook names the inventory's path and leaves the listing out of the session" {
  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ $output == *"$INVENTORY"* ]]
  [[ $output != *a-formula* ]]
  grep -qF a-formula "$INVENTORY"
}

@test "a fresh inventory is reused and a stale one is rebuilt" {
  "$HOOK" >/dev/null
  "$HOOK" >/dev/null
  [ "$(grep -c '^brew ' "$T/calls")" -eq 1 ]
  touch -t 202001010000 "$INVENTORY"
  "$HOOK" >/dev/null
  [ "$(grep -c '^brew ' "$T/calls")" -eq 2 ]
}
