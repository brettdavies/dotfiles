# Supply-chain safety: only install packages published at least 7 days ago

# uv/uvx/uv run — native relative duration (v0.9.17+)
export UV_EXCLUDE_NEWER="7 days"

# npm — native relative age in days (v11.10.0+)
export npm_config_min_release_age=7

# pip — no relative duration support; compute date dynamically (v26.0+)
if command -v date >/dev/null 2>&1; then
    case "$(uname -s)" in
        Darwin) _sc_date=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ) ;;
        *)      _sc_date=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) ;;
    esac
    export PIP_UPLOADED_PRIOR_TO="$_sc_date"
    unset _sc_date
fi
