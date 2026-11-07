#!/usr/bin/env bats
# scripts/openseo-deploy.sh runs OpenSEO's Docker stack on the Linux server and binds it to svc:openseo. The suite
# stubs docker, tailscale, curl, and the 1Password read, so it runs no container, binds nothing, and reads no secret.
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

setup_file() {
  load lib/platform
  require_linux "the script uses GNU timeout, stat, and sha256sum, and refuses to run elsewhere"
}

_stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS/op"
  export CALLS="$BATS_TEST_TMPDIR/calls.log" ACCOUNT="$BATS_TEST_TMPDIR/account" STDIN_FILE="$BATS_TEST_TMPDIR/stdin"
  export OPENSEO_ENV_DIR="$BATS_TEST_TMPDIR/cfg/openseo" OP_SKILL="$STUBS/op"
  export STUB_HEALTH=ok STUB_FIRST=false STUB_ADDR=ok STUB_CAP=1 STUB_BOUND=0
  _stub uname 'if [ -n "${STUB_OS:-}" ]; then echo "$STUB_OS"; else command -p uname "$@"; fi'
  _stub op/read_field.sh 'echo "read_field $*" >>"$CALLS"
  [ "${STUB_OP_FAIL:-}" != 1 ] || exit 1
  case "$1:$2" in
    '$STORAGE_ITEM':password) printf "%s" "${STUB_STORAGE:-STUBSECRET_storage_0123456789}" ;;
    '$ADMIN_ITEM':username) printf "admin@openseo.test" ;;
    '$ADMIN_ITEM':password) printf "STUBSECRET_admin_pw_0123" ;;
    dfs-item:credential) printf "STUBSECRET_dfs_credential==" ;;
    google-item:client_id) printf "stub-client-id.apps.test" ;;
    google-item:client_secret) printf "STUBSECRET_google_secret" ;;
    *) exit 1 ;;
  esac'
  _stub tailscale 'echo "tailscale $*" >>"$CALLS"
  if [ "$1 $2" = "status --json" ]; then
    [ "${STUB_TS_FAIL:-}" != 1 ] || exit 1
    cap=""; [ "$STUB_CAP" = 1 ] && cap=",{\"svc:openseo\":[\"100.64.0.9\"]}"
    echo "{\"MagicDNSSuffix\":\"tail-test.ts.net\",\"Self\":{\"CapMap\":{\"service-host\":[{\"svc:ollama\":[\"100.64.0.1\"]}$cap]}}}"
  fi
  [ "$1 $2" = "serve status" ] && [ "$STUB_BOUND" = 1 ] && echo "{\"Services\":{\"svc:openseo\":{}}}"
  exit 0'
  _stub curl 'echo "curl ${*: -1}" >>"$CALLS"
  first=$STUB_FIRST; [ ! -e "$ACCOUNT" ] || first=false
  case "${*: -1}" in
    http://127.0.0.1:8946/api/health) [ "$STUB_HEALTH" != down ] || exit 22; echo "{\"status\":\"$STUB_HEALTH\"}" ;;
    http://127.0.0.1:8946/api/sign-up-status) echo "{\"firstAccount\":$first}" ;;
    https://openseo.tail-test.ts.net/api/health) [ "$STUB_ADDR" = ok ] || exit 22; echo "{\"status\":\"ok\"}" ;;
  esac'
  _stub docker 'echo "docker $*" >>"$CALLS"
  echo "env COMPOSE_FILE=${COMPOSE_FILE-unset} COMPOSE_ENV_FILES=${COMPOSE_ENV_FILES-unset} PORT=${PORT-unset} OPENSEO_IMAGE=${OPENSEO_IMAGE-unset} OPENROUTER_API_KEY=${OPENROUTER_API_KEY-unset} COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME-unset} DOCKER_HOST=${DOCKER_HOST-unset}" >>"$CALLS"
  case "$2" in
    pull) [ "${STUB_PULL_FAIL:-}" != 1 ] || { echo "pull access denied" >&2; exit 1; } ;;
    up) [ "${STUB_UP_FAIL:-}" != 1 ] || { echo "up failed" >&2; exit 1; } ;;
    logs)
      [ "${STUB_INIT:-ok}" != hang ] || exec sleep 30
      if [ "${STUB_INIT:-ok}" = ok ]; then echo "OpenSEO initialized and ready."; else echo "Runtime did not start"; fi ;;
    exec)
      cat >"$STDIN_FILE"
      [ "${STUB_EXEC_FAIL:-}" != 1 ] || { echo "Account command failed; check the server logs" >&2; exit 1; }
      : >"$ACCOUNT" ;;
  esac'
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
_pin_variant() { sed "$1" "$PIN" >"$BATS_TEST_TMPDIR/variant.pin"; }
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
  image=$(awk '$1 == "image" { print $2 }' "$PIN")
  run env COMPOSE_FILE="$COMPOSE" STORAGE_ACCESS_KEY=a STORAGE_SECRET_KEY=b OPENSEO_IMAGE="$image" docker compose config --format json
  [ "$status" -eq 0 ]
  jq -e --arg i "$image" '[.services.runtime.image, .services.init.image, .services["crawl-gateway"].image] | all(. == $i)' <<<"$output"
  jq -e '[.services[].ports[]?.host_ip] | all(. == "127.0.0.1")' <<<"$output"
}

