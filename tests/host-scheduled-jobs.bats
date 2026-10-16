#!/usr/bin/env bats
# The Linux server's scheduled jobs: the vault agent-workspace sync and its health check, the OpenClaw settings backup,
# and the GitHub stars sync. They run as systemd user timers shipped in shared stow packages, so every unit carries
# ConditionHost=bigdaddy: stow-deploy restarts every timer a package ships on each Linux deploy, and `restart` starts a
# timer whether or not it was enabled. scripts/host-jobs-enable.sh enables them on that host and retires the crontab
# lines they replace.
#
# Run: bats tests/host-scheduled-jobs.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
OBS_UNITS="$REPO_ROOT/stow/obsidian/dot-config/systemd/user"
LOCAL_UNITS="$REPO_ROOT/stow/local/dot-config/systemd/user"
LOCAL_BIN="$REPO_ROOT/stow/local/dot-local/bin"
ENABLE="$REPO_ROOT/scripts/host-jobs-enable.sh"

HOST_JOBS=(
  "$OBS_UNITS/vault-agent-sync"
  "$OBS_UNITS/vault-agent-sync-check"
  "$LOCAL_UNITS/openclaw-settings-backup"
  "$LOCAL_UNITS/github-stars"
  "$LOCAL_UNITS/github-stars-clone"
)

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  export CRON_FILE="$BATS_TEST_TMPDIR/crontab"
  export STUB_OS=Linux STUB_HOST=bigdaddy
  cat >"$STUBS/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "$STUB_OS"
EOF
  cat >"$STUBS/hostname" <<'EOF'
#!/bin/sh
printf '%s\n' "$STUB_HOST"
EOF
  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
EOF
  cat >"$STUBS/crontab" <<'EOF'
#!/bin/sh
if [ "$1" = "-l" ]; then
  [ -f "$CRON_FILE" ] || { echo "no crontab for user" >&2; exit 1; }
  cat "$CRON_FILE"
elif [ "$1" = "-" ]; then
  cat >"$CRON_FILE"
fi
EOF
  chmod +x "$STUBS"/*
}

_enable() {
  run env PATH="$STUBS:$PATH" bash "$ENABLE"
}

_crontab_fixture() {
  cat >"$CRON_FILE" <<'EOF'
# Keep: unrelated job
*/5 * * * * /usr/bin/true

# Sync workspace to pool (hourly)
0 * * * * /home/brett/obsidian-vault/scripts/sync-to-pool.sh
0 * * * * sleep $((RANDOM \% 120)) && /home/brett/obsidian-vault/areas/infrastructure/scripts/github-stars.sh -j 4 >> /home/brett/.openclaw/logs/github-stars.log 2>&1
15,30,45 * * * * sleep $((RANDOM \% 120)) && /home/brett/obsidian-vault/areas/infrastructure/scripts/github-stars.sh --clone-only -j 4 >> /home/brett/.openclaw/logs/github-stars.log 2>&1
0 3 * * * /home/brett/obsidian-vault/areas/infrastructure/scripts/backup-openclaw-settings.sh
5 * * * * /home/brett/obsidian-vault/scripts/pool-sync-check.sh >> /home/brett/.openclaw/logs/pool-sync-check.log 2>&1
# DISABLED: 0 * * * * /home/brett/obsidian-vault/scripts/sync-to-pool.sh
30 4 * * * /usr/local/bin/other-job
EOF
}

# --- unit shape -------------------------------------------------------------

@test "every host job ships a service and a timer" {
  for job in "${HOST_JOBS[@]}"; do
    [ -f "$job.service" ] || { echo "missing $job.service"; return 1; }
    [ -f "$job.timer" ] || { echo "missing $job.timer"; return 1; }
  done
}

@test "every host-job unit is gated to its host" {
  for job in "${HOST_JOBS[@]}"; do
    grep -qx 'ConditionHost=bigdaddy' "$job.service" || { echo "$job.service"; return 1; }
    grep -qx 'ConditionHost=bigdaddy' "$job.timer" || { echo "$job.timer"; return 1; }
  done
}

@test "every host-job service is a oneshot with Homebrew on PATH and no hardcoded home" {
  for job in "${HOST_JOBS[@]}"; do
    grep -qx 'Type=oneshot' "$job.service"
    grep -qE '^Environment=PATH=.*/home/linuxbrew/\.linuxbrew/bin' "$job.service"
    run grep -nE '^(ExecStart|StandardOutput|StandardError)=.*/home/[a-z]' "$job.service"
    [ "$status" -eq 1 ] || { echo "$job.service: $output"; return 1; }
  done
}

@test "every host-job timer catches up after downtime and installs into timers.target" {
  for job in "${HOST_JOBS[@]}"; do
    grep -qx 'Persistent=true' "$job.timer"
    grep -qx 'WantedBy=timers.target' "$job.timer"
  done
}

@test "vault sync mirrors the agent workspace from the vault's scripts hourly" {
  grep -qx 'ExecStart=%h/obsidian-vault/scripts/sync-to-pool.sh' "$OBS_UNITS/vault-agent-sync.service"
  grep -qx 'OnCalendar=\*-\*-\* \*:00:00' "$OBS_UNITS/vault-agent-sync.timer"
}

