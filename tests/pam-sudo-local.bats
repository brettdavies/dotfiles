#!/usr/bin/env bats
# Tests for scripts/pam-sudo-local.sh, which compares /etc/pam.d/sudo_local with
# config/pam.d/sudo_local and, with --apply, installs the repo's file there.
#
# Run: bats tests/pam-sudo-local.bats
#
# Every privileged or macOS-only command the script touches is a stub in a
# PATH-prepended directory: `uname` (so Linux CI passes the Darwin gate), `stat`
# (answers only for the template path, with the owner, group and mode in
# STUB_TEMPLATE_ATTRS), and `sudo` (logs its argv to CALLS and copies the
# install's source onto its destination). Nothing reads or writes /etc:
# PAM_SUDO_LOCAL and PAM_SUDO_LOCAL_TEMPLATE point at per-test files. A test
# that needs a repo file other than the committed one runs a copy of the script
# inside a sandbox repo tree.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/pam-sudo-local.sh"
DECLARED_FILE="$REPO_ROOT/config/pam.d/sudo_local"
STOW_DEPLOY="$REPO_ROOT/scripts/stow-deploy"
LINT_SHELL="$REPO_ROOT/scripts/lint-shell"
KNOWN_GOOD='auth       sufficient     pam_tid.so'
SENTINEL='sentinel: never overwritten'

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  export PAM_SUDO_LOCAL="$BATS_TEST_TMPDIR/sudo_local"
  export PAM_SUDO_LOCAL_TEMPLATE="$BATS_TEST_TMPDIR/sudo_local.template"
  export STUB_TEMPLATE_ATTRS="_testowner testgroup 640"
  mkdir -p "$STUBS"
  : >"$CALLS"
  printf '#auth       sufficient     pam_tid.so\n' >"$PAM_SUDO_LOCAL_TEMPLATE"

  stub uname 'echo "${STUB_UNAME:-Darwin}"'
  stub stat 'log stat "$@"
    [ "${*: -1}" = "$PAM_SUDO_LOCAL_TEMPLATE" ] || exit 1
    echo "$STUB_TEMPLATE_ATTRS"'
  stub sudo 'log sudo "$@"
    [ -z "${STUB_SUDO_FAIL:-}" ] || exit 1
    [ -z "${STUB_SUDO_SWAP:-}" ] || printf "auth       required       pam_deny.so\n" >"${@: -2:1}"
    [ -n "${STUB_SUDO_NOOP:-}" ] || cp "${@: -2:1}" "${@: -1}"'
  PATH="$STUBS:$PATH"
}

# stub NAME BODY: an executable NAME whose body can call `log`.
stub() {
  cat >"$STUBS/$1" <<EOF
#!/usr/bin/env bash
log() { printf '%s\n' "\$*" >>"\$CALLS"; }
$2
EOF
  chmod +x "$STUBS/$1"
}

# sandbox_repo CONTENT: a repo tree holding a copy of the script and a
# config/pam.d/sudo_local with exactly CONTENT; sets SANDBOX_SCRIPT.
sandbox_repo() {
  local root="$BATS_TEST_TMPDIR/sandbox-repo"
  mkdir -p "$root/scripts" "$root/config/pam.d"
  cp "$SCRIPT" "$root/scripts/pam-sudo-local.sh"
  printf '%s' "$1" >"$root/config/pam.d/sudo_local"
  SANDBOX_SCRIPT="$root/scripts/pam-sudo-local.sh"
}

# seed_target: a target that differs from the repo file and must survive any
# run that is not allowed to change it.
seed_target() {
  printf '%s\n' "$SENTINEL" >"$PAM_SUDO_LOCAL"
}

assert_target_untouched() {
  [ "$(cat "$PAM_SUDO_LOCAL")" = "$SENTINEL" ]
}

# --- Declared value ---

@test "the declared file is exactly the one line macOS's template ships commented out" {
  [ "$(cat "$DECLARED_FILE"; printf x)" = "$KNOWN_GOOD"$'\n'x ]
}

# --- Not macOS ---

@test "a non-macOS host is a no-op: exit 0, no command run, no target created" {
  STUB_UNAME=Linux run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"macOS-only"* ]]
  [ ! -s "$CALLS" ]
  [ ! -e "$PAM_SUDO_LOCAL" ]
}

@test "--apply on a non-macOS host runs nothing and leaves an existing target alone" {
  seed_target
  STUB_UNAME=Linux run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  assert_target_untouched
}

# --- Report mode ---

@test "a target equal to the repo file reports in sync and exits 0" {
  cp "$DECLARED_FILE" "$PAM_SUDO_LOCAL"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
  [ ! -s "$CALLS" ]
}

