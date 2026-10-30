#!/usr/bin/env bats
# agent-slot work items: a --pr or --issue ref parsed against the slot's origin, resolved on GitHub, and the slot name
# derived from it.
#
# Run: bats tests/agent-slot-items.bats
#
# gh is the stub tests/lib/agent-slot.bash's stub_gh_items installs, answering from gh_item's fixtures.

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

LIB="$BATS_TEST_DIRNAME/../scripts/agent-slot/lib"

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  stub_gh_items
  echo '[]' >"$STUBS/gh-prs.json"
  export ORIGIN_URL=git@github.com:oxipng/oxipng.git
}

teardown() {
  stop_spawned
  assert_no_leaks
}

# lib_run CODE ARG...: runs CODE in a shell that loads agent-slot's libraries as its entry point does, with output in
# JSON. ARG... is the agent-slot command line CODE stands in for: an error's rerun command is built from it, and CODE
# reads it as $1, $2, and so on.
lib_run() {
  local code=$1
  shift
  run --separate-stderr bash -c '
    set -euo pipefail
    lib=$1 code=$2
    shift 2
    for f in env contract names record bounded launch prstate items; do source "$lib/$f.sh"; done
    agent_slot_env "$lib/.."
    contract_init agent-slot "$@"
    CONTRACT_VERB=$1 CONTRACT_OUTPUT=json
    eval "$code"' _ "$LIB" "$code" "$@"
}

# resolve KIND REF: resolves REF as `agent-slot launch oxipng --KIND REF` does for a repo whose origin is $ORIGIN_URL,
# printing the item.
resolve() {
  lib_run 'item_parse_ref "${3#--}" "$4" "$ORIGIN_URL"; item_resolve; printf "%s\n" "$ITEM"' launch oxipng "--$1" "$2"
}

# name ITEM: the slot name derived from a {kind, repo, number, title} item.
name() {
  lib_run 'item_name "$1"' "$1"
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
}

task_pattern() {
  bash -c 'source "$1/launch.sh"; printf %s "$TASK_PATTERN"' _ "$LIB"
}

oxipng_887() {
  gh_item pr 887 "Fix 16-bit to 8-bit reduction with tRNS" OPEN '{"headRefName": "fix/trns-16-to-8",
    "headRepository": {"id": "R_2", "name": "oxipng"}, "headRepositoryOwner": {"id": "U_2", "login": "andrews05"},
    "isCrossRepository": true, "url": "https://github.com/oxipng/oxipng/pull/887"}'
}

@test "887, oxipng/oxipng#887, and the PR's URL resolve to the same PR of the origin's repo, with its head" {
  local ref
  oxipng_887
  for ref in 887 oxipng/oxipng#887 https://github.com/oxipng/oxipng/pull/887; do
    : >"$CALLS"
    resolve pr "$ref"
    [ "$status" -eq 0 ] || {
      echo "$ref: $stderr"
      false
    }
    jaq -e '.kind == "pr" and .repo == "oxipng/oxipng" and .number == 887
      and .title == "Fix 16-bit to 8-bit reduction with tRNS" and .state == "OPEN"
      and .head_branch == "fix/trns-16-to-8" and .head_repo == "andrews05/oxipng"
      and .head_url == "https://github.com/andrews05/oxipng.git" and .cross_repository == true' <<<"$output"
    grep -qx 'gh api repos/oxipng/oxipng/issues/887' "$CALLS"
    grep -q '^gh pr view 887 --repo oxipng/oxipng --json ' "$CALLS"
  done
}

@test "a ref naming another repo resolves there, whatever the origin" {
  gh_item issue 10331 "Pillow 12 fails to build" CLOSED
  ORIGIN_URL=https://github.com/me/dotfiles.git resolve issue python-pillow/Pillow#10331
  [ "$status" -eq 0 ]
  jaq -e '. == {kind: "issue", repo: "python-pillow/Pillow", number: 10331, title: "Pillow 12 fails to build",
    state: "CLOSED"}' <<<"$output"
  grep -qx 'gh api repos/python-pillow/Pillow/issues/10331' "$CALLS"
  run ! grep -q 'pr view' "$CALLS"
}

@test "a PR whose head repository is gone resolves with no head repository" {
  gh_item pr 12 "Old work" CLOSED '{"headRepository": null, "headRepositoryOwner": null, "isCrossRepository": true}'
  resolve pr 12
  [ "$status" -eq 0 ]
  jaq -e '.head_branch == "pr-12" and .head_repo == null and .head_url == null and .state == "CLOSED"' <<<"$output"
}

