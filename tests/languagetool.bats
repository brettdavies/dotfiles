#!/usr/bin/env bats
# Tests for config/shell/languagetool.sh: the default LanguageTool URL and what
# lt_check, lt_info, and lt_languages say when the server cannot be reached.
#
# Run: bats tests/languagetool.bats
# run-tests: parallel
#
# `tailscale` and `curl` are stubs in a PATH-prepended directory, so nothing
# here touches the tailnet or a LanguageTool server. Every call lands in
# $CALLS. Knobs, set as a prefix on `run` or exported before it:
#   TS_SUFFIX   MagicDNS suffix `tailscale status --json` reports (empty: none)
#   TS_EXIT     make `tailscale` fail
#   CURL_EXIT   exit status of the /v2/languages probe (curl's own code)
#   CHECK_JSON  file whose content /v2/check returns
#   CHECK_BODY  text /v2/check returns instead (a non-JSON error page, say)
#   CHECK_EXIT  make every /v2/check request fail with this status
#   CHECK_FAIL_FOR  make /v2/check fail for the file whose path holds this text

bats_require_minimum_version 1.5.0

LT_SH="$BATS_TEST_DIRNAME/../config/shell/languagetool.sh"
SUFFIX="example-tailnet.ts.net"
SERVICE_URL="https://languagetool.$SUFFIX"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUBS"
  : >"$CALLS"
  export CALLS
  PATH="$STUBS:$PATH"
  unset LANGUAGETOOL_URL LT_DENY_RULES LT_BLOCKING_CATEGORIES LT_PROBE_TIMEOUT

  cat >"$STUBS/tailscale" <<'STUB'
#!/usr/bin/env bash
printf 'tailscale %s\n' "$*" >>"$CALLS"
[[ -z ${TS_EXIT:-} ]] || exit "$TS_EXIT"
printf '{"BackendState":"Running","MagicDNSSuffix":"%s"}\n' "${TS_SUFFIX-example-tailnet.ts.net}"
STUB

  cat >"$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CALLS"
url=""
for a in "$@"; do [[ $a == http* ]] && url=$a; done
case $url in
  */v2/languages)
    if [[ -n ${CURL_EXIT:-} && ${CURL_EXIT} -ne 0 ]]; then
      echo "curl: ($CURL_EXIT) stub failure" >&2
      exit "$CURL_EXIT"
    fi
    echo '[{"name":"English (US)","code":"en","longCode":"en-US"}]' ;;
  */v2/check)
    [[ -z ${CHECK_EXIT:-} ]] || exit "$CHECK_EXIT"
    if [[ -n ${CHECK_FAIL_FOR:-} && "$*" == *"$CHECK_FAIL_FOR"* ]]; then exit 28; fi
    if [[ -n ${CHECK_BODY:-} ]]; then printf '%s\n' "$CHECK_BODY"
    elif [[ -n ${CHECK_JSON:-} ]]; then cat "$CHECK_JSON"; else
      echo '{"software":{"name":"LanguageTool","version":"0.0","apiVersion":1,"premium":false},"matches":[]}'
    fi ;;
esac
STUB
  chmod +x "$STUBS/tailscale" "$STUBS/curl"

  DOC="$BATS_TEST_TMPDIR/doc.md"
  printf 'Their is a typo here.\n' >"$DOC"
}

# lt FUNCTION [ARG...]: run one library function in a fresh bash that sourced
# the file, stderr kept apart from stdout. The shell runs with the options the
# agentnative prose-check scripts set before they call it.
lt() {
  run --separate-stderr bash -c 'set -euo pipefail; source "$1"; shift; "$@"' _ "$LT_SH" "$@"
}

