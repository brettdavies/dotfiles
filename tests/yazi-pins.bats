#!/usr/bin/env bats
# The yazi pin bump: scripts/upgrade/yazi-pins.sh moves package.toml to the newest upstream revisions past the
# seven-day gate, proves them, and lands them through a merged PR.
#
# Run: bats tests/yazi-pins.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

REPO_ROOT="$BATS_TEST_DIRNAME/.."
BUMP="$REPO_ROOT/scripts/upgrade/yazi-pins.sh"
# 2026-11-02T00:00:00Z: the seven-day cutoff is 2026-10-26T00:00:00Z.
NOW=1793577600

# ---------------------------------------------------------------------------
# The bump, against a local bare repo with old pins, a host checkout cloned from it, and file-driven stubs for gh,
# ya, yazi, and the check. git signs nothing: GIT_CONFIG_GLOBAL points at a fixture config.
# ---------------------------------------------------------------------------

_pins() { # <rev for plugins> <rev for the flavor>: a package.toml in ya's layout with the stub's hashes
  printf '[[plugin.deps]]\nuse = "yazi-rs/plugins:%s"\nrev = "%s"\nhash = "h-%s-%s"\n\n' \
    piper "$1" piper "$1" smart-enter "$1" smart-enter "$1" git "$1" git "$1"
  printf '[[flavor.deps]]\nuse = "yazi-rs/flavors:catppuccin-mocha"\nrev = "%s"\nhash = "h-catppuccin-mocha-%s"\n' "$2" "$2"
}

setup() {
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/stub" "$T/bin" "$T/state" "$T/seed/stow/yazi/dot-config/yazi"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
  git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.com
  git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
  git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath /dev/null
  cp "$REPO_ROOT/stow/yazi/dot-config/yazi/"* "$T/seed/stow/yazi/dot-config/yazi/"
  _pins aaaaaaa bbbbbbb >"$T/seed/stow/yazi/dot-config/yazi/package.toml"
  git init -q -b dev "$T/seed"
  git -C "$T/seed" add -A
  git -C "$T/seed" commit -q -m seed
  git clone -q --bare "$T/seed" "$T/origin.git"
  git clone -q -b dev "$T/origin.git" "$T/checkout"

  # Upstream: plugins reached ccccccc before the cutoff and ddddddd after it; the flavor has stayed at bbbbbbb.
  printf '%s\n' "2026-11-01T00:00:00Z dddddddddddddddddddddddddddddddddddddddd" \
    "2026-10-20T00:00:00Z cccccccccccccccccccccccccccccccccccccccc" >"$T/stub/activity-yazi-rs_plugins"
  echo "2026-09-29T00:00:00Z bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >"$T/stub/activity-yazi-rs_flavors"
  echo "green @head" >"$T/stub/ci-states"

  cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
T="$T"
EOF
  cat >>"$T/bin/gh" <<'EOF'
printf '%s\n' "$*" >>"$T/gh.log"
head_sha() { git --git-dir="$T/origin.git" for-each-ref --format='%(objectname)' 'refs/heads/fix/*' | head -n 1; }
case $1 in
  api)
    case $2 in
      repos/*/activity*) r=${2#repos/}; r=${r%%/activity*}; cat "$T/stub/activity-${r//\//_}" ;;
      repos/*/compare/*)
        spec=${2##*/compare/} a=${spec%%...*} b=${spec##*...}
        s=$(awk -v k="$a...$b" '$1 == k { print $2 }' "$T/stub/compare" 2>/dev/null)
        if [ -z "$s" ]; then
          if [ "$a" = "$b" ]; then s=identical; elif [ "$b" = main ]; then s=ahead; else s=behind; fi
        fi
        echo "$s" ;;
      *"/commits?path="*) d=${2#*path=}; d=${d%%&*}; cat "$T/stub/newer-$d" 2>/dev/null || echo 0 ;;
      repos/*/commits/*) cat "$T/stub/merge-parent" 2>/dev/null || echo false ;;
      repos/*) echo main ;;
    esac ;;
  pr)
    case $2 in
      list) cat "$T/stub/open-prs" 2>/dev/null || true ;;
      create)
        while [ $# -gt 0 ]; do [ "$1" != --body-file ] || cp "$2" "$T/pr-body"; shift; done
        echo "https://github.com/fixture/dotfiles/pull/7" ;;
      view)
        case $* in
          *statusCheckRollup*)
            line=$(head -n 1 "$T/stub/ci-states")
            [ "$(wc -l <"$T/stub/ci-states")" -le 1 ] || sed -i.bak 1d "$T/stub/ci-states"
            echo "${line//@head/$(head_sha)}" ;;
          *) cat "$T/stub/pr-state" 2>/dev/null || echo MERGED ;;
        esac ;;
      merge)
        h=$(head_sha)
        [ -z "$h" ] || git --git-dir="$T/origin.git" update-ref refs/heads/dev "$h" ;;
    esac ;;
esac
EOF
  cat >"$T/bin/ya" <<EOF
#!/usr/bin/env bash
T="$T"
EOF
  cat >>"$T/bin/ya" <<'EOF'
printf '%s HOME=%s\n' "$*" "$HOME" >>"$T/ya.log"
f=$HOME/.config/yazi/package.toml
case $HOME in */yazi-pins.*) ;; *) exit 0 ;; esac
awk '/^use *=/ { u = $0; sub(/^use *= *"[^:]*:/, "", u); sub(/".*/, "", u) }
     /^rev *=/ { r = $0; sub(/^rev *= *"/, "", r); sub(/".*/, "", r) }
     /^hash *= *""/ { $0 = "hash = \"h-" u "-" r "\"" } { print }' "$f" >"$f.new"
