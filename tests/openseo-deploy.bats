#!/usr/bin/env bats
# scripts/openseo-deploy.sh runs OpenSEO's Docker stack on the Linux server and binds it to svc:openseo. The suite
# stubs docker, tailscale, curl, ssh, and the 1Password read, so it runs no container, binds nothing, and reads no secret.
# The ssh stub runs the NAS's commands on this host with the NAS's /boot/config and /usr/local/emhttp mapped into
# $NAS_ROOT, where compose.sh is a stub that logs its arguments.
# Every stub secret starts with STUBSECRET so a leak into output or an argument list is one grep.
#
# Run: bats tests/openseo-deploy.bats

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/openseo-deploy.sh"
LIB="$REPO_ROOT/scripts/openseo/lib"
PIN="$REPO_ROOT/config/openseo/openseo.pin"
COMPOSE="$REPO_ROOT/config/openseo/compose.yaml"
RUNBOOK="$REPO_ROOT/docs/runbooks/openseo.md"
STORAGE_ITEM=tdkhy4vi4ijxryxihwb4xdjowy
ADMIN_ITEM=hwacawam6ghon7c4tlxswldzye
DFS_ITEM=lx26y32x6zcxkfiahuvis6yv2m
GOOGLE_ITEM=ws3ujqnvak5jvhnikn3zwh4sxi
OPENROUTER_ITEM=3pyrzbnoefzfsvbdquhh3w5fei
COMPOSE_SH=/usr/local/emhttp/plugins/compose.manager/scripts/compose.sh
REAL_DOCKER=$(command -v docker || true)

setup_file() {
  load lib/platform
  require_linux "the script uses GNU timeout, stat, and sha256sum, and refuses to run elsewhere"
}

_stub_at() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$1"
  chmod +x "$1"
}
_stub() { _stub_at "$STUBS/$1" "$2"; }

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS/op"
  export NAS_ROOT="$BATS_TEST_TMPDIR/nas"
  STACK="$NAS_ROOT/boot/config/plugins/compose.manager/projects/openseo"
  mkdir -p "$NAS_ROOT/emhttp/plugins/compose.manager/scripts"
  _stub_at "$NAS_ROOT/emhttp/plugins/compose.manager/scripts/compose.sh" 'echo "compose.sh $*" >>"$CALLS"
  case "$1" in
    -cup)
      [ "${STUB_INIT:-ok}" != hang ] || exec sleep 30
      [ "${STUB_INIT:-ok}" != fail ] || { echo "service \"init\" didn'"'"'t complete successfully: exit 1"; exit 1; }
      [ "${STUB_UP_FAIL:-}" != 1 ] || { echo "up failed"; exit 1; } ;;
    -cstop) [ "${STUB_STOP_FAIL:-}" != 1 ] || { echo "stop failed"; exit 1; } ;;
  esac'
  export CALLS="$BATS_TEST_TMPDIR/calls.log" ACCOUNT="$BATS_TEST_TMPDIR/account" STDIN_FILE="$BATS_TEST_TMPDIR/stdin"
  export OPENSEO_ENV_DIR="$BATS_TEST_TMPDIR/cfg/openseo" OP_SKILL="$STUBS/op"
  export STUB_HEALTH=ok STUB_FIRST=false STUB_ADDR=ok STUB_CAP=1 STUB_BOUND=0
  export OPENSEO_ADVERTISE_WAIT=1 OPENSEO_HEALTH_WAIT=1 OPENSEO_INIT_TIMEOUT=2 TICKS="$BATS_TEST_TMPDIR/ticks"
  _stub uname 'if [ -n "${STUB_OS:-}" ]; then echo "$STUB_OS"; else command -p uname "$@"; fi'
  _stub op/read_field.sh 'echo "read_field $*" >>"$CALLS"
  [ "${STUB_OP_FAIL:-}" != 1 ] || exit 1
  case "$1:$2" in
    '$STORAGE_ITEM':password) printf "%s" "${STUB_STORAGE:-STUBSECRET_storage_0123456789}" ;;
    '$ADMIN_ITEM':username) printf "admin@openseo.test" ;;
    '$ADMIN_ITEM':password) printf "STUBSECRET_admin_pw_0123" ;;
    dfs-item:credential | '$DFS_ITEM':credential) printf "STUBSECRET_dfs_credential==" ;;
    google-item:client_id | '$GOOGLE_ITEM':client_id) printf "stub-client-id.apps.test" ;;
    google-item:client_secret | '$GOOGLE_ITEM':client_secret) printf "STUBSECRET_google_secret" ;;
    '$OPENROUTER_ITEM':credential) printf "STUBSECRET_openrouter_key" ;;
    *) exit 1 ;;
  esac'
  _stub tailscale 'echo "tailscale $*" >>"$CALLS"
  if [ "$1 $2" = "status --json" ]; then
    [ "${STUB_TS_FAIL:-}" != 1 ] || exit 1
    echo >>"$TICKS.cap"; cap=""
    [ "$STUB_CAP" = 1 ] && [ "$(wc -l <"$TICKS.cap")" -ge "${STUB_CAP_AFTER:-1}" ] && cap=",{\"svc:openseo\":[\"100.64.0.9\"]}"
    echo "{\"MagicDNSSuffix\":\"tail-test.ts.net\",\"Self\":{\"CapMap\":{\"service-host\":[{\"svc:ollama\":[\"100.64.0.1\"]}$cap]}}}"
  fi
  if [ "$1 $2" = "serve status" ]; then
    [ "${STUB_STATUS_FAIL:-}" != 1 ] || exit 1
    [ "$STUB_BOUND" = 1 ] && echo "{\"Services\":{\"svc:openseo\":{}}}"
  fi
  [ "${STUB_SERVE_FAIL:-}" != 1 ] || [ "$1" != serve ] || [[ " $* " != *" --yes "* ]] || { echo "serve: not permitted" >&2; exit 1; }
  [ "${STUB_OFF_FAIL:-}" != 1 ] || [ "${*: -1}" != off ] || { echo "serve: cannot turn it off" >&2; exit 1; }
  exit 0'
  _stub curl 'echo "curl ${*: -1}" >>"$CALLS"
  first=$STUB_FIRST; [ ! -e "$ACCOUNT" ] || first=false
  case "${*: -1}" in
    http://127.0.0.1:8946/api/health)
      echo >>"$TICKS.health"
      [ "$STUB_HEALTH" != down ] && [ "$(wc -l <"$TICKS.health")" -ge "${STUB_HEALTH_AFTER:-1}" ] || exit 22
      echo "{\"status\":\"$STUB_HEALTH\"}" ;;
    http://127.0.0.1:8946/api/sign-up-status) echo "{\"firstAccount\":$first}" ;;
    https://openseo.tail-test.ts.net/api/health) [ "$STUB_ADDR" = ok ] || exit 22; echo "{\"status\":\"ok\"}" ;;
  esac'
  _stub docker 'echo "docker $*" >>"$CALLS"
  echo "env COMPOSE_FILE=${COMPOSE_FILE-unset} COMPOSE_ENV_FILES=${COMPOSE_ENV_FILES-unset} PORT=${PORT-unset} OPENSEO_IMAGE=${OPENSEO_IMAGE-unset} OPENROUTER_API_KEY=${OPENROUTER_API_KEY-unset} COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME-unset} DOCKER_HOST=${DOCKER_HOST-unset}" >>"$CALLS"
  sub=$2; [ "$sub" != -p ] || sub=$4
  case "$sub" in
    pull) [ "${STUB_PULL_FAIL:-}" != 1 ] || { echo "pull access denied" >&2; exit 1; } ;;
    up)
      [ "${STUB_INIT:-ok}" != hang ] || exec sleep 30
      [ "${STUB_INIT:-ok}" != fail ] || { echo "service \"init\" didn'"'"'t complete successfully: exit 1" >&2; exit 1; }
      [ "${STUB_UP_FAIL:-}" != 1 ] || { echo "up failed" >&2; exit 1; } ;;
    logs)
      if [ "${STUB_NOREADY:-}" = 1 ]; then echo "Runtime did not start"; else echo "OpenSEO initialized and ready."; fi
      [[ " $* " != *" -f "* ]] || exec sleep 300 ;;
    exec)
      cat >"$STDIN_FILE"
      [ "${STUB_EXEC_FAIL:-}" != 1 ] || { echo "Account command failed; check the server logs" >&2; exit 1; }
      : >"$ACCOUNT" ;;
  esac'
  _stub ssh 'echo "ssh $*" >>"$CALLS"
  [ "${STUB_SSH_FAIL:-}" != 1 ] || { echo "ssh: connect to host pool port 22: Connection refused" >&2; exit 255; }
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
  shift 2
  case "$*" in *"${STUB_SSH_MISSING:-@@}"*) echo "sh: 1: $STUB_SSH_MISSING: not found" >&2; exit 127 ;; esac
  rw="s#/boot/config#$NAS_ROOT/boot/config#g;s#/usr/local/emhttp#$NAS_ROOT/emhttp#g"
  [ "$*" != "sh -s" ] || { sed "$rw" | sh -s; exit; }
  exec sh -c "$(printf %s "$*" | sed "$rw")"'
  PATH="$STUBS:$PATH"
}

