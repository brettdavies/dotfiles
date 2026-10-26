# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Configuration and tool paths shared by agent-slot and the Claude hooks that act on slots. Every path has an
# AGENT_SLOT_* override, which is how the tests point it at a sandbox; the defaults are listed in agent-slot's header.

# Usage: agent_slot_env <agent-slot directory>
# Pins PATH, resolves the tools once, and sets the AS_* configuration. Returns 1 when neither jaq nor jq is installed,
# since nothing can be read or written without one.
agent_slot_env() {
  local tool override
  AS_HOME=$1

  # The caller's PATH is never trusted: an SSH command, a Claude hook, and a cron job each hand over a different one.
  PATH="$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

  AGENT_SLOT_JQ=${AGENT_SLOT_JQ:-$(command -v jaq || command -v jq || true)}
  [[ -n $AGENT_SLOT_JQ ]] || return 1

  AS_ROOT=${AGENT_SLOT_ROOT:-$HOME/slots}
  AS_ROOT_REAL=$(realpath -m "$AS_ROOT")
  AS_DEV=${AGENT_SLOT_DEV:-$HOME/dev}
  AS_EXTRA_PRIMES=${AGENT_SLOT_EXTRA_PRIMES-$HOME/dotfiles}
  AS_STATE_DIR=${AGENT_SLOT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-slot}
  AS_LEDGER=$AS_STATE_DIR/ledger.jsonl
  AS_LOG_DIR=$AS_STATE_DIR/logs
  AS_TMUX_SOCKET=${AGENT_SLOT_TMUX_SOCKET:-agent-slots}
  AS_TMUX_CONF=${AGENT_SLOT_TMUX_CONF:-$HOME/.config/tmux/slots.conf}
  AS_SOLUTIONS=${AGENT_SLOT_SOLUTIONS:-$HOME/dev/solutions-docs}
  AS_GIT_CRYPT_KEY=${AGENT_SLOT_GIT_CRYPT_KEY:-$HOME/.config/git-crypt/key}
  AS_CLAUDE_STATE=${AGENT_SLOT_CLAUDE_STATE:-$HOME/.claude.json}
  AS_VERIFIED_VERSIONS=${AGENT_SLOT_VERIFIED_VERSIONS:-$AS_HOME/verified-versions}

  declare -gA AS_TOOL=() CONTRACT_TOOL_PATHS
  for tool in tmux claude gh git-crypt git flock timeout trash systemctl; do
    override=AGENT_SLOT_${tool^^}
    override=${override//-/_}
    AS_TOOL[$tool]=${!override:-$(command -v "$tool" || true)}
    [[ -x ${AS_TOOL[$tool]} ]] || AS_TOOL[$tool]=
    CONTRACT_TOOL_PATHS[$tool]=${AS_TOOL[$tool]:-$tool}
  done
  AS_TMUX=${AS_TOOL[tmux]}
  AS_CLAUDE=${AS_TOOL[claude]}
  AS_SYSTEMCTL=${AS_TOOL[systemctl]}

  CONTRACT_REPO=$AS_HOME
  CONTRACT_LOG_DIR=$AS_LOG_DIR
  CONTRACT_CONFIG=$(contract_json -n -c --arg root "$AS_ROOT" --arg dev "$AS_DEV" --arg state "$AS_STATE_DIR" \
    --arg conf "$AS_TMUX_CONF" --arg socket "$AS_TMUX_SOCKET" --arg solutions "$AS_SOLUTIONS" \
    '{slot_root: $root, dev_root: $dev, state_dir: $state, tmux_conf: $conf, tmux_socket: $socket,
      solutions: $solutions}')
}