@test "an in-sync target needs no readable template" {
  cp "$DECLARED_FILE" "$PAM_SUDO_LOCAL"
  rm "$PAM_SUDO_LOCAL_TEMPLATE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}

@test "a missing target prints the exact install command and exits 1" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING: drift:"* ]]
  [[ "$output" == *"it does not exist"* ]]
  [[ "$output" == *"fix: sudo /usr/bin/install -S -o _testowner -g testgroup -m 640 $DECLARED_FILE $PAM_SUDO_LOCAL"* ]]
  [ ! -e "$PAM_SUDO_LOCAL" ]
}

@test "a different target shows the diff, the exact install command, and that --apply replaces the whole file" {
  seed_target
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING: drift:"* ]]
  [[ "$output" == *"-$SENTINEL"* ]]
  [[ "$output" == *"+$KNOWN_GOOD"* ]]
  [[ "$output" == *"fix: sudo /usr/bin/install -S -o _testowner -g testgroup -m 640 $DECLARED_FILE $PAM_SUDO_LOCAL"* ]]
  [[ "$output" == *"replaces the whole file"* ]]
}

@test "the fix names the owner, group and mode the template has, not a fixed set" {
  STUB_TEMPLATE_ATTRS="root wheel 444" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"-o root -g wheel -m 444 "* ]]
}

@test "report mode never runs sudo and leaves the target as it was" {
  seed_target
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  run ! grep -q '^sudo' "$CALLS"
  assert_target_untouched
}

@test "the owner, group and mode come from the template path alone" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^stat' "$CALLS")" -eq 1 ]
  grep -qxF "stat -f %Su %Sg %Lp $PAM_SUDO_LOCAL_TEMPLATE" "$CALLS"
}

@test "an unknown argument is a usage error" {
  run "$SCRIPT" --force
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: bad-usage:"* ]]
  [[ "$output" == *"usage:"* ]]
  [ ! -s "$CALLS" ]
}

# --- Template ---

@test "a missing template on drift is a config error naming template-unreadable" {
  rm "$PAM_SUDO_LOCAL_TEMPLATE"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR: template-unreadable:"* ]]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" != *"fix:"* ]]
}

@test "a template this user cannot read is named as unreadable, not as missing" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  chmod 000 "$PAM_SUDO_LOCAL_TEMPLATE"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR: template-unreadable:"* ]]
  [[ "$output" == *"is not readable"* ]]
  [[ "$output" != *"does not exist"* ]]
}

@test "--apply with a missing template refuses and changes nothing" {
  seed_target
  rm "$PAM_SUDO_LOCAL_TEMPLATE"
  run "$SCRIPT" --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR: template-unreadable:"* ]]
  run ! grep -q '^sudo' "$CALLS"
  assert_target_untouched
}

@test "--apply with a template whose attributes do not parse refuses and changes nothing" {
  seed_target
  for attrs in "" "root wheel" "root wheel 99" "root wheel 4444x" 'ro ot wheel 444' 'root wheel 444 extra' 'root; reboot wheel 444' \
    "root wheel 666" "root wheel 664" "root wheel 646" "root wheel 4755" "root wheel 0644"; do
    STUB_TEMPLATE_ATTRS="$attrs" run "$SCRIPT" --apply
    [ "$status" -eq 3 ] || {
      echo "attrs '$attrs' gave status $status" >&2
      return 1
    }
    [[ "$output" == *"ERROR: template-unreadable:"* ]]
    [[ "$output" == *"returned no usable owner, group and mode"* ]]
    [[ "$output" == *"/usr/bin/stat"* ]]
  done
  run ! grep -q '^sudo' "$CALLS"
  assert_target_untouched
}

# --- Apply mode ---

@test "--apply installs the repo file through sudo with the template's owner, group and mode" {
  seed_target
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  grep -qxF "sudo /usr/bin/install -S -o _testowner -g testgroup -m 640 $DECLARED_FILE $PAM_SUDO_LOCAL" "$CALLS"
  cmp -s "$DECLARED_FILE" "$PAM_SUDO_LOCAL"
}