cat "$f.new" >"$f"
EOF
  cat >"$T/bin/check" <<EOF
#!/usr/bin/env bash
T="$T"
EOF
  cat >>"$T/bin/check" <<'EOF'
mkdir -p "$2"
echo listing >"$2/listing.txt"
echo tasks >"$2/tasks.txt"
revs=$(awk -F'"' '/^rev/ { printf "%s ", $2 }' "$1/.config/yazi/package.toml")
echo "$revs" >>"$T/check.log"
for bad in $(cat "$T/stub/bad-revs" 2>/dev/null); do
  case " $revs" in *" $bad "*) echo failed-fetchers; exit 1 ;; esac
done
echo ok
EOF
  printf '#!/bin/sh\nprintf "Yazi\\n    Version: 26.10.1 (Homebrew 2026-10-30)\\n"\n' >"$T/bin/yazi"
  chmod +x "$T/bin/"*
  export YAZI_PINS_STATE_DIR="$T/state" YAZI_PINS_CHECK_CMD="$T/bin/check" YAZI_PINS_POLL_S=0 YAZI_PINS_NOW=$NOW
}

_bump() {
  BUMP_STATUS=0
  PATH="$T/bin:$PATH" "$BUMP" --base dev --repo "$T/origin.git" --gh-repo fixture/dotfiles --checkout "$T/checkout" "$@" \
    >"$T/bump.out" 2>"$T/bump.err" || BUMP_STATUS=$?
  BUMP_ERR=$(cat "$T/bump.err")
  OUT=$(tail -n 1 "$T/bump.out")
  echo "status=$BUMP_STATUS stderr: $BUMP_ERR"
  echo "outcome: $OUT"
}

_field() { jaq -r "$1" <<<"$OUT"; }

