#!/usr/bin/env bats
# Verifies the supply-chain age gate configured in config/shell/supply-chain.sh.
#
# For each supported package manager that's installed on the host, this file:
#   1. Asserts the installed PM version supports the cooldown feature. On a
#      deployed dotfiles host (~/.profile is a symlink) a too-old version is
#      a hard failure with a remediation hint; off-host (fresh CI checkout)
#      it's a precondition skip — see
#      docs/solutions/conventions/bats-precondition-skips-for-deploy-dependent-tests-2026-05-15.md
#   2. Asserts the expected env var (or, for Bundler, the global config file)
#      is produced when `config/shell/supply-chain.sh` is sourced.
#   3. Probes the gate with a currently-installed dependency whose upstream
#      latest is within the cooldown window. Skips when no eligible candidate
#      exists (we never install a new tool just to test the gate).
#
# pnpm and yarn aren't installed on every host; those tests skip cleanly.
# pip's live-probe is omitted because the project's Claude Code policy denies
# `pip:*` invocations; the env-var assertion still runs.
#
# Run: bats tests/supply-chain-gate.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
SUPPLY_CHAIN_SH="$REPO_ROOT/config/shell/supply-chain.sh"
COOLDOWN_DAYS=7
MAX_CANDIDATE_PROBES=20

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Echo ISO-8601 cutoff timestamp (now - COOLDOWN_DAYS).
_cutoff_iso() {
    case "$(uname -s)" in
        Darwin) date -u -v-"${COOLDOWN_DAYS}"d +%Y-%m-%dT%H:%M:%SZ ;;
        *)      date -u -d "${COOLDOWN_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ ;;
    esac
}

# Echo 1 if version $1 >= version $2 under `sort -V`, else 0.
_ver_ge() {
    local lowest
    lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)
    [ "$lowest" = "$2" ] && echo 1 || echo 0
}

# Source supply-chain.sh in a clean bash subshell, echo the value of var $1.
_sourced_var() {
    bash -c "source '$SUPPLY_CHAIN_SH' >/dev/null 2>&1; printf '%s' \"\$${1}\""
}

# Echo upstream latest version + upload time for a pypi package as "ver|time".
# Empty on lookup failure. Always exits 0 so callers using $(...) don't trip
# `set -e` (bats sets `inherit_errexit`).
_pypi_latest() {
    local pkg="$1" info
    info=$(curl -fsS --max-time 10 "https://pypi.org/pypi/$pkg/json" 2>/dev/null) || return 0
    [ -z "$info" ] && return 0
    printf '%s' "$info" | jaq -r '.info.version as $v | "\($v)|\(.releases[$v][0].upload_time // "")"' 2>/dev/null || true
}

# Assert $name version $actual is at least $required. On a deployed dotfiles
# host (~/.profile symlink), fail loudly with $upgrade_hint; otherwise treat
# the version gap as a precondition skip — generic CI runners aren't the
# user's machine and aren't subject to the cooldown-version policy.
_require_version() {
    local actual="$1" required="$2" name="$3" upgrade_hint="$4"
    [ "$(_ver_ge "$actual" "$required")" -eq 1 ] && return 0
    [ -L "$HOME/.profile" ] || skip "$name $actual < $required (host not deployed; cooldown-version policy n/a)"
    echo "$name $actual does not support the cooldown feature (needs >= $required). $upgrade_hint"
    return 1
}

# ----------------------------------------------------------------------------
# uv
# ----------------------------------------------------------------------------

@test "uv: installed version supports UV_EXCLUDE_NEWER (>= 0.9.17)" {
    command -v uv >/dev/null 2>&1 || skip "uv not installed"
    _require_version "$(uv --version 2>/dev/null | awk '{print $2}')" "0.9.17" "uv" "brew upgrade uv"
}

@test "uv: supply-chain.sh exports UV_EXCLUDE_NEWER='7 days'" {
    command -v uv >/dev/null 2>&1 || skip "uv not installed"
    _require_version "$(uv --version 2>/dev/null | awk '{print $2}')" "0.9.17" "uv" "brew upgrade uv"
    local v
    v=$(_sourced_var UV_EXCLUDE_NEWER)
    [ "$v" = "${COOLDOWN_DAYS} days" ] || { echo "got: $v"; return 1; }
}

