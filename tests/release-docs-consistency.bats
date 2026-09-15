#!/usr/bin/env bats
# The release runbook is executable: an operator pastes its commands. These pin
# the claims that go stale silently, because a wrong runbook is only discovered
# mid-release when the recovery is expensive.

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  RUNBOOK="$REPO/RELEASES.md"
  SYNC="$REPO/scripts/sync-dev-after-release.sh"
}

@test "every script the runbook invokes exists and is executable" {
  local missing=""
  while IFS= read -r s; do
    [ -x "$REPO/$s" ] || missing="$missing $s"
    # Repo-relative invocations only: a leading `/` or `~` means the path is
    # anchored elsewhere (the unslop scorer lives under ~/.claude).
  done < <(grep -oE '(^|[^/~[:alnum:]])scripts/[a-zA-Z0-9_/.-]+\.(sh|py)' "$RUNBOOK" \
    | grep -oE 'scripts/[a-zA-Z0-9_/.-]+\.(sh|py)' | sort -u)
  [ -z "$missing" ] || {
    echo "runbook names scripts that are missing or not executable:$missing" >&2
    return 1
  }
}

@test "every flag the runbook passes to the backport script is parsed by it" {
  local missing=""
  # Flags appearing in a sync-dev-after-release.sh invocation in the runbook.
  while IFS= read -r flag; do
    grep -qF -- "$flag)" "$SYNC" || missing="$missing $flag"
  done < <(grep -oE 'sync-dev-after-release\.sh[^`]*' "$RUNBOOK" \
    | grep -oE -- '--[a-z-]+' | sort -u)
  [ -z "$missing" ] || {
    echo "runbook passes flags the script does not parse:$missing" >&2
    return 1
  }
}

@test "the script's two usage strings agree" {
  local help_usage err_usage
  help_usage=$(grep -oE 'usage: \$0 [^"]*' "$SYNC" | sed -n 1p)
  err_usage=$(grep -oE 'usage: \$0 [^"]*' "$SYNC" | sed -n 2p)
  [ -n "$help_usage" ]
  [ "$help_usage" = "$err_usage" ]
}

@test "both guarded-path leak checks filter to added and modified" {
  # A release that deletes guarded docs main carried from before the guard
  # existed is doing cleanup, not leaking. An unfiltered grep reads those
  # deletions as a leak and aborts a correct release, so neither the overlay
  # nor the cherry-pick recipe may ship without the filter.
  local checks
  # The two recipes order git's arguments differently, so match the filter and
  # the name-only pair they share rather than a whole invocation.
  checks=$(grep -c -- '--diff-filter=ACMR --name-only' "$RUNBOOK")
  [ "$checks" -eq 2 ]
}

@test "the overlay deletion sweep disables rename detection" {
  # With rename detection on, a main-only file git pairs with a similar
  # dev-side addition is reported as R, drops out of the 'D' list, and ships to
  # main as a file dev already deleted.
  grep -qF 'git diff --no-renames --name-status origin/main origin/dev' "$RUNBOOK"
}

@test "the runbook does not claim the backport is CHANGELOG-only" {
  # It discovers every diverged path now; the old framing sent operators
  # looking for a second step that does not exist.
  # `run` rather than a bare `!`: in bats a leading `!` does not fail the test
  # (SC2314), so the negation has to be asserted on $status.
  run grep -qiE 'CHANGELOG-only|copies `CHANGELOG\.md` only|release-only `CHANGELOG\.md`' "$RUNBOOK"
  [ "$status" -ne 0 ]
}