@test "sourcing the file asks tailscale and curl for nothing, in bash and in zsh" {
  run bash -c 'source "$1"' _ "$LT_SH"
  [ "$status" -eq 0 ]
  command -v zsh >/dev/null || skip "zsh not installed"
  run zsh -c 'source "$1"' _ "$LT_SH"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "with no URL set, lt_check probes the languagetool Service under the tailnet's full name" {
  lt lt_check "$DOC"
  [ "$status" -eq 0 ]
  grep -q "^tailscale status --json" "$CALLS"
  grep -q "^curl .*$SERVICE_URL/v2/languages" "$CALLS"
  grep -q "^curl .*$SERVICE_URL/v2/check" "$CALLS"
  [ -z "$stderr" ]
}

@test "with no URL set, lt_info reports the Service URL as the server it asked" {
  lt lt_info
  [ "$status" -eq 0 ]
  [[ "$output" == *"URL:           $SERVICE_URL"* ]]
  [[ "$output" == *"Reachable:     yes"* ]]
}

@test "with no URL set, lt_languages asks the Service" {
  lt lt_languages
  [ "$status" -eq 0 ]
  grep -q "^curl .*$SERVICE_URL/v2/languages" "$CALLS"
}

@test "LANGUAGETOOL_URL wins and tailscale is never asked" {
  LANGUAGETOOL_URL="https://lt.example.test" lt lt_check "$DOC"
  [ "$status" -eq 0 ]
  grep -q "^curl .*https://lt.example.test/v2/languages" "$CALLS"
  [ "$(grep -c '^tailscale' "$CALLS")" -eq 0 ]
}

@test "--lt-url wins over LANGUAGETOOL_URL and tailscale is never asked" {
  LANGUAGETOOL_URL="https://env.example.test" lt lt_check --lt-url https://flag.example.test "$DOC"
  [ "$status" -eq 0 ]
  grep -q "^curl .*https://flag.example.test/v2/languages" "$CALLS"
  [ "$(grep -c 'env.example.test' "$CALLS")" -eq 0 ]
  [ "$(grep -c '^tailscale' "$CALLS")" -eq 0 ]
}

@test "lt_rules and lt_categories print without asking tailscale" {
  lt lt_rules
  [ "$status" -eq 0 ]
  lt lt_categories
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "a usage error never reaches tailscale" {
  lt lt_check
  [ "$status" -eq 3 ]
  lt lt_check --bogus "$DOC"
  [ "$status" -eq 3 ]
  [ ! -s "$CALLS" ]
}

@test "with the tailnet name unreadable, lt_check exits 2 with a loud notice and makes no request" {
  TS_SUFFIX="" lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool URL unknown"* ]]
  [[ "$stderr" == *"grammar check NOT RUN"* ]]
  [[ "$stderr" == *"LANGUAGETOOL_URL"* ]]
  [ "$(grep -c '^curl' "$CALLS")" -eq 0 ]
}

@test "with tailscale failing, lt_check exits 2 and names the cause" {
  TS_EXIT=1 lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool URL unknown"* ]]
  [[ "$stderr" == *"tailscale status"* ]]
  [ "$(grep -c '^curl' "$CALLS")" -eq 0 ]
}

@test "a suffix with characters a hostname cannot hold is refused, not spliced into a URL" {
  TS_SUFFIX='x.ts.net/evil?' lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool URL unknown"* ]]
  [ "$(grep -c '^curl' "$CALLS")" -eq 0 ]
}

@test "with the tailnet name unreadable, lt_info says so and exits 2" {
  TS_SUFFIX="" lt lt_info
  [ "$status" -eq 2 ]
  [[ "$output" == *"Reachable:     no"* ]]
  [[ "$stderr" == "WARNING: lt_info: LanguageTool URL unknown"* ]]
}

@test "with the tailnet name unreadable, lt_languages exits 2 with the notice" {
  TS_SUFFIX="" lt lt_languages
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_languages: LanguageTool URL unknown"* ]]
}

@test "an unreachable server makes lt_check exit 2 with a loud, actionable notice" {
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=7 lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool unreachable at https://lt.example.test: "* ]]
  [[ "$stderr" == *"grammar check NOT RUN"* ]]
  [[ "$stderr" == *"curl -sS https://lt.example.test/v2/languages"* ]]
  [[ "$stderr" == *"LANGUAGETOOL_URL"* ]]
}

@test "the unreachable notice appears once however many files are checked" {
  other="$BATS_TEST_TMPDIR/other.md"
  printf 'More text.\n' >"$other"
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=7 lt lt_check "$DOC" "$other"
  [ "$status" -eq 2 ]
  [ "$(grep -c 'LanguageTool unreachable at' <<<"$stderr")" -eq 1 ]
}

@test "a refused http connection names the https-only Service as a cause, not a downed server" {
  LANGUAGETOOL_URL="http://languagetool:8081" CURL_EXIT=7 lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"https"* ]]
  [[ "$stderr" == *"Tailscale Service"* ]]
  [[ "$stderr" != *"LT service down"* ]]
}

