#!/usr/bin/env bats
# Tests for the yazi package install stow-deploy runs after it stows yazi
#
# Run: bats tests/stow-deploy-yazi.bats
# run-tests: parallel

SCRIPT="$BATS_TEST_DIRNAME/../scripts/stow-deploy"

# A copy of the script beside a yazi package holding one flat marker file, and a
# ya stub that logs the config dir and arguments it was called with. The marker
# stays out of a nested dot- directory because CI installs Stow 2.3.x from apt.
setup() {
  command -v stow >/dev/null 2>&1 || skip "stow not installed"
  fixture="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$fixture/scripts" "$fixture/stow/yazi"
  cp "$SCRIPT" "$fixture/scripts/stow-deploy"
  echo yazi >"$fixture/stow/yazi/dot-fixture-yazi"
  target="$BATS_TEST_TMPDIR/home"
  mkdir -p "$target"
  stubs="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$stubs"
  ya_log="$BATS_TEST_TMPDIR/ya.log"
  cat >"$stubs/ya" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$YAZI_CONFIG_HOME" "\$*" >>"$ya_log"
if [ -n "\${YA_STUB_ERROR:-}" ]; then
  echo "\$YA_STUB_ERROR" >&2
  exit 1
fi
EOF
  chmod +x "$stubs/ya"
}

# _home_deploy [stow-deploy args]...: deploy the fixture into a target that is
# also HOME, the only kind of deploy that installs yazi packages.
_home_deploy() {
  HOME="$target" STOW_DEPLOY_TARGET="$target" PATH="$stubs:$PATH" run "$fixture/scripts/stow-deploy" "$@"
}

@test "a \$HOME deploy of yazi installs the packages package.toml pins, discarding what an older pin left" {
  _home_deploy --headless --only yazi
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$target/.fixture-yazi" ]
  [[ "$output" == *"==> Installing yazi packages"* ]]
  [ "$(cat "$ya_log")" = "$target/.config/yazi|pkg install --discard" ]
}

@test "a failed yazi package install warns, names the rerun, and the deploy still succeeds" {
  YA_STUB_ERROR="Error: failed to fetch yazi-rs/plugins" _home_deploy --headless --only yazi
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: ya pkg install failed"* ]]
  [[ "$output" == *"    Error: failed to fetch yazi-rs/plugins"* ]]
  [[ "$output" == *"Rerun: ya pkg install --discard"* ]]
}

@test "a sandboxed deploy target never runs ya" {
  STOW_DEPLOY_TARGET="$target" PATH="$stubs:$PATH" run "$fixture/scripts/stow-deploy" --headless --only yazi
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$target/.fixture-yazi" ]
  [ ! -e "$ya_log" ]
}