_run() { run "$SCRIPT" "$@"; }
_prep() {
  _run render
  [ "$status" -eq 0 ]
  : >"$CALLS"
}
_docker_calls() { grep "^docker" "$CALLS"; }
_served() { grep -q "tailscale serve --service=svc:openseo --https=443 --yes" "$CALLS"; }
_never() { ! grep -qE "$1" "$CALLS"; }
_no_leaks() { [[ $output != *STUBSECRET* ]] && ! grep -q STUBSECRET "$CALLS"; }
_not_served() { ! _served; }
_no_volumes() { ! grep "^docker" "$CALLS" | grep -qE "(^| )(-v|--volumes)( |$)"; }
_all_loopback() { ! grep "ports:" "$COMPOSE" | grep -qv "127.0.0.1:"; }
_ssh_calls() { grep '^ssh ' "$CALLS"; }
_remote_only() { awk '/^(curl http:\/\/127\.0\.0\.1|tailscale serve)/ && prev !~ /^ssh .* -- pool / { bad = 1 } { prev = $0 } END { exit bad }' "$CALLS"; }
_ssh_only_allowed() { ! grep '^ssh ' "$CALLS" | grep -qvE "^ssh -n -o BatchMode=yes -o ConnectTimeout=10 -- pool (tailscale|curl|docker|test -x|d=.*exec $COMPOSE_SH -c(up|stop)) "; }
_web_label() { awk '/^  [a-z][a-z-]*:/ { svc = $1 } svc == "web:" && $1 == "net.unraid.docker.webui:" { print $2 }' "$1" | tr -d '"'; }
_break_stack_dir() { mkdir -p "${STACK%/*/*}" && : >"${STACK%/*}"; }
_nas_compose_calls() { grep -c "COMPOSE_ENV_FILES=$OPENSEO_ENV_DIR/nas.env .*DOCKER_HOST=ssh://${1:-pool}\$" "$CALLS"; }
_pin_image() { sed "s|^image .*|image $1|" "$PIN" >"$BATS_TEST_TMPDIR/variant.pin"; }
_load_pin() { run bash -c 'source "$1/errors.sh"; source "$1/pin.sh"; pin_load "$2"; echo "$PIN_IMAGE"' _ "$LIB" "$1"; }

@test "the vendored compose file is the one the pin records" {
  want=$(awk '$1 == "sha256" && $2 == "compose.yaml" { print $3 }' "$PIN")
  [ "$(sha256sum "$COMPOSE" | cut -d' ' -f1)" = "$want" ]
}

@test "every image but the OPENSEO_IMAGE default is pinned by digest, and every port binds loopback" {
  run grep -E '^[[:space:]]+image:' "$COMPOSE"
  [ "$status" -eq 0 ]
  for line in "${lines[@]}"; do
    [[ $line == *OPENSEO_IMAGE* || $line =~ @sha256:[0-9a-f]{64}$ ]]
  done
  run grep -E 'ports:' "$COMPOSE"
  [[ "$output" == *'"127.0.0.1:'* ]]
  _all_loopback
}

@test "docker compose config pins the three app services and publishes only on loopback" {
  [ "${OPENSEO_TEST_DOCKER:-}" = 1 ] || skip "operator opt-in: OPENSEO_TEST_DOCKER=1 runs docker, which agents never do"
  [ -n "$REAL_DOCKER" ] || skip "docker is not installed"
  image=$(awk '$1 == "image" { print $2 }' "$PIN")
  run env COMPOSE_FILE="$COMPOSE" STORAGE_ACCESS_KEY=a STORAGE_SECRET_KEY=b OPENSEO_IMAGE="$image" "$REAL_DOCKER" compose config --format json
  [ "$status" -eq 0 ]
  jq -e --arg i "$image" '[.services.runtime.image, .services.init.image, .services["crawl-gateway"].image] | all(. == $i)' <<<"$output"
  jq -e '[.services[].ports[]?.host_ip] | all(. == "127.0.0.1")' <<<"$output"
}

@test "the pin parser accepts the committed pin and prints its image, the rolling tag :0" {
  _load_pin "$PIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(awk '$1 == "image" { print $2 }' "$PIN")" ]
  [ "$output" = ghcr.io/every-app/open-seo-standalone:0 ]
}