@test "the pin parser accepts the committed pin and prints its image" {
  _load_pin "$PIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(awk '$1 == "image" { print $2 }' "$PIN")" ]
}

@test "the pin parser rejects a tag-only image, a short digest, and an unknown key, naming the line" {
  _pin_variant 's/@sha256:[0-9a-f]*/:v0.1.25/'
  _load_pin "$BATS_TEST_TMPDIR/variant.pin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pin-invalid:"*"image at line "* ]]
  _pin_variant 's/\(image .*@sha256:\)[0-9a-f]\{64\}/\1abc123/'
  _load_pin "$BATS_TEST_TMPDIR/variant.pin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pin-invalid:"*"image at line "* ]]
  { cat "$PIN"; echo 'mystery value'; } >"$BATS_TEST_TMPDIR/variant.pin"
  _load_pin "$BATS_TEST_TMPDIR/variant.pin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pin-invalid:"*" at line "* ]]
}

@test "a compose file that differs from the pin's checksum is refused" {
  { cat "$COMPOSE"; echo '# hand edit'; } >"$BATS_TEST_TMPDIR/compose.yaml"
  run bash -c 'source "$1/errors.sh"; source "$1/pin.sh"; pin_load "$2"; pin_verify "$3"' _ "$LIB" "$PIN" "$BATS_TEST_TMPDIR/compose.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: pin-mismatch:"*"fix: git checkout -- config/openseo/compose.yaml"* ]]
}

@test "render writes a mode-600 env file in a mode-700 directory with every key and the tailnet address" {
  _run render
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$OPENSEO_ENV_DIR")" = 700 ]
  [ "$(stat -c %a "$OPENSEO_ENV_DIR/local.env")" = 600 ]
  for key in AUTH_MODE PORT STORAGE_ACCESS_KEY STORAGE_SECRET_KEY BETTER_AUTH_URL OPENSEO_IMAGE DATAFORSEO_API_KEY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET; do
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

@test "render writes the DataForSEO key and the Google client when their items are configured" {
  OPENSEO_DATAFORSEO_ITEM=dfs-item OPENSEO_GOOGLE_ITEM=google-item _run render
  [ "$status" -eq 0 ]
  grep -qx 'DATAFORSEO_API_KEY=STUBSECRET_dfs_credential==' "$OPENSEO_ENV_DIR/local.env"
  grep -qx 'GOOGLE_CLIENT_ID=stub-client-id.apps.test' "$OPENSEO_ENV_DIR/local.env"
  grep -qx 'GOOGLE_CLIENT_SECRET=STUBSECRET_google_secret' "$OPENSEO_ENV_DIR/local.env"
}

@test "render with no DataForSEO item leaves the key empty and says how to add it" {
  _run render
  [ "$status" -eq 0 ]
  grep -qx 'DATAFORSEO_API_KEY=' "$OPENSEO_ENV_DIR/local.env"
  [[ "$output" == *"NOTE: DATAFORSEO_API_KEY renders empty"* ]]
}

