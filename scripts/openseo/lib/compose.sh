# shellcheck disable=SC2034,SC2088 # the tilde stays literal; globals are shared through the script that sources this file

OS_INIT_TIMEOUT=${OPENSEO_INIT_TIMEOUT:-360}
OS_HEALTH_WAIT=${OPENSEO_HEALTH_WAIT:-15}
OS_READY_LINE='OpenSEO initialized and ready.'
OS_LOGS_CMD='COMPOSE_FILE=~/dotfiles/config/openseo/compose.yaml COMPOSE_ENV_FILES=~/.config/openseo/local.env docker compose logs init'
OS_WATCH_CMD=${OS_LOGS_CMD/logs init/logs -f init}

os_compose_env() {
  export COMPOSE_FILE="$OS_COMPOSE_FILE" COMPOSE_ENV_FILES="$OS_LOCAL_ENV"
}

# Compose lets an exported variable override the env file, so a shell that exports PORT, a provider key, or
# OPENSEO_IMAGE would reconfigure the stack silently. Every variable the vendored file interpolates, the project name,
# and the daemon selectors are unset for the call, and --host nas sets DOCKER_HOST; OS_TIMEOUT bounds it. Under --host
# nas the calls name the project of the NAS's Compose Manager stack.
os_compose() {
  local cmd=() v
  [ -z "${OS_TIMEOUT:-}" ] || cmd=(timeout "$OS_TIMEOUT")
  cmd+=(env)
  for v in $(grep -oE '\$\{[A-Z_]+' "$OS_COMPOSE_FILE" | sed 's/^\${//' | sort -u) \
    COMPOSE_PROJECT_NAME COMPOSE_PROFILES DOCKER_HOST DOCKER_CONTEXT; do
    cmd+=(-u "$v")
  done
  [ -z "$OS_DOCKER_HOST" ] || cmd+=("DOCKER_HOST=$OS_DOCKER_HOST")
  cmd+=(docker compose)
  [ -z "$OS_PROJECT" ] || cmd+=(-p "$OS_PROJECT")
  "${cmd[@]}" "$@"
}

# A start returns only once init has exited 0, because web and crawl-gateway wait for it to complete, so the wait and its
# bound belong to the call. Following an exited container's log never ends, so the ready line is read as a snapshot.
os_up_step() {
  local rc=0
  OS_TIMEOUT=$OS_INIT_TIMEOUT os_try "$@" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 124 ] || [[ $OS_CAUSE == *"didn't complete successfully"* ]]; then
    os_fail init-failed "init did not complete within ${OS_INIT_TIMEOUT}s; the stack is partly started; safe to rerun once the cause is fixed" "$OS_LOGS_CMD"
  fi
  os_fail up-failed "the stack start failed; the stack may be partly started; safe to rerun" "$OS_DEPLOY up"
}

os_wait_init() {
  local out rc=0
  out=$(OS_TIMEOUT=60 os_compose logs --no-color --no-log-prefix init 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || [[ $out != *"$OS_READY_LINE"* ]]; then
    OS_CAUSE=$(tail -n 5 <<<"$out" | cut -c1-200)
    os_fail init-failed "init ended without its ready line; the stack is started but not initialized; safe to rerun once the cause is fixed" "$OS_LOGS_CMD"
  fi
  echo "==> init finished: $OS_READY_LINE"
}

os_wait_health() {
  local i
  for ((i = 0; i < OS_HEALTH_WAIT; i++)); do
    os_health "$OS_LOOPBACK"
    [ "$OS_HEALTH" != ok ] || return 0
    sleep 2
  done
}

os_up() {
  local image
  os_render
  os_need docker curl
  os_compose_env
  if [ "$OS_HOST" = nas ]; then
    echo "==> writing the Compose Manager stack $OS_STACK on the NAS"
    os_stack_write
  else
    image=$(os_env_get "$OS_LOCAL_ENV" OPENSEO_IMAGE)
    echo "==> pulling ${image##*/} (about 115 MiB)"
    os_try os_compose pull || os_fail pull-failed "docker compose pull failed for $(os_mask "$image"); nothing was started; safe to rerun" "$OS_DEPLOY up" "$image"
  fi
  os_unbind || os_unbind_failed "nothing was started; safe to rerun"
  echo "==> starting the stack with $OS_SERVICE unbound; init runs first, about 2 minutes, $OS_INIT_RUNS; to watch: $OS_WATCH_CMD"
  if [ "$OS_HOST" = nas ]; then
    os_up_step os_stack up --recreate
  else
    os_up_step os_compose up -d
    os_up_step os_compose up -d --force-recreate init web crawl-gateway
  fi
  os_wait_init
  os_wait_health
  os_serve
}

os_down() {
  os_require_env
  os_need docker
  os_compose_env
  if [ "$OS_HOST" = nas ]; then
    os_try os_stack stop
  else
    os_try os_compose stop
  fi || os_fail stop-failed "the stack stop failed; safe to rerun" "$OS_DEPLOY down"
  echo "==> stopped; the volumes and the generated secrets are untouched"
}

# The first account is made from the host, through upstream's operator command, so the address can stay unbound until
# an administrator exists.
os_create_admin() {
  local email password
  os_require_env
  os_need docker curl jq tailscale
  os_compose_env
  os_gate || :
  case "$OS_GATE" in
    unhealthy) os_unhealthy "no account was made; safe to rerun" ;;
    unbind-failed) os_unbind_failed "no account was made; safe to rerun" ;;
    ok) os_fail account-exists "OpenSEO already has an account, and create-admin makes only the first; before serve, confirm the account is yours by signing in at ${OS_SIGNIN_AT:-$OS_LOOPBACK} with the admin item; nothing changed" "$OS_DEPLOY serve" ;;
  esac
  os_item "$OS_ADMIN_ITEM" "OpenSEO - Admin Login (openseo)" username email
  os_item "$OS_ADMIN_ITEM" "OpenSEO - Admin Login (openseo)" password password
  os_try os_compose exec -T runtime node /opt/standalone/admin.mjs create-user "$email" OpenSEO <<<"$password" \
    || os_fail create-admin-failed "upstream's operator command failed; no account is known to exist; safe to rerun" \
      "${OS_LOGS_CMD% init} runtime"
  os_serve
  if [ "$OS_BOUND" = 1 ]; then
    echo "==> OpenSEO is at $(os_env_get "$OS_LOCAL_ENV" BETTER_AUTH_URL); sign in with 1Password item OpenSEO - Admin Login (openseo), then create the project anc.dev (docs/runbooks/openseo.md#first-read-only-run)"
  fi
}
