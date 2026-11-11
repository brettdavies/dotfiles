# The NAS target (--host nas): compose runs here against the NAS's Docker daemon through DOCKER_HOST=ssh://, with the env
# file kept here, and the loopback checks and tailscale serve run on the NAS through ssh. Nothing is written on the NAS.
# shellcheck disable=SC2034,SC2088 # globals are shared through the script that sources this file; the tilde stays literal

OS_HOST=local OS_DOCKER_HOST='' OS_SIGNIN_AT=''
OS_NAS_ENV=$OS_ENV_DIR/nas.env
OS_NAS_SSH=${OPENSEO_NAS_SSH:-pool}

# The alias is a ssh destination and part of DOCKER_HOST, so a value that ssh could read as an option is refused.
os_nas_ssh() {
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 -- "$OS_NAS_SSH" "$@"
}

os_use_host() {
  [ "$1" = nas ] || os_fail usage "--host takes nas, the only target besides this host; got $(os_mask "$1")" "$OS_DEPLOY --help" "$1"
  [[ $OS_NAS_SSH =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] \
    || os_fail usage "OPENSEO_NAS_SSH must be an ssh host alias, not $(os_mask "$OS_NAS_SSH")" "unset OPENSEO_NAS_SSH, or set it to the alias in ~/.ssh/config" "$OS_NAS_SSH"
  [ "$OS_HOST" != nas ] || return 0
  OS_HOST=nas OS_DOCKER_HOST=ssh://$OS_NAS_SSH
  OS_LOCAL_ENV=$OS_NAS_ENV OS_ENV_SHOWN=${OS_LOCAL_ENV/#$HOME/\~}
  OS_DEPLOY="$OS_DEPLOY --host nas" OS_ON_HOST_PREFIX="ssh $OS_NAS_SSH "
  OS_LOGS_CMD="DOCKER_HOST=$OS_DOCKER_HOST ${OS_LOGS_CMD/local.env/nas.env}"
  OS_WATCH_CMD=${OS_LOGS_CMD/logs init/logs -f init}
  OS_SIGNIN_AT="$OS_LOOPBACK on the NAS (ssh -L $OS_PORT:127.0.0.1:$OS_PORT $OS_NAS_SSH)"
}

# One call that carries docker, so it proves the connection and the daemon before anything is read or started.
os_nas_preflight() {
  os_need ssh
  os_try os_nas_ssh docker version >/dev/null \
    || os_fail_input nas-unreachable "the NAS did not answer ssh $(os_mask "$OS_NAS_SSH") docker version; nothing was changed; safe to rerun" \
      "make ssh $OS_NAS_SSH docker version succeed from this host" "$OS_NAS_SSH"
}
