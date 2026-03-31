# CAAM: transparent account rotation for Claude Code
# Prechecks usage before launching; auto-retries on rate limit for -p invocations
# On machines without caam, claude resolves to the real binary via PATH
if command -v caam >/dev/null 2>&1; then
    claude() { caam run claude --precheck -- "$@"; }

    # Auto-start daemon for proactive token refresh across all profiles
    # Daemon config: ~/.caam/config.yaml (auth_pool.enabled, check_interval, refresh_threshold)
    if ! caam daemon status 2>/dev/null | grep -q 'is running'; then
        caam daemon start >/dev/null 2>&1
    fi
fi