@test "the pin parser accepts a numeric rolling tag on the app repository" {
  for ref in ghcr.io/every-app/open-seo-standalone:0 ghcr.io/every-app/open-seo-standalone:0.1; do
    _pin_image "$ref"
    _load_pin "$BATS_TEST_TMPDIR/variant.pin"
    [ "$status" -eq 0 ]
    [ "$output" = "$ref" ]
  done
}

@test "the pin parser rejects latest, main, a digest, a release tag, and another repository, naming the line" {
  digest=$(printf '0%.0s' {1..64})
  for ref in ghcr.io/every-app/open-seo-standalone:latest ghcr.io/every-app/open-seo-standalone:main \
    "ghcr.io/every-app/open-seo-standalone@sha256:$digest" ghcr.io/every-app/open-seo-standalone:0.1.27 \
    ghcr.io/every-app/open-seo-standalone:v0 ghcr.io/every-app/open-seo-standalone: ghcr.io/every-app/other:0; do
    _pin_image "$ref"
    _load_pin "$BATS_TEST_TMPDIR/variant.pin"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: pin-invalid:"*"image at line "* ]]
  done
}

@test "the pin parser rejects an unknown key and a repeated key, naming the line" {
  { cat "$PIN"; echo 'mystery value'; } >"$BATS_TEST_TMPDIR/variant.pin"
  _load_pin "$BATS_TEST_TMPDIR/variant.pin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pin-invalid:"*" at line "* ]]
  { cat "$PIN"; grep '^tag ' "$PIN"; } >"$BATS_TEST_TMPDIR/variant.pin"
  _load_pin "$BATS_TEST_TMPDIR/variant.pin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pin-invalid:"*"repeat of tag"* ]]
}

@test "a compose file that differs from the pin's checksum is refused" {
  { cat "$COMPOSE"; echo '# hand edit'; } >"$BATS_TEST_TMPDIR/compose.yaml"
  run bash -c 'source "$1/errors.sh"; source "$1/pin.sh"; pin_load "$2"; pin_verify "$3"' _ "$LIB" "$PIN" "$BATS_TEST_TMPDIR/compose.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pin-mismatch:"*"fix: git -C ~/dotfiles checkout -- config/openseo/compose.yaml"* ]]
}

@test "render writes a mode-600 env file in a mode-700 directory with every key and the tailnet address" {
  _run render
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$OPENSEO_ENV_DIR")" = 700 ]
  [ "$(stat -c %a "$OPENSEO_ENV_DIR/local.env")" = 600 ]
  for key in AUTH_MODE PORT STORAGE_ACCESS_KEY STORAGE_SECRET_KEY BETTER_AUTH_URL OPENSEO_IMAGE DATAFORSEO_API_KEY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET OPENROUTER_API_KEY OPENROUTER_MODEL; do
    grep -q "^$key=" "$OPENSEO_ENV_DIR/local.env"
  done
  grep -qx 'BETTER_AUTH_URL=https://openseo.tail-test.ts.net' "$OPENSEO_ENV_DIR/local.env"
  grep -qx 'PORT=8946' "$OPENSEO_ENV_DIR/local.env"
  grep -qx "OPENSEO_IMAGE=$(awk '$1 == "image" { print $2 }' "$PIN")" "$OPENSEO_ENV_DIR/local.env"
}

@test "render prints no secret and passes none to any command" {
  OPENSEO_DATAFORSEO_ITEM=dfs-item OPENSEO_GOOGLE_ITEM=google-item _run render
  [ "$status" -eq 0 ]
  _no_leaks
  grep -q '^STORAGE_SECRET_KEY=STUBSECRET_storage' "$OPENSEO_ENV_DIR/local.env"
}

@test "render writes the DataForSEO key and the Google client from the items the script names" {
  _run render
  [ "$status" -eq 0 ]
  grep -q "^read_field $DFS_ITEM credential" "$CALLS"
  grep -q "^read_field $GOOGLE_ITEM client_id" "$CALLS"
  grep -qx 'DATAFORSEO_API_KEY=STUBSECRET_dfs_credential==' "$OPENSEO_ENV_DIR/local.env"
  grep -qx 'GOOGLE_CLIENT_ID=stub-client-id.apps.test' "$OPENSEO_ENV_DIR/local.env"
  grep -qx 'GOOGLE_CLIENT_SECRET=STUBSECRET_google_secret' "$OPENSEO_ENV_DIR/local.env"
}

@test "render with an empty DataForSEO item leaves the key empty and names the variable" {
  OPENSEO_DATAFORSEO_ITEM='' _run render
  [ "$status" -eq 0 ]
  grep -qx 'DATAFORSEO_API_KEY=' "$OPENSEO_ENV_DIR/local.env"
  [[ "$output" == *"NOTE: DATAFORSEO_API_KEY renders empty"*"OPENSEO_DATAFORSEO_ITEM"* ]]
}

@test "an optional item that cannot be read names the variable that skips it, and the storage item does not" {
  OPENSEO_GOOGLE_ITEM=missing-item _run render
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: item-unreadable:"*"missing-item"*"set OPENSEO_GOOGLE_ITEM to the empty string"* ]]
  OPENSEO_GOOGLE_ITEM='' _run render
  [ "$status" -eq 0 ]
  STUB_OP_FAIL=1 _run render
  [[ "$output" != *"to render without it"* ]]
}

@test "render writes OPENROUTER_API_KEY from its item and the model constant, on both hosts" {
  _run render
  [ "$status" -eq 0 ]
  grep -q "^read_field $OPENROUTER_ITEM credential" "$CALLS"
  grep -qx 'OPENROUTER_API_KEY=STUBSECRET_openrouter_key' "$OPENSEO_ENV_DIR/local.env"
  grep -qx 'OPENROUTER_MODEL=anthropic/claude-sonnet-5.5' "$OPENSEO_ENV_DIR/local.env"
  _run render --host nas
  grep -qx 'OPENROUTER_API_KEY=STUBSECRET_openrouter_key' "$OPENSEO_ENV_DIR/nas.env"
  grep -qx 'OPENROUTER_MODEL=anthropic/claude-sonnet-5.5' "$OPENSEO_ENV_DIR/nas.env"
  _no_leaks
  OPENSEO_OPENROUTER_ITEM='' _run render
  [ "$status" -eq 0 ]
  grep -qx 'OPENROUTER_API_KEY=' "$OPENSEO_ENV_DIR/local.env"
  grep -qx 'OPENROUTER_MODEL=anthropic/claude-sonnet-5.5' "$OPENSEO_ENV_DIR/local.env"
  [[ "$output" == *"NOTE: OPENROUTER_API_KEY renders empty"*"OPENSEO_OPENROUTER_ITEM"* ]]
}

