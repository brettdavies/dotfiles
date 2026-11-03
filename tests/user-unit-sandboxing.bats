#!/usr/bin/env bats
# Sandboxing in the repo's systemd user units. A user manager cannot build a mount namespace by itself, so each
# directive in NAMESPACE_KEYS first puts the service in a user namespace that maps only the user's own uid. Every
# root-owned file then reads as owned by nobody, and ssh refuses any root-owned file /etc/ssh/ssh_config includes with
# "Bad owner or permissions". So a unit that runs ssh, directly or through git, rsync, or a wrapper, sets none of them.
# ~/.gitconfig routes https://github.com/ over ssh, so git against GitHub counts as ssh.
#
# Run: bats tests/user-unit-sandboxing.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."

# Measured on systemd 255 with `systemd-run --user -p <directive>`: each either runs the command with a one-uid
# /proc/self/uid_map or fails the unit while setting up the namespace. NoNewPrivileges=, the seccomp and address-family
# filters, ProtectProc= and ProcSubset= create none.
NAMESPACE_KEYS='PrivateTmp|PrivateUsers|PrivateNetwork|PrivateIPC|PrivateMounts|PrivateDevices|ProtectSystem|ProtectHome|ProtectKernelTunables|ProtectKernelModules|ProtectKernelLogs|ProtectControlGroups|ProtectClock|ProtectHostname|ReadOnlyPaths|ReadWritePaths|InaccessiblePaths|ExecPaths|NoExecPaths|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountAPIVFS|RootDirectory|RootImage'

# Every user unit that keeps a namespace directive, and why nothing it runs reaches ssh.
NO_SSH=(
  "stow/caddy/dot-config/systemd/user/caddy.service|a local reverse proxy"
  "stow/cargo/dot-config/systemd/user/cargo-target-sweep.service|deletes local build output"
  "stow/cswap/dot-config/systemd/user/cswap-auto.service|reads account usage over HTTPS"
  "stow/local/dot-config/systemd/user/github-stars-pdf.service|fetches with an explicit https://x-access-token@ URL, which no insteadOf rule matches"
  "stow/local/dot-config/systemd/user/qmd-cleanup.service|vacuums the local index"
  "stow/local/dot-config/systemd/user/qmd-embed.service|embeds local files on the GPU"
  "stow/local/dot-config/systemd/user/qmd-serve.service|serves models on localhost"
  "stow/local/dot-config/systemd/user/qmd-update.service|re-indexes local collections"
  "stow/obsidian/dot-config/systemd/user/vault-agent-sync-check.service|reads the sync log"
  "stow/rclone/dot-config/systemd/user/box-bisync.service|syncs with Box over HTTPS"
  "stow/rust/dot-config/systemd/user/rustup-update.service|downloads toolchains over HTTPS"
)

# _namespace_lines FILE: the lines of FILE that turn on a namespace directive.
_namespace_lines() {
  grep -nE "^($NAMESPACE_KEYS)=" "$1" | grep -viE '=(no|false|off|0)?[[:space:]]*$' || true
}

@test "every user unit that keeps a namespace directive is listed with why it runs no ssh" {
  local unit rel lines failed=0
  for unit in "$REPO_ROOT"/stow/*/dot-config/systemd/user/*.service; do
    rel=${unit#"$REPO_ROOT"/}
    lines=$(_namespace_lines "$unit")
    [[ -n $lines ]] || continue
    if ! printf '%s\n' "${NO_SSH[@]}" | grep -qF "$rel|"; then
      echo "$rel sets a directive that maps root to nobody, so ssh in it fails; remove it, or list the unit in NO_SSH:"
      echo "$lines"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "every unit listed as running no ssh exists and still sets a namespace directive" {
  local entry rel failed=0
  for entry in "${NO_SSH[@]}"; do
    rel=${entry%%|*}
    if [[ ! -f $REPO_ROOT/$rel ]]; then
      echo "NO_SSH names a missing unit: $rel"
      failed=1
    elif [[ -z $(_namespace_lines "$REPO_ROOT/$rel") ]]; then
      echo "NO_SSH names a unit with no namespace directive: $rel"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "a namespace directive turned off does not count" {
  local unit="$BATS_TEST_TMPDIR/off.service"
  printf '%s\n' '[Service]' 'PrivateTmp=false' 'ProtectHome=no' 'ReadOnlyPaths=' 'NoNewPrivileges=true' >"$unit"
  [ -z "$(_namespace_lines "$unit")" ]
  printf '%s\n' 'ProtectSystem=strict' >>"$unit"
  [ "$(_namespace_lines "$unit")" = '6:ProtectSystem=strict' ]
}