@test "vault sync check runs at five past, appending to its log" {
  grep -qx 'ExecStart=%h/obsidian-vault/scripts/pool-sync-check.sh' "$OBS_UNITS/vault-agent-sync-check.service"
  grep -qx 'StandardOutput=append:%h/.openclaw/logs/pool-sync-check.log' "$OBS_UNITS/vault-agent-sync-check.service"
  grep -qx 'OnCalendar=\*-\*-\* \*:05:00' "$OBS_UNITS/vault-agent-sync-check.timer"
}

@test "vault sync check can reach the openclaw CLI for alerts" {
  grep -qE '^Environment=PATH=.*%h/\.npm-global/bin' "$OBS_UNITS/vault-agent-sync-check.service"
}

@test "settings backup runs the stowed command daily at 03:00" {
  grep -qx 'ExecStart=%h/.local/bin/backup-openclaw-settings' "$LOCAL_UNITS/openclaw-settings-backup.service"
  grep -qx 'OnCalendar=\*-\*-\* 03:00:00' "$LOCAL_UNITS/openclaw-settings-backup.timer"
}

@test "stars sync runs hourly and the clone pass at quarter hours, both randomized" {
  grep -qx 'ExecStart=%h/.local/bin/github-stars -j 4' "$LOCAL_UNITS/github-stars.service"
  grep -qx 'ExecStart=%h/.local/bin/github-stars --clone-only -j 4' "$LOCAL_UNITS/github-stars-clone.service"
  grep -qx 'OnCalendar=\*-\*-\* \*:00:00' "$LOCAL_UNITS/github-stars.timer"
  grep -qx 'OnCalendar=\*-\*-\* \*:15,30,45:00' "$LOCAL_UNITS/github-stars-clone.timer"
  grep -qx 'RandomizedDelaySec=120' "$LOCAL_UNITS/github-stars.timer"
  grep -qx 'RandomizedDelaySec=120' "$LOCAL_UNITS/github-stars-clone.timer"
}

@test "stars sync logs to the journal" {
  for unit in github-stars github-stars-clone; do
    run grep -nE '^Standard(Output|Error)=' "$LOCAL_UNITS/$unit.service"
    [ "$status" -eq 1 ] || { echo "$unit.service: $output"; return 1; }
  done
}

@test "backup-openclaw-settings is an executable stowed command with no hardcoded home" {
  [ -x "$LOCAL_BIN/backup-openclaw-settings" ]
  run grep -nE '/home/[a-z]' "$LOCAL_BIN/backup-openclaw-settings"
  [ "$status" -eq 1 ]
}

# --- enable script ------------------------------------------------------------

@test "enable script does nothing off Linux" {
  STUB_OS=Darwin _enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"Linux-only"* ]]
  [ ! -e "$SYSTEMCTL_LOG" ]
}

@test "enable script does nothing on another host" {
  _crontab_fixture
  cp "$CRON_FILE" "$BATS_TEST_TMPDIR/before"
  STUB_HOST=server-01 _enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping"* ]]
  [ ! -e "$SYSTEMCTL_LOG" ]
  cmp -s "$CRON_FILE" "$BATS_TEST_TMPDIR/before"
}

@test "enable script reloads systemd and enables every host-job timer on its host" {
  _enable
  [ "$status" -eq 0 ]
  grep -qx -- '--user daemon-reload' "$SYSTEMCTL_LOG"
  for job in "${HOST_JOBS[@]}"; do
    grep -qx -- "--user enable --now $(basename "$job").timer" "$SYSTEMCTL_LOG" || { cat "$SYSTEMCTL_LOG"; return 1; }
  done
}

@test "enable script retires exactly the crontab lines the timers replace" {
  _crontab_fixture
  _enable
  [ "$status" -eq 0 ]
  run grep -cE '^[^#]*(sync-to-pool|pool-sync-check|github-stars|backup-openclaw-settings)\.sh' "$CRON_FILE"
  [ "$output" = "0" ]
  grep -qx '\*/5 \* \* \* \* /usr/bin/true' "$CRON_FILE"
  grep -qx '30 4 \* \* \* /usr/local/bin/other-job' "$CRON_FILE"
  grep -qx '# Keep: unrelated job' "$CRON_FILE"
  grep -qx '# DISABLED: 0 \* \* \* \* /home/brett/obsidian-vault/scripts/sync-to-pool.sh' "$CRON_FILE"
}

@test "enable script drops the comment heading a retired job" {
  _crontab_fixture
  _enable
  [ "$status" -eq 0 ]
  run grep -c 'Sync workspace to pool' "$CRON_FILE"
  [ "$output" = "0" ]
}

@test "enable script is idempotent and tolerates an empty crontab" {
  _crontab_fixture
  _enable
  cp "$CRON_FILE" "$BATS_TEST_TMPDIR/after-first"
  _enable
  [ "$status" -eq 0 ]
  cmp -s "$CRON_FILE" "$BATS_TEST_TMPDIR/after-first"
  rm -f "$CRON_FILE"
  _enable
  [ "$status" -eq 0 ]
}

@test "enable script and the stowed command pass shellcheck" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run shellcheck "$ENABLE" "$LOCAL_BIN/backup-openclaw-settings"
  [ "$status" -eq 0 ]
}