@test "a TLS failure is named as one" {
  LANGUAGETOOL_URL="https://languagetool" CURL_EXIT=35 lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"TLS"* ]]
  [[ "$stderr" == *"full MagicDNS name"* ]]
}

@test "an HTTP error status is named as one" {
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=22 lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"HTTP error"* ]]
}

@test "a name that does not resolve and a timeout keep their own reasons" {
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=6 lt lt_check "$DOC"
  [[ "$stderr" == *"resolve"* ]]
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=28 LT_PROBE_TIMEOUT=3 lt lt_check "$DOC"
  [[ "$stderr" == *"timed out (>3s"* ]]
}

@test "lt_info gives the same reason lt_check does for an unreachable server" {
  LANGUAGETOOL_URL="http://languagetool:8081" CURL_EXIT=7 lt lt_info
  [ "$status" -eq 2 ]
  [[ "$output" == *"Reachable:     no"* ]]
  [[ "$output" == *"Tailscale Service"* ]]
  [[ "$output" != *"couldn't connect (host up"* ]]
}

@test "lt_languages exits 2 with the loud notice when the server is unreachable" {
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=7 lt lt_languages
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_languages: LanguageTool unreachable at https://lt.example.test: "* ]]
}

@test "a reachable server leaves stderr empty and reports blocking matches with exit 1" {
  cat >"$BATS_TEST_TMPDIR/check.json" <<'JSON'
{"matches":[{"offset":0,"message":"Possible typo","rule":{"id":"TYPO_RULE","category":{"id":"TYPOS"}}}]}
JSON
  LANGUAGETOOL_URL="https://lt.example.test" CHECK_JSON="$BATS_TEST_TMPDIR/check.json" lt lt_check "$DOC"
  [ "$status" -eq 1 ]
  [ "$output" = "$DOC:1:LT.TYPO_RULE (TYPOS): Possible typo" ]
  [ -z "$stderr" ]
}

@test "a server that passes the probe but fails every check makes lt_check exit 2 and say how many files went unchecked" {
  LANGUAGETOOL_URL="https://lt.example.test" CHECK_EXIT=28 lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool did not check 1 of 1 file(s)"* ]]
  [[ "$stderr" == *"LANGUAGETOOL_URL"* ]]
}

@test "an HTML error page from /v2/check counts as unchecked, not as no findings" {
  LANGUAGETOOL_URL="https://lt.example.test" CHECK_BODY="<html>502 Bad Gateway</html>" lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool did not check 1 of 1 file(s)"* ]]
}

@test "a JSON reply without a matches list counts as unchecked" {
  LANGUAGETOOL_URL="https://lt.example.test" CHECK_BODY='{"message":"Error: text too long"}' lt lt_check "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool did not check 1 of 1 file(s)"* ]]
}

