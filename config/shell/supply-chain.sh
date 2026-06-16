# shellcheck shell=bash
# Supply-chain safety: only install packages published at least _sc_days days ago.
#
# Change _sc_days below to adjust the window for every supported tool. Per-tool
# keys vary in accepted unit (days, minutes, hours, absolute timestamp);
# _sc_hours, _sc_minutes, and a derived date string are computed from _sc_days.
#
# bun — no env-var support; configured via stow/bun/dot-bunfig.toml (~/.bunfig.toml)
#
# npm and pnpm both consume the shared `npm_config_*` env-var namespace, but
# the release-age feature lives under different keys in each tool:
#   - npm  reads `min-release-age`        (npm 11.10.0+)
#   - pnpm reads `minimum-release-age`    (pnpm 10.16.0+)
# Neither is an alias for the other; both are current. Exporting both
# unconditionally makes npm warn ("Unknown env config 'minimum-release-age'.
# This will stop working in the next major version of npm.") and will hard-fail
# once npm 12 rejects unknown env configs. To avoid the cross-pollution, each
# export is gated on (a) the tool being installed and (b) for npm, the version
# supporting the feature.

_sc_days=7
_sc_hours=$(( _sc_days * 24 ))
_sc_minutes=$(( _sc_hours * 60 ))

# uv/uvx/uv run — native relative duration (v0.9.17+)
export UV_EXCLUDE_NEWER="${_sc_days} days"

# uv install-time malware check (preview, v0.11.16+). Every sync — uv add, uv
# sync, uv run, uvx, uv tool install — looks up the locked resolution against
# OSV's MAL advisories (OpenSSF malicious-packages) and aborts before any matched
# distribution's code runs. This COMPLEMENTS the cooldown above; it does not
# replace it. The check only catches malware that already has a public advisory,
# and most malicious uploads aren't advised until days after publication — the
# exact window UV_EXCLUDE_NEWER covers. Astral recommends running both
# (https://astral.sh/blog/uv-audit, footnote 3), so the cooldown stays at
# _sc_days regardless of this check.
#
# Fail-closed: if OSV is unreachable the sync errors ("Malware check failed due
# to an error from OSV"), even under --offline (the lookup isn't cached per
# resolution). Bypass a single invocation with `UV_MALWARE_CHECK=0`.
#
# Version-gated: the `malware-check` preview feature prints an "Unknown preview
# feature" warning on every command for uv < 0.11.16, so set it only when the
# running uv supports it. UV_PREVIEW_FEATURES silences the "experimental" warning
# the bare UV_MALWARE_CHECK=1 would emit; appended (not clobbered) to preserve
# any other preview features already enabled.
if command -v uv >/dev/null 2>&1; then
    _sc_uv_ver=$(uv --version 2>/dev/null)
    _sc_uv_ver=${_sc_uv_ver#uv }
    _sc_uv_ver=${_sc_uv_ver%% *}
    _sc_uv_major=${_sc_uv_ver%%.*}
    _sc_uv_rest=${_sc_uv_ver#*.}
    _sc_uv_minor=${_sc_uv_rest%%.*}
    _sc_uv_patch=${_sc_uv_rest#*.}
    _sc_uv_patch=${_sc_uv_patch%%[!0-9]*}
    if [ "${_sc_uv_major:-0}" -gt 0 ] \
       || [ "${_sc_uv_minor:-0}" -gt 11 ] \
       || { [ "${_sc_uv_minor:-0}" -eq 11 ] && [ "${_sc_uv_patch:-0}" -ge 16 ]; }; then
        export UV_MALWARE_CHECK=1
        case ",${UV_PREVIEW_FEATURES:-}," in
            *,malware-check,*) ;;
            *) export UV_PREVIEW_FEATURES="${UV_PREVIEW_FEATURES:+${UV_PREVIEW_FEATURES},}malware-check" ;;
        esac
    fi
    unset _sc_uv_ver _sc_uv_major _sc_uv_minor _sc_uv_rest _sc_uv_patch
fi

# npm — native relative age in days (v11.10.0+)
if command -v npm >/dev/null 2>&1; then
    _sc_npm_ver=$(npm --version 2>/dev/null)
    _sc_npm_major=${_sc_npm_ver%%.*}
    _sc_npm_rest=${_sc_npm_ver#*.}
    _sc_npm_minor=${_sc_npm_rest%%.*}
    if [ "${_sc_npm_major:-0}" -gt 11 ] \
       || { [ "${_sc_npm_major:-0}" -eq 11 ] && [ "${_sc_npm_minor:-0}" -ge 10 ]; }; then
        export npm_config_min_release_age="$_sc_days"
    fi
    unset _sc_npm_ver _sc_npm_major _sc_npm_minor _sc_npm_rest
fi

# pnpm — minimumReleaseAge in minutes (v10.16.0+); env var maps to .npmrc key
if command -v pnpm >/dev/null 2>&1; then
    export npm_config_minimum_release_age="$_sc_minutes"
fi

# yarn — npmMinimalAgeGate in time-string form (v4.6+)
export YARN_NPM_MINIMAL_AGE_GATE="${_sc_hours}h"

# pip — no relative duration support; compute date dynamically (v26.0+)
if command -v date >/dev/null 2>&1; then
    case "$(uname -s)" in
        Darwin) _sc_date=$(date -u -v-"${_sc_days}"d +%Y-%m-%dT%H:%M:%SZ) ;;
        *)      _sc_date=$(date -u -d "${_sc_days} days ago" +%Y-%m-%dT%H:%M:%SZ) ;;
    esac
    export PIP_UPLOADED_PRIOR_TO="$_sc_date"
    unset _sc_date
fi

# Bundler — native cooldown in days (v4.0.13+).
# Shell-time export covers interactive runs. Also write the global config so
# non-shell bundler invocations (cron, systemd units, GUI launchers) see it.
# A cheap grep on the YAML config skips the slow `bundle config set` shell-out
# (Ruby + Bundler startup) once the desired value is already persisted.
if command -v bundle >/dev/null 2>&1; then
    export BUNDLE_COOLDOWN="$_sc_days"
    _sc_bundle_config="${BUNDLE_USER_CONFIG:-${HOME}/.bundle/config}"
    if [ ! -f "$_sc_bundle_config" ] \
       || ! grep -Eq "^BUNDLE_COOLDOWN:[[:space:]]+[\"']?${_sc_days}[\"']?[[:space:]]*$" "$_sc_bundle_config"; then
        bundle config set --global cooldown "$_sc_days" >/dev/null 2>&1 || true
    fi
    unset _sc_bundle_config
fi

unset _sc_days _sc_hours _sc_minutes
