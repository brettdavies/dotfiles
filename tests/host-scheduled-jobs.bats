#!/usr/bin/env bats
# The Linux server's scheduled jobs: the vault agent-workspace sync and its health check, the GitHub stars sync, the
# daily brew and uv tool upgrades, the automatic agent slot sweep, and the agent slot tab reconcile. They run as systemd
# user timers shipped in shared stow packages, so every unit carries ConditionHost=bigdaddy: stow-deploy restarts every
# timer a package ships on each Linux deploy, and `restart` starts a timer whether or not it was enabled.
# scripts/host-jobs-enable.sh enables them on that host and retires the crontab lines they replace. The same script
# enables the host's long-running user services: the Rex server that keeps the account's tabs up with no client
# connected.
#
# Run: bats tests/host-scheduled-jobs.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
OBS_UNITS="$REPO_ROOT/stow/obsidian/dot-config/systemd/user"
LOCAL_UNITS="$REPO_ROOT/stow/local/dot-config/systemd/user"
ENABLE="$REPO_ROOT/scripts/host-jobs-enable.sh"
REX_SERVER="$LOCAL_UNITS/rex-server.service"
NUMBERS="$LOCAL_UNITS/rex-tab-numbers.service"

HOST_JOBS=(
  "$OBS_UNITS/vault-agent-sync"
  "$OBS_UNITS/vault-agent-sync-check"
  "$LOCAL_UNITS/github-stars"
  "$LOCAL_UNITS/github-stars-clone"
  "$LOCAL_UNITS/brew-upgrade"
  "$LOCAL_UNITS/uv-tools-upgrade"
  "$LOCAL_UNITS/agent-slot-sweep"
  "$LOCAL_UNITS/agent-slot-reconcile"
)
RECONCILE="$LOCAL_UNITS/agent-slot-reconcile"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  export CRON_FILE="$BATS_TEST_TMPDIR/crontab"
  export STUB_OS=Linux STUB_HOST=bigdaddy
  export OP_SKILL="$STUBS/op-skill" OP_LOG="$BATS_TEST_TMPDIR/op.log"
  export STARS_ENV="$BATS_TEST_TMPDIR/home/.config/github-stars/env"
  mkdir -p "$OP_SKILL"
  cat >"$OP_SKILL/read_field.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$OP_LOG"
[ "${STUB_OP_FAIL:-0}" = 1 ] && exit 1
printf 'stub-token'
EOF
  chmod +x "$OP_SKILL/read_field.sh"
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