_branch_pins() { # the package.toml on the pushed bump branch
  git --git-dir="$T/origin.git" show "$(git --git-dir="$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/fix/*' | head -n 1):stow/yazi/dot-config/yazi/package.toml"
}

@test "pins whose content did not change and that pass the check are not-needed, and the stamp records the yazi" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  printf '%s\n' "2026-10-20T00:00:00Z aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$T/stub/activity-yazi-rs_plugins"
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  [ "$(_field '[.outcome, .reason, .exit_code, .pr, .host_update, .next_step.action] | tostring')" = \
    '["not-needed","up-to-date",0,null,null,"none"]' ]
  [ "$(cat "$T/state/yazi-pins-proven")" = 26.10.1 ]
  run grep -c 'pr create' "$T/gh.log"
  [ "$output" = 0 ]
}

@test "a candidate older than the current rev is never chosen" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  echo "ccccccc...aaaaaaa ahead" >"$T/stub/compare"
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  [ "$(_field .outcome)" = not-needed ]
  grep -qx 'aaaaaaa aaaaaaa aaaaaaa bbbbbbb ' "$T/check.log"
}

@test "a passing candidate is pushed as ya wrote it, merged at the head CI passed on, and pulled into the host over its older pins" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  [ "$(_field '[.outcome, .reason, .exit_code, .pr, .host_update.action, .next_step.action] | tostring')" = \
    '["bumped","pr-merged",0,"https://github.com/fixture/dotfiles/pull/7","pulled","none"]' ]
  [ "$(_branch_pins)" = "$(_pins ccccccc bbbbbbb)" ]
  head=$(git --git-dir="$T/origin.git" rev-parse dev)
  grep -q -- "pr create -R fixture/dotfiles --base dev --head fix/yazi-pins-26.10.1-20261102 " "$T/gh.log"
  grep -q -- "pr merge https://github.com/fixture/dotfiles/pull/7 -R fixture/dotfiles --squash --delete-branch --match-head-commit $head" "$T/gh.log"
  [ "$(cat "$T/checkout/stow/yazi/dot-config/yazi/package.toml")" = "$(_pins ccccccc bbbbbbb)" ]
  [ "$(grep -v "HOME=.*/yazi-pins\." "$T/ya.log")" = "pkg install --discard HOME=$HOME" ]
  grep -qF 'To install them at once: `git -C ~/dotfiles pull --ff-only && ya pkg install --discard`' "$T/pr-body"
  [ "$(cat "$T/state/yazi-pins-proven")" = 26.10.1 ]
  [ ! -e "$T/state/yazi-pins-pr" ]
}

@test "a host checkout on another branch is left alone, and the pull becomes the next step" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  git -C "$T/checkout" switch -q -c elsewhere
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  [ "$(_field '[.outcome, .host_update.action, .host_update.reason, .next_step.action] | tostring')" = \
    '["bumped","skipped","not-on-base","pull"]' ]
  [[ "$(_field .next_step.command)" == "git -C $T/checkout pull --ff-only && ya pkg install --discard" ]]
  [ "$(cat "$T/checkout/stow/yazi/dot-config/yazi/package.toml")" = "$(_pins aaaaaaa bbbbbbb)" ]
}

@test "a PR behind its base is updated through GitHub and merged at the update's head" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  merge=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  printf '%s\n' "behind @head" "pending $merge" "green $merge" >"$T/stub/ci-states"
  echo true >"$T/stub/merge-parent"
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  [ "$(_field .outcome)" = bumped ]
  grep -q '^pr update-branch https://github.com/fixture/dotfiles/pull/7' "$T/gh.log"
  grep -q -- "--match-head-commit $merge" "$T/gh.log"
}

@test "an update whose head does not descend from the pushed commit is not merged" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  printf '%s\n' "behind @head" "green eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" >"$T/stub/ci-states"
  _bump
  [ "$BUMP_STATUS" -eq 1 ]
  [ "$(_field '[.outcome, .reason, .next_step.action] | tostring')" = '["failed","ci-failed","inspect-pr"]' ]
  run grep -c '^pr merge' "$T/gh.log"
  [ "$output" = 0 ]
}

@test "red checks leave the PR open and recorded, and name the checks to inspect" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  echo "red @head" >"$T/stub/ci-states"
  _bump
  [ "$BUMP_STATUS" -eq 1 ]
  [ "$(_field '[.outcome, .reason, .pr, .next_step.command] | tostring')" = \
    '["failed","ci-failed","https://github.com/fixture/dotfiles/pull/7","gh pr checks https://github.com/fixture/dotfiles/pull/7"]' ]
  grep -q '^https://github.com/fixture/dotfiles/pull/7 ' "$T/state/yazi-pins-pr"
  [ ! -e "$T/state/yazi-pins-proven" ]
}

@test "checks still running at the timeout end the run, and the PR stays recorded for the next one" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  echo "pending @head" >"$T/stub/ci-states"
  YAZI_PINS_CI_TIMEOUT=0 _bump
  [ "$BUMP_STATUS" -eq 1 ]
  [ "$(_field '[.outcome, .reason] | tostring')" = '["failed","ci-timeout"]' ]
  [ -s "$T/state/yazi-pins-pr" ]
}

