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
  mkdir -p "$HOME" "$T/bin" "$T/tree"
  local tool
  for tool in qmd uv; do
    printf '#!/bin/sh\necho "%s $PWD" >>"%s/calls"\n' "$tool" "$T" >"$T/bin/$tool"
    chmod +x "$T/bin/$tool"
  done
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