@test "--apply runs the command the report mode prints" {
  run "$SCRIPT"
  fix=${output#*fix: }
  fix=${fix%%$'\n'*}
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  grep -qxF "$fix" "$CALLS"
}

@test "--apply tells the operator to keep the terminal open, test from a second one, and undo from the first" {
  run --separate-stderr "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"NOTE: keep this terminal open"* ]]
  [[ "$stderr" == *"sudo -k; sudo true"* ]]
  [[ "$stderr" == *"sudo rm $PAM_SUDO_LOCAL"* ]]
  [[ "$stderr" == *"in this terminal right away"* ]]
  [[ "$output" != *"keep this terminal open"* ]]
}

@test "--apply on an in-sync target runs nothing" {
  cp "$DECLARED_FILE" "$PAM_SUDO_LOCAL"
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  run ! grep -q '^sudo' "$CALLS"
}

@test "--apply fails with apply-failed when sudo fails, and tells the operator to check the target" {
  seed_target
  STUB_SUDO_FAIL=1 run "$SCRIPT" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: apply-failed:"* ]]
  [[ "$output" == *"check $PAM_SUDO_LOCAL"* ]]
  [[ "$output" != *"as it was"* ]]
  assert_target_untouched
}

@test "--apply fails with apply-failed when the target is not the known-good line after the install" {
  seed_target
  STUB_SUDO_NOOP=1 run "$SCRIPT" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: apply-failed:"* ]]
  [[ "$output" == *"is not the known-good line"* ]]
}

@test "--apply fails with apply-failed and the undo command when the repo file changes between the check and the install" {
  sandbox_repo "$KNOWN_GOOD"$'\n'
  seed_target
  STUB_SUDO_SWAP=1 run "$SANDBOX_SCRIPT" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: apply-failed:"* ]]
  [[ "$output" == *"is not the known-good line"* ]]
  [[ "$output" == *"sudo rm $PAM_SUDO_LOCAL"* ]]
  [[ "$output" != *"sudo_local installed"* ]]
}

# --- Known-good gate ---

@test "a repo file that is not exactly the known-good line is refused in both modes, and nothing changes" {
  local -a bad=(
    "$KNOWN_GOOD"
    "$KNOWN_GOOD"$'\n\n'
    "$KNOWN_GOOD"$'\n'"auth required pam_deny.so"$'\n'
    "auth sufficient pam_tid.so"$'\n'
    "#$KNOWN_GOOD"$'\n'
    "auth       required       pam_deny.so"$'\n'
    ""
  )
  local content
  seed_target
  for content in "${bad[@]}"; do
    sandbox_repo "$content"
    for mode in "" --apply; do
      run "$SANDBOX_SCRIPT" $mode
      [ "$status" -eq 3 ] || {
        echo "repo file '$content' with '$mode' gave status $status: $output" >&2
        return 1
      }
      [[ "$output" == *"ERROR: repo-file-not-known-good:"* ]]
      [[ "$output" != *"fix:"* ]]
    done
  done
  run ! grep -q '^sudo' "$CALLS"
  assert_target_untouched
}

@test "a repo file with a NUL byte after the known-good line is refused" {
  sandbox_repo "$KNOWN_GOOD"$'\n'
  printf '\0' >>"$BATS_TEST_TMPDIR/sandbox-repo/config/pam.d/sudo_local"
  seed_target
  for mode in "" --apply; do
    run "$SANDBOX_SCRIPT" $mode
    [ "$status" -eq 3 ]
    [[ "$output" == *"ERROR: repo-file-not-known-good:"* ]]
  done
  run ! grep -q '^sudo' "$CALLS"
  assert_target_untouched
}

@test "a missing repo file is refused as not known good" {
  sandbox_repo "$KNOWN_GOOD"$'\n'
  rm "$BATS_TEST_TMPDIR/sandbox-repo/config/pam.d/sudo_local"
  seed_target
  run "$BATS_TEST_TMPDIR/sandbox-repo/scripts/pam-sudo-local.sh" --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR: repo-file-not-known-good:"* ]]
  run ! grep -q '^sudo' "$CALLS"
  assert_target_untouched
}

@test "a sandboxed repo with the known-good line installs it" {
  sandbox_repo "$KNOWN_GOOD"$'\n'
  seed_target
  run "$SANDBOX_SCRIPT" --apply
  [ "$status" -eq 0 ]
  grep -qxF "sudo /usr/bin/install -S -o _testowner -g testgroup -m 640 $BATS_TEST_TMPDIR/sandbox-repo/config/pam.d/sudo_local $PAM_SUDO_LOCAL" "$CALLS"
  [ "$(cat "$PAM_SUDO_LOCAL")" = "$KNOWN_GOOD" ]
}

# --- Wiring ---

@test "stow-deploy runs the check inside the macOS \$HOME block and never applies it" {
  local block
  block=$(awk '/^if \[ "\$PLATFORM" = "Darwin" \] && \[ "\$TARGET" = "\$HOME" \]; then$/ { on = 1 }
    on { print } on && /^fi$/ { exit }' "$STOW_DEPLOY")
  [[ "$block" == *'scripts/pam-sudo-local.sh" || true'* ]]
  run ! grep -q 'pam-sudo-local.sh.*--apply' "$STOW_DEPLOY"
}

@test "the script is executable and a lint target" {
  [ -x "$SCRIPT" ]
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run "$LINT_SHELL" scripts/pam-sudo-local.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) clean"* ]]
}
