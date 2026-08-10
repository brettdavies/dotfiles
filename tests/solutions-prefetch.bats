#!/usr/bin/env bats
# Tests for the UserPromptSubmit hook that nudges the agent to query
# docs/solutions before debugging (stow/claude/dot-claude/solutions-prefetch.sh).
#
# The hook is reminder-only: it emits one reminder line on a debugging-flavored
# prompt, and nothing otherwise. So a test is just FIRE (non-empty output) vs
# SILENT (empty output).
#
# Four sections:
#   POSITIVE            — debugging prompts that SHOULD fire and do.
#   NEGATIVE            — non-debugging prompts that should stay silent and do.
#   KNOWN FALSE POSITIVE — prompts that fire but ideally would not. Asserted as
#                          FIRE to PIN current behavior; if a future trigger
#                          tweak silences one, that test fails and you move it up
#                          to NEGATIVE on purpose.
#   KNOWN FALSE NEGATIVE — debugging prompts the keyword triggers miss. Asserted
#                          as SILENT to pin the recall gap; if you broaden the
#                          triggers to catch one, that test fails and you move it
#                          up to POSITIVE on purpose.
#
# Run: bats tests/solutions-prefetch.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/solutions-prefetch.sh"

# Feed a prompt string as the hook's JSON stdin; echo FIRE or SILENT.
fires() {
  local prompt=$1 out
  out=$(jaq -n --arg p "$prompt" '{prompt: $p}' | "$HOOK" 2>/dev/null)
  [ -n "$out" ] && echo FIRE || echo SILENT
}

# ---------------------------------------------------------------------------
# POSITIVE — debugging, must FIRE
# ---------------------------------------------------------------------------