# _unit_key FILE SECTION KEY: each value KEY takes in SECTION of the unit FILE, one per line.
_unit_key() {
  awk -v sec="[$2]" -v key="$3" '
    /^\[/ { in_sec = ($0 == sec); next }
    in_sec && index($0, key "=") == 1 { print substr($0, length(key) + 2) }
  ' "$1"
}

_crontab_fixture() {
  cat >"$CRON_FILE" <<'EOF'
# Keep: unrelated job
*/5 * * * * /usr/bin/true

# Sync workspace to pool (hourly)
0 * * * * /home/brett/obsidian-vault/scripts/sync-to-pool.sh
0 * * * * sleep $((RANDOM \% 120)) && /home/brett/obsidian-vault/areas/infrastructure/scripts/github-stars.sh -j 4 >> /home/brett/.openclaw/logs/github-stars.log 2>&1
15,30,45 * * * * sleep $((RANDOM \% 120)) && /home/brett/obsidian-vault/areas/infrastructure/scripts/github-stars.sh --clone-only -j 4 >> /home/brett/.openclaw/logs/github-stars.log 2>&1
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

@test "vault sync check runs the repo's check at five past, appending to its log and alerting through the journal" {
  grep -qx 'ExecStart=%h/dotfiles/scripts/vault-agent-sync-check.sh' "$OBS_UNITS/vault-agent-sync-check.service"
  grep -qx 'StandardOutput=append:%h/.openclaw/logs/pool-sync-check.log' "$OBS_UNITS/vault-agent-sync-check.service"
  grep -qx 'StandardError=journal' "$OBS_UNITS/vault-agent-sync-check.service"
  grep -qx 'SyslogLevel=err' "$OBS_UNITS/vault-agent-sync-check.service"
  grep -qx 'OnCalendar=\*-\*-\* \*:05:00' "$OBS_UNITS/vault-agent-sync-check.timer"
}

@test "stars sync runs hourly and the clone pass at quarter hours, both randomized" {
  grep -qx 'ExecStart=%h/.local/bin/github-stars -j 8' "$LOCAL_UNITS/github-stars.service"
  grep -qx 'ExecStart=%h/.local/bin/github-stars --clone-only -j 8' "$LOCAL_UNITS/github-stars-clone.service"
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

@test "the PDF converter is a host-gated oneshot that only a successful stars sync starts" {
  local unit="$LOCAL_UNITS/github-stars-pdf.service"
  grep -qx 'ConditionHost=bigdaddy' "$unit"
  grep -qx 'Type=oneshot' "$unit"
  grep -qx 'ExecStart=%h/.local/bin/github-stars-pdf' "$unit"
  grep -qx 'EnvironmentFile=-%h/.config/github-stars/env' "$unit"
  grep -qE '^Environment=PATH=.*/home/linuxbrew/\.linuxbrew/bin' "$unit"
  run grep -nE '^(ExecStart|StandardOutput|StandardError)=.*/home/[a-z]' "$unit"
  [ "$status" -eq 1 ]
  [ ! -e "$LOCAL_UNITS/github-stars-pdf.timer" ]
  run grep -n '^\[Install\]' "$unit"
  [ "$status" -eq 1 ]
  for svc in github-stars github-stars-clone; do
    grep -qx 'OnSuccess=github-stars-pdf.service' "$LOCAL_UNITS/$svc.service" || { echo "$svc.service"; return 1; }
  done
}

@test "both stars units load the read-only token file when it exists" {
  for unit in github-stars github-stars-clone; do
    grep -qx 'EnvironmentFile=-%h/.config/github-stars/env' "$LOCAL_UNITS/$unit.service" || { echo "$unit.service"; return 1; }
  done
}

# --- the Rex server -----------------------------------------------------------

@test "the Rex server unit runs rex server run with no quit-when-empty, reporting ready to systemd, on its host" {
  [ "$(_unit_key "$REX_SERVER" Service ExecStart)" = '/usr/bin/rex server run' ]
  [ "$(_unit_key "$REX_SERVER" Service Type)" = notify ]
  [ "$(_unit_key "$REX_SERVER" Unit ConditionHost)" = bigdaddy ]
  [ "$(_unit_key "$REX_SERVER" Install WantedBy)" = default.target ]
}

@test "the Rex server unit restarts always, every 10 s, with no start limit" {
  [ "$(_unit_key "$REX_SERVER" Service Restart)" = always ]
  [ "$(_unit_key "$REX_SERVER" Service RestartSec)" = 10s ]
  [ "$(_unit_key "$REX_SERVER" Unit StartLimitIntervalSec)" = 0 ]
}

@test "the Rex server unit sets no sandboxing, which every program its tabs run would inherit" {
  run grep -nE '^(PrivateTmp|ProtectHome|PrivateDevices|NoNewPrivileges)=' "$REX_SERVER"
  [ "$status" -eq 1 ]
}

@test "systemd accepts the Rex server unit" {
  command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not installed"
  [ -x /usr/bin/rex ] || skip "rex not installed"
  local runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [ -d "$runtime" ] || skip "no user runtime directory"
  run env XDG_RUNTIME_DIR="$runtime" systemd-analyze --user verify "$REX_SERVER"
  [ "$status" -eq 0 ]
  [[ $output != *"rex-server.service:"* ]]
}

@test "the reconcile timer runs the helper's timer pass every minute, and catches up after downtime" {
  [ "$(_unit_key "$RECONCILE.service" Service ExecStart)" = '%h/.local/bin/agent-slot-rex restore --by poll --output json' ]
  [ "$(_unit_key "$RECONCILE.timer" Timer OnCalendar)" = 'minutely' ]
  [ "$(_unit_key "$RECONCILE.timer" Timer AccuracySec)" = 1s ]
  [ "$(_unit_key "$RECONCILE.timer" Timer Persistent)" = true ]
}

@test "the reconcile and sweep services set no sandboxing, which the slots their passes resume would inherit" {
  local unit
  for unit in "$RECONCILE.service" "$LOCAL_UNITS/agent-slot-sweep.service"; do
    run grep -nE '^(PrivateTmp|ProtectHome|PrivateDevices|NoNewPrivileges)=' "$unit"
    [ "$status" -eq 1 ] || { echo "$unit: $output"; return 1; }
  done
}

@test "systemd accepts the reconcile units" {
  command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not installed"
  # verify fails a unit whose ExecStart names a missing file, and the service runs the stowed helper.
  [ -x "$HOME/.local/bin/agent-slot-rex" ] || skip "agent-slot-rex not deployed"
  local runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [ -d "$runtime" ] || skip "no user runtime directory"
  run env XDG_RUNTIME_DIR="$runtime" systemd-analyze --user verify "$RECONCILE.service" "$RECONCILE.timer"
  [ "$status" -eq 0 ]
  [[ $output != *"agent-slot-reconcile."* ]]
}

@test "the tab-number watcher runs with the Rex server, restarting every 5 s with no start limit" {
  [ "$(_unit_key "$NUMBERS" Unit After)" = rex-server.service ]
  [ "$(_unit_key "$NUMBERS" Unit BindsTo)" = rex-server.service ]
  [ "$(_unit_key "$NUMBERS" Install WantedBy)" = rex-server.service ]
  [ "$(_unit_key "$NUMBERS" Unit StartLimitIntervalSec)" = 0 ]
  [ "$(_unit_key "$NUMBERS" Unit ConditionHost)" = bigdaddy ]
  [ "$(_unit_key "$NUMBERS" Service Restart)" = always ]
  [ "$(_unit_key "$NUMBERS" Service RestartSec)" = 5s ]
  [ "$(_unit_key "$NUMBERS" Service ExecStart)" = '/usr/bin/rex --autostart=false do --all %h/.config/rex/tab-numbers.lua' ]
  run grep -nE '^(PrivateTmp|ProtectHome|PrivateDevices|NoNewPrivileges)=' "$NUMBERS"
  [ "$status" -eq 1 ]
}

@test "systemd accepts the tab-number watcher unit" {
  command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not installed"
  [ -x /usr/bin/rex ] || skip "rex not installed"
  local runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [ -d "$runtime" ] || skip "no user runtime directory"
  run env XDG_RUNTIME_DIR="$runtime" systemd-analyze --user verify "$REX_SERVER" "$NUMBERS"
  [ "$status" -eq 0 ]
  [[ $output != *"rex-tab-numbers.service:"* ]]
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
  [ ! -e "$STARS_ENV" ]
  cmp -s "$CRON_FILE" "$BATS_TEST_TMPDIR/before"
}

# GNU stat takes -c; the BSD stat on macOS takes -f.
_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

@test "enable script writes the stars token file from 1Password when it is missing" {
  _enable
  [ "$status" -eq 0 ]
  [ "$(cat "$STARS_ENV")" = "GH_TOKEN=stub-token" ]
  [ "$(_mode "$STARS_ENV")" = "600" ]
  [ "$(_mode "${STARS_ENV%/*}")" = "700" ]
  grep -qx '6zqmvltmdtcsoxew2vgvnfrb2y credential' "$OP_LOG"
  [[ "$output" != *"stub-token"* ]]
}

@test "enable script keeps an existing stars token file" {
  mkdir -p "${STARS_ENV%/*}"
  printf 'GH_TOKEN=keep\n' >"$STARS_ENV"
  _enable
  [ "$status" -eq 0 ]
  [ "$(cat "$STARS_ENV")" = "GH_TOKEN=keep" ]
  [ ! -e "$OP_LOG" ]
}

@test "enable script falls back to the gh login when 1Password cannot be read" {
  STUB_OP_FAIL=1 _enable
  [ "$status" -eq 0 ]
  [ ! -e "$STARS_ENV" ]
  [[ "$output" == *"falls back to the gh login"* ]]
  grep -qx -- '--user enable --now github-stars.timer' "$SYSTEMCTL_LOG"
}

@test "enable script reloads systemd and enables every host-job timer on its host" {
  _enable
  [ "$status" -eq 0 ]
  grep -qx -- '--user daemon-reload' "$SYSTEMCTL_LOG"
  for job in "${HOST_JOBS[@]}"; do
    grep -qx -- "--user enable --now $(basename "$job").timer" "$SYSTEMCTL_LOG" || { cat "$SYSTEMCTL_LOG"; return 1; }
  done
}

# Under set -e, `enable --now` of a unit no package ships fails the script on the host before the jobs after it.
@test "every unit the enable script names ships in a package" {
  local unit count=0
  while read -r unit; do
    count=$((count + 1))
    [ -f "$OBS_UNITS/$unit" ] || [ -f "$LOCAL_UNITS/$unit" ] || { echo "no package ships $unit"; return 1; }
  done < <(awk '/^(TIMERS|SERVICES)=\(/ { on = 1; next } on && /^\)/ { on = 0 } on { print $1 }' "$ENABLE")
  [ "$count" -gt 0 ]
}

@test "enable script enables the Rex server without waiting on its start, and lists it at the end" {
  # systemd fails a start that waits while the login server's own Rex server holds the account socket.
  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in *--now*rex-server.service) case "$*" in *--no-block*) ;; *) exit 1 ;; esac ;; esac
EOF
  _enable
  [ "$status" -eq 0 ]
  grep -qx -- '--user enable --now --no-block rex-server.service' "$SYSTEMCTL_LOG"
  grep -qx -- '--user enable --now --no-block rex-tab-numbers.service' "$SYSTEMCTL_LOG"
  grep -qE -- '^--user list-units .*rex-server\.service rex-tab-numbers\.service' "$SYSTEMCTL_LOG"
}

@test "enable script retires exactly the crontab lines the timers replace" {
  _crontab_fixture
  _enable
  [ "$status" -eq 0 ]
  run grep -cE '^[^#]*(sync-to-pool|pool-sync-check|github-stars)\.sh' "$CRON_FILE"
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

@test "enable script passes shellcheck" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run shellcheck "$ENABLE"
  [ "$status" -eq 0 ]
}
