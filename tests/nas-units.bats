#!/usr/bin/env bats
# Shape checks for the NAS mount units in config/systemd/system/ and the
# reachability probe in scripts/nas-deploy.sh.
#
# Run: bats tests/nas-units.bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
UNITS="$REPO_ROOT/config/systemd/system"

# An automount unit is implicitly ordered Before=local-fs.target. Ordering it
# after the network as well closes a loop through network.target,
# wpa_supplicant, dbus, basic.target and sysinit.target, and systemd breaks
# that loop at boot by dropping an arbitrary job (apparmor.service among them).
@test "the automount carries no network ordering" {
  run grep -nE '^(After|Wants|Requires|BindsTo)=.*network' "$UNITS/mnt-nas.automount"
  [ "$status" -eq 1 ]
}

@test "the mount itself waits for the network" {
  grep -qx 'After=network-online.target' "$UNITS/mnt-nas.mount"
  grep -qx 'Wants=network-online.target' "$UNITS/mnt-nas.mount"
}

@test "Documentation= entries use URL schemes systemd accepts" {
  run grep -nE '^Documentation=' "$UNITS/mnt-nas.mount" "$UNITS/mnt-nas.automount"
  for line in "${lines[@]}"; do
    for url in ${line#*Documentation=}; do
      [[ "$url" =~ ^(https?|file|info|man): ]] || { echo "rejected by systemd: $url"; return 1; }
    done
  done
}

@test "nas-deploy probes the SMB port instead of shelling out to ping" {
  run sh -c 'grep -vE "^[[:space:]]*#" "$1" | grep -nwE "ping"' _ "$REPO_ROOT/scripts/nas-deploy.sh"
  [ "$status" -eq 1 ]
  grep -qF '/dev/tcp/$NAS_IP/445' "$REPO_ROOT/scripts/nas-deploy.sh"
}
