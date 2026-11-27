#!/usr/bin/env bats
# run-tests: parallel
# Tests for stow/local/dot-local/bin/nvidia-lts-watch, which fails once apt
# sees the 620-server driver in a released pocket, so that the failed-units
# notice at session start names the driver move as ready.
#
# apt-cache answers from $FIXTURE/policy, and systemd-notify logs its
# arguments to $FIXTURE/notify.
#
# Run: bats tests/nvidia-lts-watch.bats

WATCH="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/nvidia-lts-watch"
READY='NVIDIA 620-server-open 620.70.10-0ubuntu0.24.04.1 is in noble-updates: the driver move in docs/runbooks/headless-gpu-server-nvidia-driver.md is ready'

setup_file() {
  local stubs="$BATS_FILE_TMPDIR/stubs"
  mkdir -p "$stubs"
  cat >"$stubs/apt-cache" <<'EOF'
#!/bin/sh
# apt-cache policy PACKAGE, answered from $FIXTURE/policy; apt prints nothing
# for a package it does not know.
[ ! -f "$FIXTURE/policy" ] || cat "$FIXTURE/policy"
EOF
  cat >"$stubs/systemd-notify" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FIXTURE/notify"
EOF
  chmod 555 "$stubs/apt-cache" "$stubs/systemd-notify"
}

setup() {
  export FIXTURE="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE"
  export NOTIFY_SOCKET="$BATS_TEST_TMPDIR/notify.sock"
  PATH="$BATS_FILE_TMPDIR/stubs:$PATH"
}

# policy <version> <pocket>...: apt-cache policy for the 620 package with one
# version, published to each pocket.
policy() {
  local ver="$1" pocket
  shift
  {
    printf 'nvidia-headless-620-server-open:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' "$ver"
    printf '     %s 500\n' "$ver"
    for pocket in "$@"; do
      printf '        500 http://archive.ubuntu.com/ubuntu %s/multiverse amd64 Packages\n' "$pocket"
    done
  } >"$FIXTURE/policy"
}

@test "apt knowing no 620-server package passes and sets no status" {
  run "$WATCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt knows no nvidia-headless-620-server-open"* ]]
  [ ! -e "$FIXTURE/notify" ]
}

@test "a 620-server package only in noble-proposed passes and sets no status" {
  policy 620.70.06-0ubuntu0.24.04.1 noble-proposed
  run "$WATCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no released nvidia-headless-620-server-open"* ]]
  [ ! -e "$FIXTURE/notify" ]
}

@test "a 620-server package in noble-updates fails and sets the unit's status to the driver move" {
  policy 620.70.10-0ubuntu0.24.04.1 noble-updates noble-security
  run "$WATCH"
  [ "$status" -eq 1 ]
  [ "$output" = "$READY" ]
  [ "$(cat "$FIXTURE/notify")" = "--status=$READY" ]
}

@test "outside systemd a released package fails without calling systemd-notify" {
  policy 620.70.10-0ubuntu0.24.04.1 noble-updates
  unset NOTIFY_SOCKET
  run "$WATCH"
  [ "$status" -eq 1 ]
  [ "$output" = "$READY" ]
  [ ! -e "$FIXTURE/notify" ]
}

@test "-h and --help print the usage and exit 0; any other argument is a usage error (exit 2)" {
  local flag
  for flag in -h --help; do
    run "$WATCH" "$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == "usage: nvidia-lts-watch [-h | --help]"* ]]
    [[ "$output" == *"Read-only, no root."* ]]
  done
  run "$WATCH" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == "usage: nvidia-lts-watch"* ]]
}