@test "positive: broken state" { [ "$(fires "the login page is broken")" = FIRE ]; }
@test "positive: failing tests" { [ "$(fires "tests are failing on CI")" = FIRE ]; }
@test "positive: build failed + exit code" { [ "$(fires "the build failed with exit code 1")" = FIRE ]; }
@test "positive: crashes" { [ "$(fires "app crashes on startup")" = FIRE ]; }
@test "positive: hangs" { [ "$(fires "the worker hangs forever and never returns")" = FIRE ]; }
@test "positive: PascalCase *Exception" { [ "$(fires "getting a NullPointerException in the handler")" = FIRE ]; }
@test "positive: PascalCase *Error + Error: prefix" { [ "$(fires "ValueError: invalid literal for int()")" = FIRE ]; }
@test "positive: NNN status" { [ "$(fires "the deploy returns a 500 status")" = FIRE ]; }
@test "positive: FATAL + connection refused" { [ "$(fires "FATAL: connection refused to db")" = FIRE ]; }
@test "positive: used to work" { [ "$(fires "it used to work, now uploads silently drop")" = FIRE ]; }
@test "positive: why ... wrong" { [ "$(fires "why is the score endpoint returning wrong data")" = FIRE ]; }
@test "positive: flaky" { [ "$(fires "the e2e test is flaky")" = FIRE ]; }
@test "positive: Permission denied" { [ "$(fires "[err] Permission denied (13)")" = FIRE ]; }
@test "positive: SIGSEGV" { [ "$(fires "SIGSEGV in the parser")" = FIRE ]; }
@test "positive: won't start (apostrophe)" { [ "$(fires "wrangler dev won't start")" = FIRE ]; }
@test "positive: doesn't work (apostrophe)" { [ "$(fires "the cache doesn't work after the deploy")" = FIRE ]; }
@test "positive: isn't working (apostrophe)" { [ "$(fires "the toggle isn't working on mobile")" = FIRE ]; }
@test "positive: can't connect (apostrophe)" { [ "$(fires "can't connect to the database")" = FIRE ]; }
@test "positive: stack trace" { [ "$(fires "here is the stack trace from the panic")" = FIRE ]; }
@test "positive: debug this" { [ "$(fires "debug this auth flow for me")" = FIRE ]; }
@test "positive: timed out" { [ "$(fires "the request timed out after 30s")" = FIRE ]; }
@test "positive: multi-line log with Python Traceback" {
  [ "$(fires "$(printf '%s\n' '2026-05-29 INFO worker up' 'DEBUG cache warm' 'Traceback (most recent call last):' '  File app.py line 42' 'ValueError: bad int' 'INFO done')")" = FIRE ]
}
@test "positive: multi-line log with ERROR line" {
  [ "$(fires "$(printf '%s\n' 'INFO listening on 8787' 'WARN slow query' 'ERROR upstream returned 503' 'INFO ok')")" = FIRE ]
}

# ---------------------------------------------------------------------------
# NEGATIVE — not debugging, must stay SILENT
# ---------------------------------------------------------------------------

@test "negative: feature request" { [ "$(fires "add a dark mode toggle")" = SILENT ]; }
@test "negative: lowercase error (the error case)" { [ "$(fires "handle the error case gracefully")" = SILENT ]; }
@test "negative: lowercase error (error handling)" { [ "$(fires "implement error handling for the form")" = SILENT ]; }
@test "negative: failover / fail-safe (not failed/failing)" { [ "$(fires "design a fail-safe failover strategy")" = SILENT ]; }
@test "negative: refactor" { [ "$(fires "refactor the auth module")" = SILENT ]; }
@test "negative: complexity question" { [ "$(fires "what is the time complexity of this sort")" = SILENT ]; }
@test "negative: React error boundary (lowercase error)" { [ "$(fires "build the React error boundary component")" = SILENT ]; }
@test "negative: NNN not error/status (500 items)" { [ "$(fires "write a function that returns 500 items")" = SILENT ]; }
@test "negative: plain question" { [ "$(fires "explain the difference between let and const")" = SILENT ]; }
@test "negative: write tests" { [ "$(fires "write unit tests for the parser")" = SILENT ]; }
@test "negative: empty prompt" { [ "$(fires "")" = SILENT ]; }
@test "negative: missing prompt field" {
  run bash -c "echo '{}' | '$HOOK'"
  [ -z "$output" ]
}
@test "negative: multi-line feature request" {
  [ "$(fires "$(printf '%s\n' 'Add a settings page with:' '- a theme picker' '- a font size slider')")" = SILENT ]
}

# ---------------------------------------------------------------------------
# KNOWN FALSE POSITIVE — fires today, ideally silent (pin current behavior)
# ---------------------------------------------------------------------------

@test "known FP: 'Exception' in a learning question" { [ "$(fires "explain how Exception handling works in Java")" = FIRE ]; }
@test "known FP: writing a custom *Error class" { [ "$(fires "write a custom RuntimeError subclass")" = FIRE ]; }
@test "known FP: asking what an errno code means" { [ "$(fires "what does ECONNREFUSED mean")" = FIRE ]; }
@test "known FP: adding a SIGTERM handler (feature)" { [ "$(fires "add a SIGTERM handler for graceful shutdown")" = FIRE ]; }
@test "known FP: writing the regression test suite" { [ "$(fires "I am writing the regression test suite")" = FIRE ]; }
@test "known FP: comparing ERROR vs WARN log levels" { [ "$(fires "compare the ERROR and WARN log levels")" = FIRE ]; }

# ---------------------------------------------------------------------------
# KNOWN FALSE NEGATIVE — debugging the triggers miss, silent today (pin the gap)
# ---------------------------------------------------------------------------

@test "known FN: vague 'looks wrong'" { [ "$(fires "the output looks wrong")" = SILENT ]; }
@test "known FN: 'returns null unexpectedly'" { [ "$(fires "this returns null unexpectedly")" = SILENT ]; }
@test "known FN: performance (slow)" { [ "$(fires "the dashboard is really slow now")" = SILENT ]; }
@test "known FN: blank page" { [ "$(fires "the page is blank")" = SILENT ]; }
@test "known FN: 'nothing happens'" { [ "$(fires "nothing happens when I click submit")" = SILENT ]; }
@test "known FN: memory leak phrasing" { [ "$(fires "memory keeps growing over time")" = SILENT ]; }
@test "known FN: log whose error line has no keyword" {
  [ "$(fires "$(printf '%s\n' 'INFO start' '[err] something went sideways downstream' 'INFO end')")" = SILENT ]
}
