# shellcheck shell=bash
# CAAM: transparent account rotation for Claude Code
# Prechecks usage before launching; auto-retries on rate limit for -p invocations
# On machines without caam, claude resolves to the real binary via PATH
if command -v caam >/dev/null 2>&1; then
    claude() {
        # Only wrap non-interactive invocations (-p flag) for auto-retry on rate limit.
        # Interactive sessions need direct TTY access — caam run breaks keystroke passthrough.
        case " $* " in
            *" -p "*) caam run claude -- "$@" ;;
            *)        command claude "$@" ;;
        esac
    }

    # Quick switch: rotate to best profile and launch interactive session
    claude-switch() { caam activate claude --auto && command claude "$@"; }

    # Auto-start daemon for proactive token refresh across all profiles
    # Daemon config: ~/.caam/config.yaml (auth_pool.enabled, check_interval, refresh_threshold)
    if ! caam daemon status 2>/dev/null | grep -q 'is running'; then
        caam daemon start >/dev/null 2>&1
    fi

    # Adopt caam config back into stow source (daemon may rewrite config.yaml, breaking symlink)
    stow --dotfiles --no-folding --target="$HOME" --dir="$HOME/dotfiles/stow" -R --adopt caam 2>/dev/null || true
fi