@test "render keeps the env file's image when the pin has moved on" {
  _prep
  sed -i 's|^OPENSEO_IMAGE=.*|OPENSEO_IMAGE=ghcr.io/every-app/open-seo-standalone@sha256:0000000000000000000000000000000000000000000000000000000000000000|' "$OPENSEO_ENV_DIR/local.env"
  _run render
  [ "$status" -eq 0 ]
  grep -q '^OPENSEO_IMAGE=.*@sha256:0\{64\}$' "$OPENSEO_ENV_DIR/local.env"
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
  [[ "$output" == *"ERROR: tailscale-unavailable:"*"tailscale status --json"* ]]
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
  [[ "$output" == *"ERROR: pull-failed:"*"open-seo-standalone@sha256:"*"cause: pull access denied"* ]]
  _never "docker compose up"
}

@test "up with a failing init exits 1 and prints the logs command" {
  STUB_INIT=fail _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: init-failed:"*"cause: Runtime did not start"*"fix: COMPOSE_FILE="*"docker compose logs init"* ]]
  _not_served
}

@test "up gives up on an init that never finishes" {
  OPENSEO_INIT_TIMEOUT=1 STUB_INIT=hang _run up
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: init-failed: init did not finish within 1s"* ]]
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

@test "create-admin refuses when an account exists and names serve" {
  _prep
  _run create-admin
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: account-exists:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
  _never "docker compose exec"
}

@test "create-admin reports upstream's failure and binds nothing" {
  _prep
  STUB_FIRST=true STUB_EXEC_FAIL=1 _run create-admin
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: create-admin-failed:"*"cause: Account command failed"* ]]
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

@test "status passes with loopback, the service, and the address healthy, and never calls docker" {
  _prep
  _run status
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: OpenSEO is up at https://openseo.tail-test.ts.net"* ]]
  _never "^docker"
}

@test "status names up for a stack that is down and serve for a service the control plane lacks" {
  _prep
  STUB_HEALTH=down _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: unhealthy:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh up"* ]]
  STUB_CAP=0 _run status
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

@test "status on the OpenSEO host passes with a NOTE when only its own address refuses" {
  _prep
  STUB_ADDR=down _run status
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE: this host cannot reach its own service address"* ]]
}

@test "status with no account yet and the service bound says the first visitor would become administrator" {
  _prep
  STUB_FIRST=true STUB_BOUND=1 _run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: first-account-open:"*"first visitor would become administrator"*"fix: ~/dotfiles/scripts/openseo-deploy.sh serve"* ]]
  _never "tailscale serve --service"
}

@test "status notes an update when the tracked pin differs from the host's image" {
  _prep
  sed -i 's|^OPENSEO_IMAGE=.*|OPENSEO_IMAGE=ghcr.io/every-app/open-seo-standalone@sha256:0000000000000000000000000000000000000000000000000000000000000000|' "$OPENSEO_ENV_DIR/local.env"
  _run status
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE: the tracked pin v0.1.25 differs from this host's image; apply it with: ~/dotfiles/scripts/openseo-deploy.sh update"* ]]
}

@test "status --output json carries the global envelope and its exit_code matches the process" {
  _prep
  run --separate-stderr "$SCRIPT" status --output json
  [ "$status" -eq 0 ]
  jq -e '.reason == "ok" and .exit_code == 0 and (.next_step | has("action", "command", "docs")) and (.checks | length == 3)' <<<"$output"
  STUB_HEALTH=down run --separate-stderr "$SCRIPT" status --output json
  [ "$status" -eq 1 ]
  jq -e --argjson c "$status" '.reason == "unhealthy" and .exit_code == $c and .next_step.action == "run-command" and (.next_step.command | endswith("openseo-deploy.sh up")) and (.message | length > 0)' <<<"$output"
}

@test "--help exits 0, names every verb, and marks the docker verbs; an unknown verb exits 2 and points at --help" {
  _run --help
  [ "$status" -eq 0 ]
  for verb in render up down serve status create-admin; do [[ "$output" == *"  $verb "* ]]; done
  [[ "$output" == *"up"*"[operator: docker]"* ]]
  _run frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: usage:"*"fix: ~/dotfiles/scripts/openseo-deploy.sh --help"* ]]
  run --separate-stderr "$SCRIPT" frobnicate --output json
  jq -e '.reason == "usage" and .exit_code == 2 and .value == "frobnicate"' <<<"$output"
}

@test "--output json is refused for the operator verbs" {
  _run up --output json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"reason": "usage"'* ]]
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
  [ "$seen" = " item-unreadable unsupported-host usage env-missing storage-key-changed unhealthy service-not-advertised pull-failed" ]
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
