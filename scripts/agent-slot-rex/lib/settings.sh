# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# agent-slot-rex's settings: every default that names a host, a path, a socket, a unit, or a session, each read once
# from its AGENT_SLOT_REX_* override (the dispatcher's header lists them). The dispatcher sources this file before any
# other, and it reads the host's OS before it touches PATH.
#
# A Rex server started by systemd or by the login server's PAM session hands what it starts a PATH without Homebrew,
# where tmux, jq, jaq, and flock live on the Linux server, so the Homebrew bin moves to the front of PATH whenever it
# exists.

AR_OS=$(uname -s)

AR_SERVER=${AGENT_SLOT_REX_SERVER:-bigdaddy}
AR_CLIENT=${AGENT_SLOT_REX_CLIENT:-agent-slot-rex}

AR_SSH=${AGENT_SLOT_REX_SSH:-ssh}
AR_PS=${AGENT_SLOT_REX_PS:-ps}
AR_TMUX=${AGENT_SLOT_REX_TMUX:-tmux}
AR_SYSTEMCTL=${AGENT_SLOT_REX_SYSTEMCTL:-systemctl}
AR_AGENT_SLOT=${AGENT_SLOT_REX_AGENT_SLOT:-$HOME/.local/bin/agent-slot}
AR_REXURRECT=${AGENT_SLOT_REX_REXURRECT:-$HOME/.local/bin/rexurrect}
AR_SELF=${AGENT_SLOT_REX_SELF:-$HOME/.local/bin/agent-slot-rex}
# The Linux server's shell expands the tilde.
# shellcheck disable=SC2088
AR_REMOTE_SELF='~/.local/bin/agent-slot-rex'

AR_REX_PATHS=${AGENT_SLOT_REX_APP_PATHS-/usr/bin/rex}

case $AR_OS in
  Darwin) AR_HOMEBREW=${AGENT_SLOT_REX_HOMEBREW:-/opt/homebrew} ;;
  *) AR_HOMEBREW=${AGENT_SLOT_REX_HOMEBREW:-/home/linuxbrew/.linuxbrew} ;;
esac
if [[ -d $AR_HOMEBREW/bin ]]; then
  PATH=:$PATH:
  PATH=${PATH//:$AR_HOMEBREW\/bin:/:}
  PATH=${PATH#:}
  PATH=$AR_HOMEBREW/bin:${PATH%:}
fi

AR_STATE=${AGENT_SLOT_REX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-slot-rex}
AR_LOG_DIR=$AR_STATE/logs
AR_STARTUP_RECORD=$AR_STATE/startup.json
AR_VERIFIED=${AGENT_SLOT_REX_VERIFIED_VERSIONS:-$AR_HOME/../agent-slot/verified-versions}
# systemctl --user finds the user manager through XDG_RUNTIME_DIR, which a shell in a slot's tmux session lacks.
AR_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID}

AR_CONTROL=agent-slots
AR_TMUX_SOCKET=agent-slots
AR_REX_UNIT=rex-server.service
AR_LOGIN_UNIT=rex-login-server.service
AR_RECONCILE_TIMER=agent-slot-reconcile.timer
AR_TAB_NUMBERS_UNIT=rex-tab-numbers.service

AR_RETRY=${AGENT_SLOT_REX_RETRY_DELAY:-3}
AR_LOCK_WAIT=${AGENT_SLOT_REX_LOCK_WAIT:-300}
AR_RECONCILE_STALE=${AGENT_SLOT_REX_RECONCILE_STALE:-180}
# The start-up step's bounds: how long it waits for a Rex server that is still loading its config to answer, how long
# rexurrect's restore may run (its 30 s watch for a blank Rex.app session plus the restore), and the age past which a
# server with no start-up record is reconciled anyway.
AR_STARTUP_WAIT=${AGENT_SLOT_REX_STARTUP_WAIT:-120}
AR_REXURRECT_BOUND=${AGENT_SLOT_REX_REXURRECT_BOUND:-90}
AR_STARTUP_LIMIT=${AGENT_SLOT_REX_STARTUP_LIMIT:-300}