@test "render writes the pin's image over the one already in the env file" {
  _prep
  sed -i 's|^OPENSEO_IMAGE=.*|OPENSEO_IMAGE=ghcr.io/every-app/open-seo-standalone@sha256:0000000000000000000000000000000000000000000000000000000000000000|' "$OPENSEO_ENV_DIR/local.env"
  _run render
  [ "$status" -eq 0 ]
  grep -qx "OPENSEO_IMAGE=$(awk '$1 == "image" { print $2 }' "$PIN")" "$OPENSEO_ENV_DIR/local.env"
  [ "$(grep -c '^OPENSEO_IMAGE=' "$OPENSEO_ENV_DIR/local.env")" -eq 1 ]
}

@test "a failed 1Password read exits 1 naming the item and leaves an existing env file byte-identical" {
  _prep
  before=$(cksum <"$OPENSEO_ENV_DIR/local.env")
  STUB_OP_FAIL=1 _run render
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: item-unreadable:"*"$STORAGE_ITEM (OpenSEO - Storage Secret (openseo))"*"fix: ~/.claude/skills/1password/scripts/get_item.sh $STORAGE_ITEM"* ]]
  [ "$(cksum <"$OPENSEO_ENV_DIR/local.env")" = "$before" ]
}

@test "a storage secret that differs from the env file's exits 1, names the item and the restore path, and changes nothing" {
  _prep
  before=$(cksum <"$OPENSEO_ENV_DIR/local.env")
  STUB_STORAGE=STUBSECRET_other _run render
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: storage-key-changed:"*"$STORAGE_ITEM"*"restore"* ]]
  [ "$(cksum <"$OPENSEO_ENV_DIR/local.env")" = "$before" ]
}

@test "a value an env file cannot carry safely is refused and nothing is written" {
  STUB_STORAGE='STUBSECRET_$HOME' _run render
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: value-unsafe:"* ]]
  [ ! -e "$OPENSEO_ENV_DIR/local.env" ]
}

@test "render with tailscale status failing exits 1 naming it and writes nothing" {
  STUB_TS_FAIL=1 _run render
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: tailscale-unavailable:"*"tailscale status --json"*"fix: tailscale status, then tailscale up"* ]]
  [ ! -e "$OPENSEO_ENV_DIR/local.env" ]
}

@test "render on a Darwin host exits 1 before reading any secret" {
  STUB_OS=Darwin _run render
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unsupported-host:"* ]]
  _never read_field
}

@test "up pulls, starts, force-recreates init web crawl-gateway, waits on init, then binds, all on the vendored file and env file" {
  _run up
  [ "$status" -eq 0 ]
  run _docker_calls
  [ "${lines[0]}" = "docker compose pull" ]
  [ "${lines[1]}" = "docker compose up -d" ]
  [ "${lines[2]}" = "docker compose up -d --force-recreate init web crawl-gateway" ]
  [[ "${lines[3]}" == "docker compose logs"*" init" ]]
  [ "${#lines[@]}" -eq 4 ]
  [ "$(grep -c "^env COMPOSE_FILE=$COMPOSE COMPOSE_ENV_FILES=$OPENSEO_ENV_DIR/local.env " "$CALLS")" -eq 4 ]
  _served
}

@test "up drops exported variables that would override the env file" {
  PORT=3000 OPENSEO_IMAGE=wrong OPENROUTER_API_KEY=leak COMPOSE_PROJECT_NAME=other DOCKER_HOST=ssh://elsewhere _run up
  [ "$status" -eq 0 ]
  [ "$(grep -c 'PORT=unset OPENSEO_IMAGE=unset OPENROUTER_API_KEY=unset COMPOSE_PROJECT_NAME=unset DOCKER_HOST=unset$' "$CALLS")" -eq 4 ]
}

@test "up stops before any docker call when render fails" {
  STUB_OP_FAIL=1 _run up
  [ "$status" -eq 1 ]
  _never "^docker"
}

@test "up with a failing pull exits 1 naming the image and never starts the stack" {
  STUB_PULL_FAIL=1 _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pull-failed:"*"open-seo-standalone:0"*"cause: pull access denied"* ]]
  _never "docker compose up"
}

@test "up whose init exits non-zero reports init-failed with the logs command, not up-failed" {
  STUB_INIT=fail _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: init-failed:"*"cause: service \"init\" didn't complete successfully"*"fix: COMPOSE_FILE="*"docker compose logs init"* ]]
  _not_served
}

@test "up whose init exits 0 without its ready line reports init-failed with the log's last line" {
  STUB_NOREADY=1 _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: init-failed:"*"cause: Runtime did not start"* ]]
  _not_served
}

@test "up gives up on a start that never finishes, naming the bound and the logs command" {
  OPENSEO_INIT_TIMEOUT=1 STUB_INIT=hang _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: init-failed: init did not complete within 1s"*"docker compose logs init"* ]]
}

@test "up says what it waits for and how to follow it before the first start, and reads the log without following" {
  _run up
  [ "$status" -eq 0 ]
  [[ "$output" == *"starting the stack"*"docker compose logs -f init"* ]]
  [[ "$output" == *"init finished"* ]]
}

@test "up with a failing compose up reports up-failed and names up" {
  STUB_UP_FAIL=1 _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: up-failed:"*"cause: up failed"*"fix: ~/dotfiles/scripts/openseo-deploy.sh up"* ]]
}

@test "up turns the binding off before it starts anything, and leaves the address dark when the start fails" {
  STUB_BOUND=1 STUB_UP_FAIL=1 _run up
  [ "$status" -eq 1 ]
  [ "$(grep -nF 'tailscale serve --service=svc:openseo --https=443 off' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n '^docker compose up' "$CALLS" | head -1 | cut -d: -f1)" ]
  _not_served
}

@test "up stops before it starts anything when the binding will not turn off" {
  STUB_BOUND=1 STUB_OFF_FAIL=1 _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unbind-failed:"*"cause: serve: cannot turn it off"*"fix: tailscale serve --service=svc:openseo --https=443 off"* ]]
  _never "docker compose up"
}

@test "up waits for the health endpoint to answer before it checks the gate" {
  STUB_HEALTH_AFTER=2 OPENSEO_HEALTH_WAIT=5 _run up
  [ "$status" -eq 0 ]
  _served
}

@test "up and serve with no account yet never bind and name create-admin" {
  STUB_FIRST=true _run up
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE:"*"create-admin"* ]]
  STUB_FIRST=true _run serve
  [ "$status" -eq 0 ]
  _not_served
}

