#!/usr/bin/env bats
# Tests for the bash >= 4.4 guard that opens every script needing bash 4.
#
# Run: bats tests/bash-version-guard.bats
#
# `#!/usr/bin/env bash` finds the macOS system bash 3.2 wherever Homebrew is
# not ahead of /usr/bin on PATH (launchd's default PATH, or `/bin/bash script`).
# A script using a bash 4 construct opens with GUARD, which re-execs it under
# Homebrew's bash, or stops with the install hint when none is present. The
# floor is 4.4 rather than 4 because below it an empty array expanded under
# `set -u` is an unbound-variable error, and scripts/release/guarded-paths.sh
# is a byte-for-byte copy of a template that holds every copy to 4.4.
# Stowed scripts run through symlinks outside the repo, so the guard is inline
# rather than sourced, and this suite holds every copy to GUARD.
#
# The behavior tests need a bash older than 4 at OLD_BASH and skip without
# one: macOS ships it at /bin/bash, Linux CI does not.

bats_require_minimum_version 1.5.0

REPO_ROOT="$BATS_TEST_DIRNAME/.."
OLD_BASH=/bin/bash
PROBES='/opt/homebrew/bin/bash /usr/local/bin/bash'
SAMPLE="$REPO_ROOT/scripts/release/guarded-paths.sh"

GUARD='if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi'

# Constructs bash 3.2 rejects when it reaches them: declare/local attributes
# -A -g -n -l -u, mapfile/readarray, ${x,,} and ${x^^}, &>>, |&, wait -n/-f/-p,
# the 4.x shopt options, coproc, negative subscripts, ${x@Q}-style transforms,
# test -v, {fd}> allocation, ;;& and the 4.x/5.x special variables.
BASH4_RE='(declare|local|typeset|readonly)[[:space:]]+-[a-zA-Z]*[Agnlu]'
BASH4_RE+='|(^|[^[:alnum:]_-])(mapfile|readarray)([^[:alnum:]_-]|$)'
BASH4_RE+='|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,|\^)'
BASH4_RE+='|&>>|\|&|;;&'
BASH4_RE+='|(^|[^[:alnum:]_])wait[[:space:]]+-[a-z]*[nfp]'
BASH4_RE+='|shopt[[:space:]]+-s[[:space:]].*(globstar|lastpipe|inherit_errexit|autocd|checkjobs|direxpand)'
BASH4_RE+='|(^|[^[:alnum:]_])coproc([^[:alnum:]_]|$)'
BASH4_RE+='|\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]'
BASH4_RE+='|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAaKkULu]\}'
BASH4_RE+='|(\[\[|test|\[)[[:space:]]+-v[[:space:]]'
BASH4_RE+='|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
BASH4_RE+='|BASHPID|EPOCHSECONDS|EPOCHREALTIME'

# The first seven command lines of FILE: everything after the shebang and the
# header comments, which is where the guard sits.
_opening() {
  awk 'NR == 1 { next }
    !started && (/^[[:space:]]*#/ || /^[[:space:]]*$/) { next }
    { started = 1; print }' "$1" | head -n 7
}

# FILE plus any lib/*.sh beside it, minus comment lines.
_code_of() {
  local dir
  dir=$(dirname "$1")
  cat "$1" "$dir"/lib/*.sh 2>/dev/null | grep -vE '^[[:space:]]*#' || true
}

_bash_scripts() {
  git -C "$REPO_ROOT" ls-files .githooks scripts stow | while IFS= read -r f; do
    head -n 1 "$REPO_ROOT/$f" 2>/dev/null | grep -qE '^#!.*[/ ]bash([[:space:]]|$)' && echo "$f"
  done
}

_require_old_bash() {
  [ -x "$OLD_BASH" ] || skip "no $OLD_BASH"
  [ "$("$OLD_BASH" -c 'echo "${BASH_VERSINFO[0]}"')" -lt 4 ] || skip "$OLD_BASH is bash 4 or newer"
}

_require_new_bash() {
  for NEW_BASH in $PROBES; do
    [ -x "$NEW_BASH" ] && return 0
  done
  skip "no bash at $PROBES"
}

@test "every script that needs bash 4 opens with the guard" {
  missing=""
  while IFS= read -r f; do
    _code_of "$REPO_ROOT/$f" | grep -qE "$BASH4_RE" || continue
    [ "$(_opening "$REPO_ROOT/$f")" = "$GUARD" ] || missing="$missing $f"
  done < <(_bash_scripts)
  [ -z "$missing" ] || {
    echo "uses a bash 4 construct but does not open with the guard:$missing" >&2
    return 1
  }
}

@test "no script names /bin/bash in its shebang" {
  run git -C "$REPO_ROOT" grep -n '^#!/bin/bash' -- .
  hits=$(printf '%s\n' "$output" | grep -E '^[^:]+:1:' || true)
  [ -z "$hits" ] || {
    echo "use #!/usr/bin/env bash instead:" >&2
    echo "$hits" >&2
    return 1
  }
}

@test "a guarded script started by bash 3 runs to completion under a newer bash" {
  _require_old_bash
  _require_new_bash
  expected=$("$NEW_BASH" "$SAMPLE")
  run "$OLD_BASH" "$SAMPLE"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" = "$expected" ]
}

@test "the guard re-execs with the original arguments" {
  _require_old_bash
  _require_new_bash
  probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo '#!/usr/bin/env bash'
    _opening "$SAMPLE"
    echo 'echo "major=${BASH_VERSINFO[0]} args=$1|$2"'
  } >"$probe"
  run "$OLD_BASH" "$probe" "a b" "c"
  [ "$status" -eq 0 ]
  [[ "$output" =~ major=[4-9]\ args=a\ b\|c ]]
}

@test "with no newer bash on its probe list the guard exits 1 with the install hint" {
  _require_old_bash
  probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo '#!/usr/bin/env bash'
    _opening "$SAMPLE" | sed "s|$PROBES|$BATS_TEST_TMPDIR/none/bash|"
    echo 'declare -A reached=([k]=v)'
    echo 'echo "reached ${reached[k]}"'
  } >"$probe"
  run "$OLD_BASH" "$probe"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: needs bash >= 4.4 (running 3."* ]]
  [[ "$output" == *"brew install bash"* ]]
  [[ "$output" != *"reached"* ]]
}
