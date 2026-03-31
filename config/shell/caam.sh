# CAAM: transparent account rotation for Claude Code
# Prechecks usage before launching; auto-retries on rate limit for -p invocations
# On machines without caam, claude resolves to the real binary via PATH
if command -v caam >/dev/null 2>&1; then
    claude() { caam run claude --precheck -- "$@"; }
fi