@test "serve with unhealthy OpenSEO exits 1 and never binds" {
  _prep
  STUB_HEALTH=issues _run serve
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unhealthy:"*"'issues'"*"fix: ~/dotfiles/scripts/openseo-deploy.sh up"* ]]
  _not_served
}

@test "serve without a rendered env file names render" {
  _run serve
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: env-missing:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh render"* ]]
}

@test "serve with no account yet and a binding in place turns the binding off and names create-admin" {
  _prep
  STUB_FIRST=true STUB_BOUND=1 _run serve
  [ "$status" -eq 0 ]
  grep -qF 'tailscale serve --service=svc:openseo --https=443 off' "$CALLS"
  [[ "$output" == *"binding is now off"*"create-admin"* ]]
}

@test "serve exits 1 when the control plane does not list the service" {
  _prep
  STUB_CAP=0 _run serve
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: service-not-advertised:"*"openseo.md#service-not-advertised"* ]]
}

@test "serve waits for the control plane to list the service before it gives up" {
  _prep
  STUB_CAP_AFTER=4 OPENSEO_ADVERTISE_WAIT=5 _run serve
  [ "$status" -eq 0 ]
  [[ "$output" == *"bound: https://openseo.tail-test.ts.net"* ]]
}

@test "serve exits 1 with bind-failed when tailscale refuses the binding" {
  _prep
  STUB_SERVE_FAIL=1 _run serve
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: bind-failed:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
  [[ "$output" != *"bound: https"* ]]
}

@test "serve exits 1 with unbind-failed when no account exists, a binding stands, and it will not turn off" {
  _prep
  STUB_FIRST=true STUB_BOUND=1 STUB_OFF_FAIL=1 _run serve
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unbind-failed:"*"cause: serve: cannot turn it off"*"fix: tailscale serve --service=svc:openseo --https=443 off"* ]]
}

@test "serve treats a serve config it cannot read as bound when no account exists, and tries to turn it off" {
  _prep
  STUB_FIRST=true STUB_STATUS_FAIL=1 _run serve
  [ "$status" -eq 0 ]
  grep -qF 'tailscale serve --service=svc:openseo --https=443 off' "$CALLS"
}

@test "serve names the endpoint when sign-up-status gives no usable answer" {
  _prep
  STUB_FIRST=null _run serve
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unhealthy:"*"/api/sign-up-status"*"nothing usable"* ]]
  _not_served
}

@test "create-admin sends the password on stdin only, then binds and prints the address, item, and next step" {
  _prep
  STUB_FIRST=true _run create-admin
  [ "$status" -eq 0 ]
  [ "$(cat "$STDIN_FILE")" = STUBSECRET_admin_pw_0123 ]
  grep -qF 'docker compose exec -T runtime node /opt/standalone/admin.mjs create-user admin@openseo.test OpenSEO' "$CALLS"
  _no_leaks
  _served
  [[ "$output" == *"https://openseo.tail-test.ts.net"*"OpenSEO - Admin Login (openseo)"*"anc.dev"* ]]
}

@test "create-admin refuses when an account exists, asks for a sign-in check, and names serve" {
  _prep
  _run create-admin
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: account-exists:"*"signing in at http://127.0.0.1:8946"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
  _never "docker compose exec"
}

@test "create-admin turns a standing binding off before it makes the account, and fails when it cannot" {
  _prep
  STUB_FIRST=true STUB_BOUND=1 _run create-admin
  [ "$status" -eq 0 ]
  [ "$(grep -nF 'tailscale serve --service=svc:openseo --https=443 off' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'docker compose exec' "$CALLS" | head -1 | cut -d: -f1)" ]
  : >"$CALLS"
  rm -f "$ACCOUNT"
  STUB_FIRST=true STUB_BOUND=1 STUB_OFF_FAIL=1 _run create-admin
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unbind-failed:"*"no account was made"* ]]
  _never "docker compose exec"
}

@test "create-admin reports upstream's failure and binds nothing" {
  _prep
  STUB_FIRST=true STUB_EXEC_FAIL=1 _run create-admin
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: create-admin-failed:"*"cause: Account command failed"*"docker compose logs runtime"* ]]
  _not_served
}

@test "no verb passes -v or --volumes to compose" {
  _run up
  STUB_FIRST=true _run create-admin
  _run down
  [ "$status" -eq 0 ]
  grep -q 'docker compose stop' "$CALLS"
  _no_volumes
}

@test "status passes with loopback, the service, the binding, and the address healthy, and never calls docker" {
  _prep
  STUB_BOUND=1 _run status
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: OpenSEO is up at https://openseo.tail-test.ts.net"* ]]
  _never "^docker"
}

@test "status names up for a stack that is down and serve for a service the control plane lacks" {
  _prep
  STUB_BOUND=1 STUB_HEALTH=down _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unhealthy:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh up"* ]]
  STUB_BOUND=1 STUB_CAP=0 _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: service-not-advertised:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
}

@test "status on a host with no local.env skips the loopback and service checks, even beside a nas.env" {
  mkdir -p "$OPENSEO_ENV_DIR"
  : >"$OPENSEO_ENV_DIR/nas.env"
  STUB_CAP=0 STUB_HEALTH=down _run status
  [ "$status" -eq 0 ]
  _never 127.0.0.1
}

@test "status from a host with no local.env fails with address-unreachable when the address refuses" {
  STUB_ADDR=down _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: address-unreachable:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
}

@test "status fails with bind-failed when the service is advertised but no binding stands" {
  _prep
  STUB_BOUND=0 _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: bind-failed:"*"no binding on this host"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
}

@test "status on the OpenSEO host passes with a NOTE when only its own address refuses" {
  _prep
  STUB_BOUND=1 STUB_ADDR=down _run status
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE: this host cannot reach its own service address"* ]]
}

@test "status with no account yet and the service bound says the first visitor could become administrator" {
  _prep
  STUB_FIRST=true STUB_BOUND=1 _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: first-account-open:"*"first visitor could become administrator"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
  _never "tailscale serve --service"
}

@test "status with no account yet and a serve config it cannot read does not call the service unbound" {
  _prep
  STUB_FIRST=true STUB_STATUS_FAIL=1 _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"is, or may still be, bound"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
}