@test "a recorded open PR for the installed yazi is resumed and merged without a new clone" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  url=https://github.com/fixture/dotfiles/pull/5
  sha=ffffffffffffffffffffffffffffffffffffffff
  echo "$url fix/yazi-pins-26.10.1-20261101 $sha" >"$T/stub/open-prs"
  echo "$url $sha" >"$T/state/yazi-pins-pr"
  echo "green $sha" >"$T/stub/ci-states"
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  [ "$(_field '[.outcome, .pr] | tostring')" = "[\"bumped\",\"$url\"]" ]
  grep -q -- "pr merge $url -R fixture/dotfiles --squash --delete-branch --match-head-commit $sha" "$T/gh.log"
  [ ! -e "$T/check.log" ]
}

@test "a recorded open PR for an older yazi is closed and replaced by a fresh bump" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  url=https://github.com/fixture/dotfiles/pull/5
  sha=ffffffffffffffffffffffffffffffffffffffff
  echo "$url fix/yazi-pins-26.9.1-20261020 $sha" >"$T/stub/open-prs"
  echo "$url $sha" >"$T/state/yazi-pins-pr"
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  grep -q "^pr close $url -R fixture/dotfiles --delete-branch" "$T/gh.log"
  [ "$(_field '[.outcome, .pr] | tostring')" = '["bumped","https://github.com/fixture/dotfiles/pull/7"]' ]
}

@test "an open bump PR this job did not record is reported and never merged" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  echo "https://github.com/fixture/dotfiles/pull/5 fix/yazi-pins-26.10.1-20261101 ffffffffffffffffffffffffffffffffffffffff" \
    >"$T/stub/open-prs"
  _bump
  [ "$BUMP_STATUS" -eq 1 ]
  [ "$(_field '[.outcome, .reason, .next_step.action] | tostring')" = '["failed","pr-open","inspect-pr"]' ]
  run grep -c '^pr merge' "$T/gh.log"
  [ "$output" = 0 ]
}

@test "a candidate that fails while the current pins pass is not-needed, naming the rejected candidate" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  echo ccccccc >"$T/stub/bad-revs"
  _bump
  [ "$BUMP_STATUS" -eq 0 ]
  [ "$(_field '[.outcome, .reason] | tostring')" = '["not-needed","up-to-date"]' ]
  [[ "$(_field .value)" == *ccccccc* ]]
  run grep -c 'pr create' "$T/gh.log"
  [ "$output" = 0 ]
}

@test "when no pins pass and a pinned plugin has a newer upstream commit, the bump waits for the gate" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  printf '%s\n' ccccccc aaaaaaa >"$T/stub/bad-revs"
  echo 1 >"$T/stub/newer-git.yazi"
  _bump
  [ "$BUMP_STATUS" -eq 75 ]
  [ "$(_field '[.outcome, .reason, .next_step.action] | tostring')" = '["waiting","cooldown","rerun"]' ]
  [[ "$(_field .value)" == *"$T/state/yazi-pins-check.txt"* ]]
  [ -s "$T/state/yazi-pins-check.txt" ]
  [ ! -e "$T/state/yazi-pins-proven" ]
}

@test "when no pins pass and no pinned plugin has anything newer, the bump fails the check" {
  command -v jaq >/dev/null 2>&1 || skip "jaq not available"
  printf '%s\n' ccccccc aaaaaaa >"$T/stub/bad-revs"
  _bump
  [ "$BUMP_STATUS" -eq 1 ]
  [ "$(_field '[.outcome, .reason] | tostring')" = '["failed","check-failed"]' ]
  run grep -c 'pr create' "$T/gh.log"
  [ "$output" = 0 ]
}

@test "an unknown argument is a usage error that names the flags" {
  _bump --bogus
  [ "$BUMP_STATUS" -eq 2 ]
  [[ "$BUMP_ERR" == *"ERROR: unknown argument: --bogus"* ]]
  [[ "$BUMP_ERR" == *"--checkout"* ]]
}
