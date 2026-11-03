#!/usr/bin/env bats
# Sandboxing in the repo's systemd user units. A user manager cannot build a mount namespace by itself, so each
# directive in NAMESPACE_KEYS first puts the service in a user namespace that maps only the user's own uid. On the Linux
# server that namespace isolates nothing: AppArmor's unprivileged_userns profile denies it CAP_SYS_ADMIN, so the mount
# setup fails and the service keeps the host's /tmp. What it does do is read every root-owned file as owned by nobody,
# which makes ssh refuse the root-owned files /etc/ssh/ssh_config includes, hide every other process's /proc/<pid>/exe,
# and log an AppArmor denial for each open of / by the service. So no user unit sets one.
#
# Run: bats tests/user-unit-sandboxing.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."

# Measured on systemd 255 with `systemd-run --user -p <directive>`: each either runs the command with a one-uid
# /proc/self/uid_map or fails the unit while setting up the namespace. NoNewPrivileges=, the seccomp and address-family
# filters, ProtectProc= and ProcSubset= create none.
NAMESPACE_KEYS='PrivateTmp|PrivateUsers|PrivateNetwork|PrivateIPC|PrivateMounts|PrivateDevices|ProtectSystem|ProtectHome|ProtectKernelTunables|ProtectKernelModules|ProtectKernelLogs|ProtectControlGroups|ProtectClock|ProtectHostname|ReadOnlyPaths|ReadWritePaths|InaccessiblePaths|ExecPaths|NoExecPaths|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountAPIVFS|RootDirectory|RootImage'

# _namespace_lines FILE: the lines of FILE that turn on a namespace directive.
_namespace_lines() {
  grep -nE "^($NAMESPACE_KEYS)=" "$1" | grep -viE '=(no|false|off|0)?[[:space:]]*$' || true
}

@test "no user unit turns on a namespace directive" {
  local unit rel lines failed=0 count=0
  while IFS= read -r unit; do
    count=$((count + 1))
    rel=${unit#"$REPO_ROOT"/}
    lines=$(_namespace_lines "$unit")
    [[ -n $lines ]] || continue
    echo "$rel puts the unit in a one-uid user namespace that isolates nothing and maps root to nobody; remove:"
    echo "$lines"
    failed=1
  done < <(find "$REPO_ROOT"/stow/*/dot-config/systemd/user -type f)
  [ "$count" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "a namespace directive turned off does not count" {
  local unit="$BATS_TEST_TMPDIR/off.service"
  printf '%s\n' '[Service]' 'PrivateTmp=false' 'ProtectHome=no' 'ReadOnlyPaths=' 'NoNewPrivileges=true' >"$unit"
  [ -z "$(_namespace_lines "$unit")" ]
  printf '%s\n' 'ProtectSystem=strict' >>"$unit"
  [ "$(_namespace_lines "$unit")" = '6:ProtectSystem=strict' ]
}