@test "status names up, never an update verb, when the env file's image is not the pin's" {
  _prep
  sed -i 's|^OPENSEO_IMAGE=.*|OPENSEO_IMAGE=ghcr.io/every-app/open-seo-standalone@sha256:0000000000000000000000000000000000000000000000000000000000000000|' "$OPENSEO_ENV_DIR/local.env"
  STUB_BOUND=1 _run status
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE: the pin's image ghcr.io/every-app/open-seo-standalone:0 differs from this host's env file"*"apply it with: ~/dotfiles/scripts/openseo-deploy.sh up"* ]]
  [[ "$output" != *update* ]]
  STUB_BOUND=1 run --separate-stderr "$SCRIPT" status --output json
  [ "$status" -eq 0 ]
  jq -e '.notes | length == 1 and (.[0] | endswith("openseo-deploy.sh up") and (contains("update") | not))' <<<"$output"
  _run render --host nas
  [ "$status" -eq 0 ]
  sed -i 's|^OPENSEO_IMAGE=.*|OPENSEO_IMAGE=ghcr.io/every-app/open-seo-standalone@sha256:0000000000000000000000000000000000000000000000000000000000000000|' "$OPENSEO_ENV_DIR/nas.env"
  STUB_BOUND=1 _run status --host nas
  [ "$status" -eq 0 ]
  [[ "$output" == *"differs from the NAS's env file"*"apply it with: ~/dotfiles/scripts/openseo-deploy.sh --host nas up"* ]]
  [[ "$output" != *update* ]]
}

@test "status notes nothing about the image when the env file holds the pin's" {
  _prep
  STUB_BOUND=1 _run status
  [ "$status" -eq 0 ]
  [[ "$output" != *NOTE* ]]
}

@test "status --output json carries the global envelope and its exit_code matches the process" {
  _prep
  STUB_BOUND=1 run --separate-stderr "$SCRIPT" status --output json
  [ "$status" -eq 0 ]
  jq -e '.reason == "ok" and .exit_code == 0 and (.next_step | has("action", "command", "docs")) and (.checks | length == 4)' <<<"$output"
  STUB_BOUND=1 STUB_HEALTH=down run --separate-stderr "$SCRIPT" status --output json
  [ "$status" -eq 1 ]
  jq -e --argjson c "$status" '.reason == "unhealthy" and .exit_code == $c and .next_step.action == "ask-operator" and (.next_step.command | endswith("openseo-deploy.sh up")) and (.message | length > 0) and (.checks[-1] | .ok == false and .name == "unhealthy")' <<<"$output"
}

@test "an error only a person can resolve carries no command in the JSON envelope" {
  _prep
  { cat "$PIN"; echo 'mystery value'; } >"$BATS_TEST_TMPDIR/variant.pin"
  run --separate-stderr bash -c 'source "$1/errors.sh"; source "$1/pin.sh"; OS_OUTPUT=json; pin_load "$2"' _ "$LIB" "$BATS_TEST_TMPDIR/variant.pin"
  [ "$status" -eq 1 ]
  jq -e '.reason == "pin-invalid" and .next_step.action == "supply-input" and .next_step.command == null' <<<"$output"
}

@test "without jq the JSON mode still prints a fixed object, and a tool outside Homebrew is not told to brew install" {
  run --separate-stderr bash -c 'source "$1/errors.sh"; command() { return 1; }; OS_OUTPUT=json; os_need jq' _ "$LIB"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')" = tool-missing ]
  run bash -c 'source "$1/errors.sh"; command() { return 1; }; os_need docker' _ "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: tool-missing: docker"*"fix: install docker as BOOTSTRAP.md describes"* ]]
}

@test "--help exits 0, names every verb, and marks the docker verbs; an unknown verb exits 2 and points at --help" {
  _run --help
  [ "$status" -eq 0 ]
  for verb in render up down serve status create-admin; do [[ "$output" == *"  $verb "* ]]; done
  [[ "$output" == *"up"*"[operator: docker]"* ]]
  [[ "$output" == *"  --host nas "* ]]
  _run frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: usage:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --help"* ]]
  run --separate-stderr "$SCRIPT" frobnicate --output json
  jq -e '.reason == "usage" and .exit_code == 2 and .value == "frobnicate"' <<<"$output"
}

@test "--output json is refused for the operator verbs" {
  _run up --output json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"reason": "usage"'* && "$output" == *'"value": "up"'* ]]
}

@test "render --host nas writes nas.env beside no local.env, with the same keys and mode" {
  _run render --host nas
  [ "$status" -eq 0 ]
  [ ! -e "$OPENSEO_ENV_DIR/local.env" ]
  [ "$(stat -c %a "$OPENSEO_ENV_DIR/nas.env")" = 600 ]
  grep -qx 'PORT=8946' "$OPENSEO_ENV_DIR/nas.env"
  grep -qx 'BETTER_AUTH_URL=https://openseo.tail-test.ts.net' "$OPENSEO_ENV_DIR/nas.env"
  _no_leaks
}