@test "--issue on a PR's number, or --pr on an issue's, fails with item-kind-mismatch and the command with the flag swapped" {
  oxipng_887
  gh_item issue 3 "An issue"
  resolve issue 887
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "item-kind-mismatch" and .value == "887" and (.message | contains("PR"))
    and .next_step.action == "rerun" and .next_step.command == "agent-slot launch oxipng --pr 887"
    and .recovery.retryable == false and .recovery.side_effects == "none"' <<<"$stderr"
  resolve pr 3
  [ "$status" -eq 2 ]
  jaq -e '.reason == "item-kind-mismatch" and .next_step.command == "agent-slot launch oxipng --issue 3"' <<<"$stderr"
}

@test "GitHub's not-found answer fails with item-not-found naming the ref" {
  resolve pr oxipng/oxipng#999
  [ "$status" -eq 2 ]
  assert_error_shape "$stderr"
  jaq -e '.reason == "item-not-found" and .value == "oxipng/oxipng#999" and (.message | contains("oxipng/oxipng#999"))
    and .next_step.action == "run" and .next_step.command == "agent-slot launch --help"
    and .recovery.retryable == false' <<<"$stderr"
}

@test "gh timing out or failing otherwise fails with retryable pr-state-unknown and the same command to rerun" {
  local body
  for body in 'exit 124' 'echo "HTTP 502: Bad Gateway" >&2; exit 1'; do
    stub gh "$body"
    resolve pr 887
    [ "$status" -eq 1 ] || {
      echo "$body: $stderr"
      false
    }
    assert_error_shape "$stderr"
    jaq -e '.reason == "pr-state-unknown" and .value == "887" and .recovery.retryable == true
      and .next_step.action == "retry" and .next_step.command == "agent-slot launch oxipng --pr 887"
      and .log != null' <<<"$stderr"
  done
}

@test "gh with no usable sign-in fails with gh-auth-missing" {
  local body
  for body in 'echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4' \
    'echo "HTTP 401: Bad credentials (https://api.github.com/repos/oxipng/oxipng/issues/887)" >&2; exit 1'; do
    stub gh "$body"
    resolve pr 887
    [ "$status" -eq 77 ] || {
      echo "$body: $stderr"
      false
    }
    jaq -e '.reason == "gh-auth-missing" and .next_step.command == "gh auth login"' <<<"$stderr"
  done
}

@test "a ref in none of the forms fails with usage before gh is called" {
  local ref
  for ref in '#887' 'oxipng#887' 'https://github.com/oxipng/oxipng/commit/887' '0' 'pr887' '887 ' 'a/b/c#1'; do
    resolve pr "$ref"
    [ "$status" -eq 2 ] || {
      echo "$ref: $status $stderr"
      false
    }
    jaq -e --arg ref "$ref" '.reason == "usage" and .value == $ref' <<<"$stderr"
  done
  run ! grep -q '^gh ' "$CALLS"
}

@test "a title names the slot <repo>-pr<N>-<slug>" {
  name '{"kind": "pr", "repo": "oxipng/oxipng", "number": 887, "title": "Fix 16-bit to 8-bit reduction with tRNS"}'
  [ "$output" = oxipng-pr887-fix-16-bit-to-8-bit-reduction-with-trns ]
}

@test "a long title is cut at a dash to fit a task name, and a long repo name keeps the number" {
  local title full pattern
  pattern=$(task_pattern)
  title=$(printf 'word%s ' $(seq 1 40))
  title=${title:0:200}
  name "$(jaq -n -c --arg t "$title" '{kind: "pr", repo: "oxipng/oxipng", number: 887, title: $t}')"
  full="oxipng-pr887-$(tr ' ' - <<<"${title% }")"
  ((${#output} <= 64))
  [[ $output =~ $pattern ]]
  [[ $output != *- ]]
  [ "${full:${#output}:1}" = - ]
  [ "${full:0:${#output}}" = "$output" ]
  name "$(jaq -n -c --arg r "o/$(printf 'r%.0s' $(seq 1 70))" '{kind: "issue", repo: $r, number: 12345, title: "Fix"}')"
  ((${#output} <= 64))
  [[ $output =~ $pattern ]]
  [[ $output == r*-issue12345 ]]
}

@test "a title of only punctuation names <repo>-pr<N>, and a repo's dots become dashes with leading ones dropped" {
  name '{"kind": "pr", "repo": "oxipng/oxipng", "number": 887, "title": "?!... ---"}'
  [ "$output" = oxipng-pr887 ]
  name '{"kind": "issue", "repo": "x/x.github.io", "number": 3, "title": "Broken link"}'
  [ "$output" = x-github-io-issue3-broken-link ]
  name '{"kind": "issue", "repo": "x/.github", "number": 4, "title": "Add a template"}'
  [ "$output" = github-issue4-add-a-template ]
}
