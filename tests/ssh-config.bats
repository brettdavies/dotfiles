#!/usr/bin/env bats
# Tests for the SSH client config in stow/ssh/dot-ssh/config, read through `ssh -G` so each assertion is about the
# options ssh resolves for a host rather than the file's text.
#
# Run: bats tests/ssh-config.bats
#
# The config is git-crypt ciphertext in a clone without the key, CI's included, so every test skips there and runs
# wherever the clone is unlocked, which the pre-push gate covers.

bats_require_minimum_version 1.5.0

SSH_CONFIG="$BATS_TEST_DIRNAME/../stow/ssh/dot-ssh/config"
DEV_PORTS="3000 5173 8080 8787 8788 8789 8976 9229"

setup() {
  [ "$(head -c 9 "$SSH_CONFIG" | tail -c 8)" != GITCRYPT ] || skip "the SSH config is git-crypt ciphertext in this clone"
  command -v ssh >/dev/null 2>&1 || skip "ssh is not installed"
}

resolved() {
  ssh -G -F "$SSH_CONFIG" "$1" </dev/null 2>/dev/null
}

option() {
  resolved "$1" | awk -v key="$2" '$1 == key { print $2 }'
}

@test "the tunnel entry forwards every dev port to the same port on the Linux server" {
  [ "$(option bd-tunnel hostname)" = "$(option bigdaddy hostname)" ]
  [ "$(option bd-tunnel localforward | sort -n | xargs)" = "$DEV_PORTS" ]
  for port in $DEV_PORTS; do
    resolved bd-tunnel | grep -qxF "localforward $port [localhost]:$port"
  done
}

@test "the tunnel keeps its other forwards when one local port is already taken" {
  [ -n "$(option bd-tunnel localforward)" ]
  [ "$(option bd-tunnel exitonforwardfailure)" = no ]
}

# ssh logs a forward's bind failure at INFO only for the last loopback address it tries; a refusal on the other
# address (a local server holding the port on ::1 alone, say) reaches the log only at VERBOSE or above.
@test "the tunnel logs a forward refused on either loopback address" {
  case "$(option bd-tunnel loglevel)" in
    VERBOSE | DEBUG | DEBUG1 | DEBUG2 | DEBUG3) ;;
    *) return 1 ;;
  esac
}

@test "the tunnel notices a dead connection within a minute" {
  interval=$(option bd-tunnel serveraliveinterval)
  count=$(option bd-tunnel serveralivecountmax)
  [ "$interval" -gt 0 ]
  [ $((interval * count)) -le 60 ]
}

@test "bd-dev still reaches the Linux server and forwards nothing" {
  [ "$(option bd-dev hostname)" = "$(option bigdaddy hostname)" ]
  [ -z "$(option bd-dev localforward)" ]
}