@test "up --host nas writes the Compose Manager stack, starts it with the plugin's compose.sh, and binds through ssh" {
  _run --host nas up
  [ "$status" -eq 0 ]
  [ "$(_nas_compose_calls)" -eq 1 ]
  grep -q '^docker compose -p openseo logs --no-color --no-log-prefix init$' "$CALLS"
  _never "^docker compose (pull|up|stop)"
  [[ "$output" == *"docker compose -p openseo logs -f init"* ]]
  [ "$(_ssh_calls | head -1)" = "ssh -n -o BatchMode=yes -o ConnectTimeout=10 -- pool test -x $COMPOSE_SH || { echo \"Compose Manager plugin not installed: $COMPOSE_SH\" >&2; exit 1; }; docker version && curl --version && tailscale version" ]
  [[ "$output" == *"==> wrote the stack folder $STACK on the NAS"* ]]
  [ "$(cat "$STACK/name")" = OpenSEO ]
  [ "$(cat "$STACK/project_name")" = openseo ]
  [ "$(cat "$STACK/autostart")" = true ]
  [ -s "$STACK/description" ]
  [ "$(cat "$STACK/icon_url")" = https://raw.githubusercontent.com/every-app/open-seo/505d4859622c02175e203e528c1669fdf10dcfe4/src/public/apple-touch-icon.png ]
  [ "$(cat "$STACK/webui_url")" = https://openseo.tail-test.ts.net/ ]
  cmp "$COMPOSE" "$STACK/compose.yaml"
  sed 's|@WEBUI_URL@|https://openseo.tail-test.ts.net/|' "$REPO_ROOT/config/openseo/compose.override.yaml" | cmp - "$STACK/compose.override.yaml"
  [ "$(_web_label "$STACK/compose.override.yaml")" = https://openseo.tail-test.ts.net/ ]
  [ "$(grep -c 'net.unraid.docker.webui: ""' "$STACK/compose.override.yaml")" -eq 4 ]
  cmp "$OPENSEO_ENV_DIR/nas.env" "$STACK/.env"
  [ "$(stat -c %a "$STACK/.env")" = 600 ]
  grep -qx "compose.sh -cup --recreate -popenseo -f$STACK/compose.yaml -f$STACK/compose.override.yaml -e$STACK/.env -s$STACK" "$CALLS"
  _no_leaks
  _ssh_calls | grep -q -- "-- pool tailscale serve --service=svc:openseo --https=443 --yes http://127.0.0.1:8946"
  _ssh_calls | grep -q -- "-- pool curl .*http://127.0.0.1:8946/api/health"
  [ ! -e "$OPENSEO_ENV_DIR/local.env" ]
}

@test "the override labels every service compose.yaml defines as Compose Manager's" {
  services() { awk '/^services:/ { in_s = 1; next } /^[^ #]/ { in_s = 0 } in_s && /^  [a-z][a-z-]*:/ { sub(":.*", ""); gsub(" ", ""); print }' "$1"; }
  override="$REPO_ROOT/config/openseo/compose.override.yaml"
  [ -n "$(services "$COMPOSE")" ]
  [ "$(services "$override")" = "$(services "$COMPOSE")" ]
  [ "$(grep -c 'net.unraid.docker.managed: composeman' "$override")" -eq "$(services "$COMPOSE" | wc -l)" ]
}

@test "the tracked override holds the address placeholder in web only, never a tailnet name" {
  override="$REPO_ROOT/config/openseo/compose.override.yaml"
  [ "$(grep -c '@WEBUI_URL@' "$override")" -eq 1 ]
  [ "$(_web_label "$override")" = @WEBUI_URL@ ]
  run ! grep -qE 'ts\.net|https?://' "$override"
}

@test "up --host nas keeps a folder's metadata and the dashboard's files, and replaces only the three stack files" {
  mkdir -p "$STACK"
  for f in name project_name description autostart icon_url webui_url last_result.json; do printf 'dashboard-%s' "$f" >"$STACK/$f"; done
  printf old >"$STACK/compose.yaml"
  printf old >"$STACK/.env"
  chmod 644 "$STACK/.env"
  _run up --host nas
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$STACK/.env")" = 600 ]
  [ -z "$(find "$STACK" -name '*.new')" ]
  for f in name project_name description autostart icon_url webui_url last_result.json; do [ "$(cat "$STACK/$f")" = "dashboard-$f" ]; done
  cmp "$COMPOSE" "$STACK/compose.yaml"
  [ "$(_web_label "$STACK/compose.override.yaml")" = https://openseo.tail-test.ts.net/ ]
  cmp "$OPENSEO_ENV_DIR/nas.env" "$STACK/.env"
}

@test "up --host nas puts the stack under PROJECTS_FOLDER from the plugin's config, quoted or not" {
  cfg="$NAS_ROOT/boot/config/plugins/compose.manager/compose.manager.cfg"
  mkdir -p "${cfg%/*}"
  printf 'OTHER="x"\nPROJECTS_FOLDER="%s/quoted"\n' "$NAS_ROOT" >"$cfg"
  _run up --host nas
  [ "$status" -eq 0 ]
  [ -f "$NAS_ROOT/quoted/openseo/compose.yaml" ] && [ ! -e "$STACK" ]
  grep -q "^compose.sh -cup --recreate -popenseo -f$NAS_ROOT/quoted/openseo/compose.yaml " "$CALLS"
  printf 'PROJECTS_FOLDER=%s/bare\n' "$NAS_ROOT" >"$cfg"
  _run up --host nas
  [ -f "$NAS_ROOT/bare/openseo/.env" ]
}

@test "up --host nas names the failing step: stack-write-failed, up-failed, or init-failed" {
  _break_stack_dir
  _run up --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: stack-write-failed:"*"nothing was started"*"cause:"*'fix: ssh pool "grep PROJECTS_FOLDER /boot/config/plugins/compose.manager/compose.manager.cfg;'*"then ~/dotfiles/scripts/openseo-deploy.sh --host nas up"* ]]
  _never "^compose.sh"
  rm -f "${STACK%/*}"
  STUB_UP_FAIL=1 _run up --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: up-failed:"*"cause: up failed"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --host nas up"* ]]
  STUB_INIT=fail _run up --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: init-failed:"*"didn't complete successfully"*"docker compose -p openseo logs init"* ]]
  OPENSEO_INIT_TIMEOUT=1 STUB_INIT=hang _run up --host nas
  [[ "$output" == *"ERROR: init-failed: init did not complete within 1s"* ]]
  _not_served
}

@test "up and down --host nas without the plugin's compose.sh stop at the probe, before 1Password and the NAS's disk" {
  chmod -x "$NAS_ROOT/emhttp/plugins/compose.manager/scripts/compose.sh"
  for verb in up down; do
    : >"$CALLS"
    _run "$verb" --host nas
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: nas-unreachable:"*"test -x $COMPOSE_SH"*"cause: Compose Manager plugin not installed: "*"fix:"* ]]
    [ "$(wc -l <"$CALLS")" -eq 1 ]
  done
  [ ! -e "$STACK" ] && [ ! -e "$OPENSEO_ENV_DIR/nas.env" ]
  _run render --host nas
  [ "$status" -eq 0 ]
}

@test "down --host nas stops the stack with compose.sh and runs no docker compose stop" {
  _prep
  _run render --host nas
  : >"$CALLS"
  _run down --host nas
  [ "$status" -eq 0 ]
  grep -qx "compose.sh -cstop -popenseo -f$STACK/compose.yaml -f$STACK/compose.override.yaml -e$STACK/.env -s$STACK" "$CALLS"
  _never "^docker compose"
  STUB_STOP_FAIL=1 _run down --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: stop-failed:"*"cause: stop failed"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --host nas down"* ]]
}

@test "OPENSEO_NAS_SSH names another alias, and a value that is not a host alias is a usage error" {
  OPENSEO_NAS_SSH=nashost _run up --host nas
  [ "$status" -eq 0 ]
  [ "$(_nas_compose_calls nashost)" -eq 1 ]
  _ssh_calls | grep -q -- "-- nashost "
  STUB_HEALTH=issues OPENSEO_NAS_SSH=nashost _run serve --host nas
  [[ "$output" == *"fix: OPENSEO_NAS_SSH=nashost ~/dotfiles/scripts/openseo-deploy.sh --host nas up"* ]]
  OPENSEO_NAS_SSH='-oProxyCommand=x' _run up --host nas
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: usage:"*"OPENSEO_NAS_SSH"* ]]
  OPENSEO_NAS_SSH='-oProxyCommand=x' run --separate-stderr "$SCRIPT" status --host nas --output json
  [ "$status" -eq 2 ]
  jq -e '.reason == "usage" and .exit_code == 2 and (.message | contains("OPENSEO_NAS_SSH")) and .next_step.action == "supply-input" and .next_step.command == null' <<<"$output"
  _run up --host mars
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: usage:"*"--host takes nas"* ]]
}

