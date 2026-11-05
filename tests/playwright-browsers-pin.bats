#!/usr/bin/env bats
# Tests for config/playwright/browsers.pin and its one parser,
# scripts/playwright-browsers/lib/pin.sh: the shapes it accepts, the masked
# stable reason for everything else, and the closed set of reasons the scripts
# use against the runbook's reason table.
#
# Run: bats tests/playwright-browsers-pin.bats
#
# run-tests: parallel

bats_require_minimum_version 1.5.0
load lib/browser-set

REASON_TABLE="$BATS_TEST_DIRNAME/../docs/runbooks/playwright-browser-launch.md"

setup_file() { bs_build_archives; }
setup() { bs_sandbox; }

# pin_with SED-EXPR: the test pin with one edit, checked through --check.
pin_with() {
  sed "$1" "$BS_TEST_PIN" >"$BATS_TEST_TMPDIR/edited.pin"
  run --separate-stderr "$BS_SCRIPT" --pin "$BATS_TEST_TMPDIR/edited.pin" --check
}

@test "the repo's pin parses, and its fields have the shapes the readers rely on" {
  run "$BASH" -c 'source "$1/scripts/playwright-browsers/lib/pin.sh"; pin_load "$2"
    echo "$PIN_CFT_VERSION $PW_CFT_NUMBER $PIN_WEBKIT_REVISION $PIN_FFMPEG_REVISION $PIN_LIBRARY_VERSION $PIN_SOURCE_RELEASE ${#PIN_SHA[@]}"' _ "$BS_ROOT" "$BS_PIN"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^157\.0\.8103\.38\ 8103038\ 2388\ 1013\ 1\.61\.1\ 1\.65\.0\ 9$ ]]
}

@test "a value outside its shape stops with pin-invalid-value, showing it masked, and changes nothing" {
  local cases=(
    's/^cft-version .*/cft-version 157.0.8103/'
    's/^cft-version .*/cft-version 157.0.8103.1234/'
    's/^cft-version .*/cft-version 157.0.8103.38 /; s/38 $/38x/'
    's/^webkit-revision .*/webkit-revision 02388/'
    's/^ffmpeg-revision .*/ffmpeg-revision 10 13/'
    's/^library-version .*/library-version npm:other@1/'
    's/^library-sha256 .*/library-sha256 3740BBA3A3E93B4C7BD7C0F6E3C0E5F8CDCE498BEF13511E4D534CC99A8CE198/'
    's/^source-sha256 .*/source-sha256 abc/'
    's/^chromium-aliases .*/chromium-aliases 1200 12x0/'
    's/^chromium-aliases .*/chromium-aliases/'
    's/^webkit-aliases .*/webkit-aliases 2227 2400/'
    's/^sha256 ffmpeg-linux.zip .*/sha256 ffmpeg-linux.zip nothex/'
    's/^sha256 ffmpeg-linux.zip /sha256 ffmpeg-solaris.zip /'
  )
  local c
  for c in "${cases[@]}"; do
    pin_with "$c"
    [ "$status" -eq 1 ] || {
      echo "accepted: $c" >&2
      return 1
    }
    [[ "$stderr" == "ERROR: "*"reason: pin-invalid-value; value: "*"; nothing changed; next: ~/dotfiles/scripts/playwright-browsers-deploy.sh --pin "*" --help" ]] || {
      echo "wrong error for $c: $stderr" >&2
      return 1
    }
  done
  [ ! -e "$BP" ]
}

@test "a bad value is located by its line, and a WebKit alias above the set's says so" {
  pin_with 's/^library-version .*/library-version 1.x/'
  [[ "$stderr" == *"the pin has an invalid value for library-version at line "[0-9]*"; reason: pin-invalid-value; value: 1.x;"* ]]
  pin_with 's/^webkit-aliases .*/webkit-aliases 2227 2400/'
  [[ "$stderr" == *"a WebKit alias is above the set's WebKit 2388; reason: pin-invalid-value; value: 2400;"* ]]
}

@test "an unknown key, a repeated key, and a repeated archive are malformed" {
  pin_with '$a mystery-key 1'
  [[ "$stderr" == *"reason: pin-malformed; value: mystery-key;"* ]]
  pin_with '$a ffmpeg-revision 1013'
  [[ "$stderr" == *"the pin repeats a key, at line "*"; reason: pin-malformed; value: ffmpeg-revision;"* ]]
  pin_with '$a sha256 ffmpeg-linux.zip ee986434d158f74fb5d9c5ff1092026ceedb63f324fe90b5be89460926b7b679'
  [[ "$stderr" == *"reason: pin-invalid-value; value: sha256;"* ]] || [[ "$stderr" == *"reason: pin-invalid-value; value: ffmpeg-linux.zip"* ]]
}

@test "a key or a required archive that is missing is incomplete, naming it" {
  pin_with '/^library-version /d'
  [[ "$stderr" == *"the pin lacks a required key; reason: pin-incomplete; value: library-version;"* ]]
  pin_with '/^sha256 webkit-ubuntu-24.04.zip /d'
  [[ "$stderr" == *"the pin lacks the sha256 of a required archive; reason: pin-incomplete; value: webkit-ubuntu-24.04.zip;"* ]]
}

@test "the pin is data: a value that is a command runs nothing, and its text cannot forge the line that reports it" {
  pin_with 's|^ffmpeg-revision .*|ffmpeg-revision $(touch '"$BATS_TEST_TMPDIR"'/ran); reason: forged; next: rm -rf ~|'
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
  [ "$(wc -l <<<"$stderr")" -eq 1 ]
  [[ "$stderr" == *"reason: pin-invalid-value; value: "?(*)"; nothing changed; next: ~/dotfiles/scripts/playwright-browsers-deploy.sh --pin "*" --help" ]]
  [[ "$stderr" != *'$('* && "$stderr" != *"reason: forged"* ]]
  [[ "$stderr" == *"value: ?touch ?"* ]] || [[ "$stderr" == *"value: ??touch"* ]]
}

@test "a value is shown at most 80 characters long" {
  pin_with "s/^cft-version .*/cft-version $(printf '9%.0s' {1..300})/"
  [[ "$stderr" =~ value:\ 9{80}\; ]]
}

@test "the reasons the scripts use are exactly the runbook's reason table" {
  local in_code in_table
  in_code="$(cat "$BS_ROOT"/scripts/playwright-browsers-deploy.sh "$BS_ROOT"/scripts/playwright-browsers/lib/*.sh |
    grep -vE '^[[:space:]]*#|pin_bad ' | grep -oE '(^|[[:space:]])(usage|[a-z]+(-[a-z]+)+)[[:space:]]+("|\\$|\\\\)' | grep -oE '(usage|[a-z]+(-[a-z]+)+)' | sort -u)"
  in_table="$(grep -oE '^\| `[a-z-]+` +\| [12] ' "$REASON_TABLE" | grep -oE '[a-z-]+' | sort -u)"
  [ -n "$in_code" ]
  [ "$in_code" = "$in_table" ] || {
    diff <(echo "$in_code") <(echo "$in_table") >&2
    return 1
  }
}
