# The NAS target (--host nas): the stack is the NAS's Compose Manager stack (scripts/openseo/lib/stack.sh), which `up`
# writes and the plugin starts; reads of the running stack use compose here against the NAS's Docker daemon through
# DOCKER_HOST=ssh://, with the env file kept here, and the loopback checks and tailscale serve run on the NAS through ssh.
# shellcheck disable=SC2034,SC2088 # globals are shared through the script that sources this file; the tilde stays literal

OS_HOST=local OS_DOCKER_HOST='' OS_SIGNIN_AT='' OS_PROJECT='' OS_INIT_RUNS=twice
OS_NAS_ENV=$OS_ENV_DIR/nas.env
OS_NAS_SSH=${OPENSEO_NAS_SSH:-pool}

OS_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

os_nas_ssh() {
  local cmd=()
  [ -z "${OS_TIMEOUT:-}" ] || cmd=(timeout "$OS_TIMEOUT")
  cmd+=(ssh -n "${OS_SSH_OPTS[@]}" -- "$OS_NAS_SSH")
  "${cmd[@]}" "$@"
}

os_nas_ssh_in() {
  ssh "${OS_SSH_OPTS[@]}" -- "$OS_NAS_SSH" "$@"
}

os_use_host() {
  [ "$1" = nas ] || os_fail usage "--host takes nas, the only target besides this host; got $(os_mask "$1")" "$OS_DEPLOY --help" "$1"
  [ "$OS_HOST" != nas ] || return 0
  OS_HOST=nas OS_DOCKER_HOST=ssh://$OS_NAS_SSH
  OS_LOCAL_ENV=$OS_NAS_ENV OS_ENV_SHOWN=${OS_LOCAL_ENV/#$HOME/\~}
  [ "$OS_NAS_SSH" = pool ] || OS_DEPLOY="OPENSEO_NAS_SSH=$(os_mask "$OS_NAS_SSH") $OS_DEPLOY"
  OS_DEPLOY="$OS_DEPLOY --host nas" OS_ON_HOST_PREFIX="ssh $OS_NAS_SSH " OS_WHERE='the NAS' OS_AT_NAS=' on the NAS'
  OS_PROJECT=$OS_STACK OS_INIT_RUNS=once
  OS_LOGS_CMD=${OS_LOGS_CMD/local.env/nas.env}
  OS_LOGS_CMD="DOCKER_HOST=$OS_DOCKER_HOST ${OS_LOGS_CMD/docker compose/docker compose -p $OS_STACK}"
  OS_WATCH_CMD=${OS_LOGS_CMD/logs init/logs -f init}
  OS_SIGNIN_AT="$OS_LOOPBACK on the NAS (ssh -L $OS_PORT:127.0.0.1:$OS_PORT $OS_NAS_SSH)"
}

# One ssh call that runs every tool the verb will run there, so a missing tool or plugin is named before anything is read
# or started. status runs no docker, so it checks none; up and down run the plugin's compose.sh. The alias is a ssh
# destination and part of DOCKER_HOST, so a value ssh could read as an option is refused; that check waits for here,
# after --output is known.
os_nas_preflight() {
  local probe='curl --version && tailscale version'
  [[ $OS_NAS_SSH =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] \
    || os_fail_input usage "OPENSEO_NAS_SSH must be an ssh host alias, not $(os_mask "$OS_NAS_SSH")" "unset OPENSEO_NAS_SSH, or set it to the alias in ~/.ssh/config" "$OS_NAS_SSH"
  [ "$1" = status ] || probe="docker version && $probe"
  case "$1" in up | down) probe="test -x $OS_COMPOSE_SH || { echo \"Compose Manager plugin not installed: $OS_COMPOSE_SH\" >&2; exit 1; }; $probe" ;; esac
  os_need ssh
  os_try os_nas_ssh "$probe" >/dev/null \
    || os_fail_input nas-unreachable "the NAS did not answer ssh $OS_NAS_SSH '$probe'; nothing was changed; safe to rerun" \
      "make ssh $OS_NAS_SSH '$probe' succeed from this host" "$OS_NAS_SSH"
}