@test "one unchecked file among checked ones exits 2 and names the count" {
  other="$BATS_TEST_TMPDIR/other.md"
  printf 'More text.\n' >"$other"
  LANGUAGETOOL_URL="https://lt.example.test" CHECK_FAIL_FOR="other.md" lt lt_check "$DOC" "$other"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool did not check 1 of 2 file(s)"* ]]
}

@test "blocking matches still exit 1 when another file went unchecked, and the notice still prints" {
  other="$BATS_TEST_TMPDIR/other.md"
  printf 'More text.\n' >"$other"
  cat >"$BATS_TEST_TMPDIR/check.json" <<'JSON'
{"matches":[{"offset":0,"message":"Possible typo","rule":{"id":"TYPO_RULE","category":{"id":"TYPOS"}}}]}
JSON
  LANGUAGETOOL_URL="https://lt.example.test" CHECK_JSON="$BATS_TEST_TMPDIR/check.json" CHECK_FAIL_FOR="other.md" \
    lt lt_check "$DOC" "$other"
  [ "$status" -eq 1 ]
  [ "$output" = "$DOC:1:LT.TYPO_RULE (TYPOS): Possible typo" ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool did not check 1 of 2 file(s)"* ]]
}

@test "an empty matches list is a checked file with nothing to report" {
  LANGUAGETOOL_URL="https://lt.example.test" CHECK_BODY='{"matches":[]}' lt lt_check "$DOC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "the notice does not advise a flag the prose-check scripts reject" {
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=7 lt lt_check "$DOC"
  [[ "$stderr" != *"--lt-url"* ]]
  TS_SUFFIX="" lt lt_check "$DOC"
  [[ "$stderr" != *"--lt-url"* ]]
}

@test "lt_info and lt_languages do not claim a grammar check failed to run" {
  TS_SUFFIX="" lt lt_info
  [[ "$stderr" == *"LanguageTool URL unknown"* ]]
  [[ "$stderr" != *"NOT RUN"* ]]
  LANGUAGETOOL_URL="https://lt.example.test" CURL_EXIT=7 lt lt_languages
  [[ "$stderr" == *"LanguageTool unreachable"* ]]
  [[ "$stderr" != *"NOT RUN"* ]]
}

# The shim answers `command -v tailscale` as a PATH without tailscale would.
NO_TS_ON_PATH='command() { if [[ $1 == -v && $2 == tailscale ]]; then return 1; fi; builtin command "$@"; }'

@test "with tailscale off PATH, the macOS app's CLI names the tailnet" {
  cat >"$BATS_TEST_TMPDIR/app-cli" <<'STUB'
#!/usr/bin/env bash
printf 'app-cli %s\n' "$*" >>"$CALLS"
printf '{"MagicDNSSuffix":"%s"}\n' "$SUFFIX"
STUB
  chmod +x "$BATS_TEST_TMPDIR/app-cli"
  export SUFFIX
  LT_TAILSCALE_APP="$BATS_TEST_TMPDIR/app-cli" run --separate-stderr \
    bash -c "set -euo pipefail; $NO_TS_ON_PATH; "'source "$1"; lt_check "$2"' _ "$LT_SH" "$DOC"
  [ "$status" -eq 0 ]
  grep -q '^app-cli status --json' "$CALLS"
  grep -q "^curl .*$SERVICE_URL/v2/languages" "$CALLS"
  [ "$(grep -c '^tailscale' "$CALLS")" -eq 0 ]
}

@test "with tailscale off PATH and no app CLI, lt_check exits 2 with the no-URL notice" {
  LT_TAILSCALE_APP="$BATS_TEST_TMPDIR/absent" run --separate-stderr \
    bash -c "set -euo pipefail; $NO_TS_ON_PATH; "'source "$1"; lt_check "$2"' _ "$LT_SH" "$DOC"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "WARNING: lt_check: LanguageTool URL unknown"* ]]
  [ "$(grep -c '^curl' "$CALLS")" -eq 0 ]
}