@test "uv: gate holds an in-window upstream release back on an installed tool" {
    command -v uv >/dev/null 2>&1 || skip "uv not installed"
    command -v curl >/dev/null 2>&1 || skip "curl not available"
    command -v jaq >/dev/null 2>&1 || skip "jaq not available"
    _require_version "$(uv --version 2>/dev/null | awk '{print $2}')" "0.9.17" "uv" "brew upgrade uv"

    local cutoff tools tool info ver upload candidate latest probed=0
    cutoff=$(_cutoff_iso)
    tools=$(uv tool list 2>/dev/null | awk '/^[A-Za-z0-9]/ {print $1}')
    [ -n "$tools" ] || skip "no uv tools installed; no candidates to probe"

    for tool in $tools; do
        probed=$((probed + 1))
        [ "$probed" -gt "$MAX_CANDIDATE_PROBES" ] && break
        info=$(_pypi_latest "$tool")
        [ -z "$info" ] && continue
        ver=${info%%|*}
        upload=${info##*|}
        [ -z "$upload" ] && continue
        if [ "$upload" \> "$cutoff" ]; then
            candidate="$tool"
            latest="$ver"
            break
        fi
    done

    [ -n "${candidate:-}" ] || skip "no uv tool has an upstream release inside the ${COOLDOWN_DAYS}-day window"
    echo "# uv candidate: $candidate latest=$latest cutoff=$cutoff" >&3

    local tmpdir resolved
    tmpdir=$(mktemp -d "$BATS_TEST_TMPDIR/gate-uv-XXXXXX")
    uv venv --quiet --seed "$tmpdir/.venv" >/dev/null 2>&1 || \
        { echo "uv venv setup failed"; return 1; }
    resolved=$(uv pip install --python "$tmpdir/.venv/bin/python" --dry-run "$candidate" 2>&1 \
        | awk -v p="$candidate" '$0 ~ "^ \\+ "p"==" {sub("^ \\+ "p"==", ""); sub("[[:space:]].*$", ""); print; exit}')

    [ -n "$resolved" ] || { echo "could not parse resolved version for $candidate"; return 1; }
    echo "# uv resolved: $candidate==$resolved (held back from $latest)" >&3
    [ "$resolved" != "$latest" ] || \
        { echo "uv gate ineffective: $candidate resolved to latest $latest"; return 1; }
}

# ----------------------------------------------------------------------------
# npm
# ----------------------------------------------------------------------------

@test "npm: installed version supports min-release-age (>= 11.10.0)" {
    command -v npm >/dev/null 2>&1 || skip "npm not installed"
    _require_version "$(npm --version 2>/dev/null)" "11.10.0" "npm" "brew upgrade node"
}

@test "npm: supply-chain.sh exports npm_config_min_release_age=7" {
    command -v npm >/dev/null 2>&1 || skip "npm not installed"
    _require_version "$(npm --version 2>/dev/null)" "11.10.0" "npm" "brew upgrade node"
    local v
    v=$(_sourced_var npm_config_min_release_age)
    [ "$v" = "$COOLDOWN_DAYS" ] || { echo "got: $v"; return 1; }
}

@test "npm: gate holds an in-window upstream release back on a globally-installed package" {
    command -v npm >/dev/null 2>&1 || skip "npm not installed"
    _require_version "$(npm --version 2>/dev/null)" "11.10.0" "npm" "brew upgrade node"

    local cutoff pkgs pkg published candidate latest probed=0
    cutoff=$(_cutoff_iso)
    pkgs=$(npm list -g --depth=0 --parseable 2>/dev/null \
        | awk -F/ 'NR>1 {print $NF}' \
        | grep -v '^$' || true)
    [ -n "$pkgs" ] || skip "no globally-installed npm packages"

    for pkg in $pkgs; do
        probed=$((probed + 1))
        [ "$probed" -gt "$MAX_CANDIDATE_PROBES" ] && break
        latest=$(npm view "$pkg" version 2>/dev/null || true)
        [ -z "$latest" ] && continue
        # time.modified bumps on any metadata change (deprecations, dist-tag
        # edits), not just a publish, so it picks packages whose latest is
        # already out of the window. Gate on the latest version's own publish
        # time, mirroring the uv probe, so the candidate is genuinely in-window.
        published=$(npm view "$pkg" time --json 2>/dev/null \
            | jaq -r --arg v "$latest" '.[$v] // ""' 2>/dev/null || true)
        [ -z "$published" ] && continue
        if [ "$published" \> "$cutoff" ]; then
            candidate="$pkg"
            break
        fi
    done

    [ -n "${candidate:-}" ] || skip "no globally-installed npm package has an upstream release inside the ${COOLDOWN_DAYS}-day window"
    echo "# npm candidate: $candidate latest=$latest cutoff=$cutoff" >&3

    local tmpdir resolved
    tmpdir=$(mktemp -d "$BATS_TEST_TMPDIR/gate-npm-XXXXXX")
    (
        cd "$tmpdir" || exit 1
        printf '{"name":"gate-test","version":"0.0.0","private":true}\n' > package.json
        npm install --dry-run --no-audit --no-fund "$candidate" 2>&1
    ) | awk -v p="$candidate" '$1 == "add" && $2 == p {print $3; exit}' > "$tmpdir/resolved.txt"
    resolved=$(cat "$tmpdir/resolved.txt" 2>/dev/null || true)

    [ -n "$resolved" ] || { echo "could not parse resolved version for $candidate"; return 1; }
    echo "# npm resolved: $candidate@$resolved (held back from $latest)" >&3
    [ "$resolved" != "$latest" ] || \
        { echo "npm gate ineffective: $candidate resolved to latest $latest"; return 1; }
}

# ----------------------------------------------------------------------------
# pnpm (skip if not installed)
# ----------------------------------------------------------------------------

@test "pnpm: installed version supports minimum-release-age (>= 10.16.0)" {
    command -v pnpm >/dev/null 2>&1 || skip "pnpm not installed"
    _require_version "$(pnpm --version 2>/dev/null)" "10.16.0" "pnpm" "Upgrade pnpm: bun add -g pnpm@latest"
}

@test "pnpm: supply-chain.sh exports npm_config_minimum_release_age in minutes" {
    command -v pnpm >/dev/null 2>&1 || skip "pnpm not installed"
    _require_version "$(pnpm --version 2>/dev/null)" "10.16.0" "pnpm" "Upgrade pnpm: bun add -g pnpm@latest"
    local v expected
    v=$(_sourced_var npm_config_minimum_release_age)
    expected=$(( COOLDOWN_DAYS * 24 * 60 ))
    [ "$v" = "$expected" ] || { echo "got: $v, expected: $expected"; return 1; }
}

# ----------------------------------------------------------------------------
# yarn (skip if not installed)
# ----------------------------------------------------------------------------

@test "yarn: installed version supports npmMinimalAgeGate (>= 4.6.0)" {
    command -v yarn >/dev/null 2>&1 || skip "yarn not installed"
    _require_version "$(yarn --version 2>/dev/null)" "4.6.0" "yarn" "Upgrade yarn: corepack prepare yarn@stable --activate"
}

@test "yarn: supply-chain.sh exports YARN_NPM_MINIMAL_AGE_GATE as hours" {
    command -v yarn >/dev/null 2>&1 || skip "yarn not installed"
    _require_version "$(yarn --version 2>/dev/null)" "4.6.0" "yarn" "Upgrade yarn: corepack prepare yarn@stable --activate"
    local v expected
    v=$(_sourced_var YARN_NPM_MINIMAL_AGE_GATE)
    expected="$(( COOLDOWN_DAYS * 24 ))h"
    [ "$v" = "$expected" ] || { echo "got: $v, expected: $expected"; return 1; }
}

# ----------------------------------------------------------------------------
# pip
# ----------------------------------------------------------------------------

@test "pip: installed version supports PIP_UPLOADED_PRIOR_TO (>= 26.0)" {
    local pip_cmd=""
    for c in pip3 pip; do
        if command -v "$c" >/dev/null 2>&1; then
            pip_cmd="$c"
            break
        fi
    done
    [ -n "$pip_cmd" ] || skip "pip not installed"
    _require_version "$("$pip_cmd" --version 2>/dev/null | awk '{print $2}')" "26.0" "$pip_cmd" "Upgrade pip: $pip_cmd install --upgrade pip"
}

@test "pip: supply-chain.sh exports PIP_UPLOADED_PRIOR_TO as ISO-8601 cutoff" {
    command -v date >/dev/null 2>&1 || skip "date not available"
    local v
    v=$(_sourced_var PIP_UPLOADED_PRIOR_TO)
    [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
        { echo "PIP_UPLOADED_PRIOR_TO=$v is not a valid ISO-8601 UTC timestamp"; return 1; }
}

# ----------------------------------------------------------------------------
# Bundler
# ----------------------------------------------------------------------------

@test "bundler: installed version supports cooldown (>= 4.0.13)" {
    command -v bundle >/dev/null 2>&1 || skip "bundler not installed"
    _require_version "$(bundle --version 2>/dev/null | awk '{print $NF}')" "4.0.13" "Bundler" "gem update --system && gem install bundler -v '>= 4.0.13'"
}

@test "bundler: supply-chain.sh exports BUNDLE_COOLDOWN=7" {
    command -v bundle >/dev/null 2>&1 || skip "bundler not installed"
    _require_version "$(bundle --version 2>/dev/null | awk '{print $NF}')" "4.0.13" "Bundler" "gem update --system && gem install bundler -v '>= 4.0.13'"
    local v
    v=$(_sourced_var BUNDLE_COOLDOWN)
    [ "$v" = "$COOLDOWN_DAYS" ] || { echo "got: $v"; return 1; }
}

@test "bundler: global config (~/.bundle/config) carries cooldown=7" {
    command -v bundle >/dev/null 2>&1 || skip "bundler not installed"
    _require_version "$(bundle --version 2>/dev/null | awk '{print $NF}')" "4.0.13" "Bundler" "gem update --system && gem install bundler -v '>= 4.0.13'"
    # Trigger the writer if it hasn't run yet in this process.
    bash -c "source '$SUPPLY_CHAIN_SH' >/dev/null 2>&1" >/dev/null 2>&1 || true
    local cfg="${BUNDLE_USER_CONFIG:-${HOME}/.bundle/config}"
    [ -f "$cfg" ] || { echo "expected $cfg to exist"; return 1; }
    grep -Eq "^BUNDLE_COOLDOWN:[[:space:]]+[\"']?${COOLDOWN_DAYS}[\"']?[[:space:]]*$" "$cfg" || \
        { echo "expected BUNDLE_COOLDOWN=\"${COOLDOWN_DAYS}\" in $cfg; actual:"; cat "$cfg"; return 1; }
}