@test "no verb but up writes on the NAS: ssh carries only tailscale, curl, docker, and compose.sh, always non-interactive" {
  _run render --host nas
  STUB_FIRST=true _run create-admin --host nas
  [ "$status" -eq 0 ]
  grep -q "^docker compose -p openseo exec -T runtime node /opt/standalone/admin.mjs create-user " "$CALLS"
  grep -q "^env COMPOSE_FILE=$COMPOSE COMPOSE_ENV_FILES=$OPENSEO_ENV_DIR/nas.env .*DOCKER_HOST=ssh://pool$" "$CALLS"
  [ "$(cat "$STDIN_FILE")" = STUBSECRET_admin_pw_0123 ]
  _run down --host nas
  [ "$status" -eq 0 ]
  _run serve --host nas
  [ "$status" -eq 0 ]
  STUB_BOUND=1 _run status --host nas
  [ "$status" -eq 0 ]
  [ "$(_nas_compose_calls)" -ge 1 ]
  for cmd in tailscale curl docker; do _ssh_calls | grep -q -- "-- pool $cmd "; done
  [ -z "$(find "$NAS_ROOT/boot" -type f)" ]
  _remote_only
  _ssh_only_allowed
}

@test "every --host nas verb exits 1 naming ssh pool when the NAS does not answer, and makes no further call" {
  for verb in render up down serve create-admin status; do
    : >"$CALLS"
    STUB_SSH_FAIL=1 _run "$verb" --host nas
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: nas-unreachable:"*"ssh pool"*"fix:"* ]]
    [ "$(wc -l <"$CALLS")" -eq 1 ]
  done
  : >"$CALLS"
  STUB_SSH_MISSING=curl _run serve --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: nas-unreachable:"*"cause: sh: 1: curl: not found"*"fix:"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
  STUB_SSH_FAIL=1 run --separate-stderr "$SCRIPT" status --host nas --output json
  jq -e '.reason == "nas-unreachable" and .exit_code == 1 and .next_step.action == "supply-input" and .next_step.command == null' <<<"$output"
}

@test "serve --host nas refuses when the NAS's gate fails, and a binding it cannot turn off names the ssh command" {
  _run render --host nas
  STUB_HEALTH=issues _run serve --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unhealthy:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --host nas up"* ]]
  [[ "$output" == *"answered http://127.0.0.1:8946/api/health on the NAS"* ]]
  _ssh_calls | grep -q -- "-- pool curl .*/api/health"
  _not_served
  STUB_CAP=0 _run serve --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: service-not-advertised:"*"does not list the NAS for it"*"approve the NAS"* ]]
  STUB_FIRST=true STUB_BOUND=1 STUB_OFF_FAIL=1 _run serve --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unbind-failed:"*"fix: ssh pool tailscale serve --service=svc:openseo --https=443 off"* ]]
  _remote_only
}

@test "status --host nas reads the NAS's loopback and binding over ssh and the address from this host" {
  _run render --host nas
  : >"$CALLS"
  STUB_BOUND=1 _run status --host nas
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: OpenSEO is up at https://openseo.tail-test.ts.net"* ]]
  [ "$(_ssh_calls | head -1)" = "ssh -n -o BatchMode=yes -o ConnectTimeout=10 -- pool curl --version && tailscale version" ]
  _never "^docker"
  _ssh_calls | grep -q -- "-- pool tailscale serve status --json"
  _ssh_calls | grep -q -- "-- pool tailscale status --json"
  grep -q '^curl https://openseo.tail-test.ts.net/api/health$' "$CALLS"
  [ "$(_ssh_calls | grep -c 'https://openseo' || true)" -eq 0 ]
  STUB_BOUND=0 _run status --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: bind-failed:"*"no binding on the NAS"* ]]
  STUB_BOUND=1 STUB_ADDR=down _run status --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: address-unreachable:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --host nas serve"* ]]
  STUB_BOUND=1 STUB_HEALTH=down _run status --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unhealthy:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --host nas up"* ]]
  _remote_only
}

@test "status --host nas without a nas.env still runs the NAS gate, and a bound NAS with no account fails" {
  STUB_FIRST=true STUB_BOUND=1 _run status --host nas
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: first-account-open:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --host nas serve"* ]]
  _ssh_calls | grep -q -- "-- pool curl .*/api/sign-up-status"
  _remote_only
}

@test "status with no local.env and a nas.env names the --host nas fix for a refused address" {
  mkdir -p "$OPENSEO_ENV_DIR"
  : >"$OPENSEO_ENV_DIR/nas.env"
  STUB_ADDR=down _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: address-unreachable:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --host nas serve"* ]]
  _never "^ssh "
}

@test "every error the suite can trigger has a reason from the closed set and ends with a fix: line" {
  reasons=$(bash -c 'source "$1/errors.sh"; echo $OS_REASONS' _ "$LIB")
  seen=
  _check() {
    local i first=-1
    [ "$status" -ne 0 ]
    for i in "${!lines[@]}"; do
      if [[ ${lines[$i]} == ERROR:* ]]; then first=$i; break; fi
    done
    [ "$first" -ge 0 ]
    [[ ${lines[$first]} =~ ^ERROR:\ ([a-z-]+): ]]
    [[ " $reasons " == *" ${BASH_REMATCH[1]} "* ]]
    [[ ${lines[${#lines[@]} - 1]} == fix:* ]]
    seen+=" ${BASH_REMATCH[1]}"
  }
  STUB_OP_FAIL=1 _run render; _check
  STUB_OS=Darwin _run render; _check
  _run frobnicate; _check
  _run serve; _check
  _prep
  STUB_STORAGE=STUBSECRET_other _run render; _check
  STUB_HEALTH=issues _run serve; _check
  STUB_CAP=0 _run serve; _check
  STUB_PULL_FAIL=1 _run up; _check
  STUB_SSH_FAIL=1 _run status --host nas; _check
  _break_stack_dir
  _run up --host nas; _check
  [ "$seen" = " item-unreadable unsupported-host usage env-missing storage-key-changed unhealthy service-not-advertised pull-failed nas-unreachable stack-write-failed" ]
}

@test "every reason has a heading in the runbook, and every verb it runs is in --help" {
  for reason in $(bash -c 'source "$1/errors.sh"; echo $OS_REASONS' _ "$LIB"); do
    grep -qx "### $reason" "$RUNBOOK"
  done
  _run --help
  while read -r verb; do
    [[ $verb == --help || "$output" == *"  $verb "* ]]
  done < <(grep -oE 'scripts/openseo-deploy\.sh [a-z-]+' "$RUNBOOK" | awk '{ print $2 }' | sort -u)
}
