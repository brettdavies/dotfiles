#!/usr/bin/env bats
# Tests for scripts/test-cost-guard.sh, which fails a suite whose setup() builds
# a repository for every test and, from a bats junit report, each test over the
# time budget.
#
# Run: bats tests/test-cost-guard.bats
# run-tests: parallel

GUARD="$BATS_TEST_DIRNAME/../scripts/test-cost-guard.sh"

setup() {
  # The cases that rely on the default budget must not take the caller's.
  unset RUN_TESTS_BUDGET_MS
  SBX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SBX/scripts" "$SBX/tests"
  cp "$GUARD" "$SBX/scripts/"
}

# suite <name> <line>...: writes tests/<name>.bats in the sandbox.
suite() {
  local name=$1
  shift
  printf '%s\n' "$@" >"$SBX/tests/$name.bats"
}

allow() {
  printf '%s\n' "$@" >"$SBX/tests/slow-tests.tsv"
}

# report <name> <seconds>...: a junit report of tests/x.bats, one test per name and time.
report() {
  {
    echo '<testsuite name="x.bats">'
    while [ "$#" -gt 0 ]; do
      printf '    <testcase classname="x.bats" name="%s" time="%s" />\n' "$1" "$2"
      shift 2
    done
    echo '</testsuite>'
  } >"$BATS_TEST_TMPDIR/report.xml"
}

@test "a setup() that commits, pushes, clones or calls fixture_repo is named by file and line" {
  suite builds 'setup() {' '  git -C "$R" -c user.name=t commit -q -m x' '  fixture_git "$R" push -q origin dev' \
    '  ok=1 && git clone -q "$O" "$C"' '  fixture_repo "$R"' '}'
  run "$SBX/scripts/test-cost-guard.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/builds.bats:2: git -C"* ]]
  [[ "$output" == *"tests/builds.bats:3: fixture_git"* ]]
  [[ "$output" == *"tests/builds.bats:4: ok=1"* ]]
  [[ "$output" == *"tests/builds.bats:5: fixture_repo"* ]]
  [[ "$output" == *"build the repository once in setup_file()"* ]]
}

@test "the same work in setup_file, git init or config in setup(), and git in a string or comment pass" {
  suite clean 'setup_file() {' '  git -C "$R" commit -q -m x' '}' 'setup() {' '  git init -q "$R"' \
    '  git -C "$R" config commit.gpgsign false' "  decide 'git commit --file m && trash m'" '  # git push here' '}'
  run "$SBX/scripts/test-cost-guard.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a one-line setup() is checked, and the check ends with it" {
  suite one 'setup() { git -C "$R" commit -q -m x; }' '@test "t" {' '  git -C "$R" commit -q -m y' '}'
  run "$SBX/scripts/test-cost-guard.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/one.bats:1:"* ]]
  [[ "$output" != *"tests/one.bats:3:"* ]]
}

@test "named files are checked only when they are suites directly under tests/" {
  suite builds 'setup() {' '  fixture_repo "$R"' '}'
  mkdir -p "$SBX/tests/perf"
  cp "$SBX/tests/builds.bats" "$SBX/tests/perf/builds.bats"
  cd "$SBX"
  run "$SBX/scripts/test-cost-guard.sh" tests/perf/builds.bats README.md
  [ "$status" -eq 0 ]
  run "$SBX/scripts/test-cost-guard.sh" tests/builds.bats
  [ "$status" -eq 1 ]
}

@test "an allowlisted setup() passes, and the sweep fails entries that match nothing" {
  suite builds 'setup() {' '  fixture_repo "$R"' '}'
  suite clean '@test "real \"name\" with \$HOME" {' '  :' '}'
  allow '# comment' '' $'builds.bats\tsetup()\teach test needs a fresh repository' \
    $'clean.bats\treal "name" with $HOME\twaits on purpose'
  run "$SBX/scripts/test-cost-guard.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  allow $'clean.bats\tsetup()\tstale' $'clean.bats\tno such test\tstale' $'gone.bats\tt\tstale' $'clean.bats\treal "name" with $HOME'
  run "$SBX/scripts/test-cost-guard.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean.bats: setup() builds no repository"* ]]
  [[ "$output" == *'clean.bats: no test named "no such test"'* ]]
  [[ "$output" == *"gone.bats: no such suite"* ]]
  [[ "$output" == *"no reason given"* ]]
}

@test "the time check prints each test over the budget that is not allowlisted, names decoded" {
  report 'quick' 0.150 'slow &amp; &quot;loud&quot;' 3.500 'allowed &lt;one&gt;' 9.000 'skipped' 0
  allow $'x.bats\tallowed <one>\twaits on purpose'
  run "$SBX/scripts/test-cost-guard.sh" --report "$BATS_TEST_TMPDIR/report.xml" tests/x.bats
  [ "$status" -eq 1 ]
  [ "$output" = $'tests/x.bats\tslow & "loud"\t3500\t3000' ]
  RUN_TESTS_BUDGET_MS=4000 run "$SBX/scripts/test-cost-guard.sh" --report "$BATS_TEST_TMPDIR/report.xml" tests/x.bats
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  RUN_TESTS_BUDGET_MS=0 run "$SBX/scripts/test-cost-guard.sh" --report "$BATS_TEST_TMPDIR/report.xml" tests/x.bats
  [ "$status" -eq 0 ]
  RUN_TESTS_BUDGET_MS=2s run "$SBX/scripts/test-cost-guard.sh" --report "$BATS_TEST_TMPDIR/report.xml" tests/x.bats
  [ "$status" -eq 2 ]
  [[ "$output" == *"RUN_TESTS_BUDGET_MS takes a whole number of milliseconds, got '2s'"* ]]
}

@test "a passing test that printed output is checked too, and a failed or skipped one is not" {
  cat >"$BATS_TEST_TMPDIR/report.xml" <<'EOF'
<testsuite name="x.bats">
    <testcase classname="x.bats" name="printed" time="3.500">
        <system-out>a line
&lt;failure&gt; quoted in the output</system-out>
    </testcase>
    <testcase classname="x.bats" name="kept its output" time="3.600">
        <system-err>noise</system-err>
    </testcase>
    <testcase classname="x.bats" name="failed" time="9.000">
        <failure type="failure">(in test file x.bats)</failure>
    </testcase>
    <testcase classname="x.bats" name="skipped" time="9.000">
        <skipped>no tool</skipped>
    </testcase>
</testsuite>
EOF
  run "$SBX/scripts/test-cost-guard.sh" --report "$BATS_TEST_TMPDIR/report.xml" tests/x.bats
  echo "$output"
  [ "$status" -eq 1 ]
  [ "$output" = $'tests/x.bats\tprinted\t3500\t3000\ntests/x.bats\tkept its output\t3600\t3000' ]
}

@test "an allowlisted test is found however many tests follow it" {
  # One awk rather than a shell loop, which bats's per-command trap makes cost seconds.
  awk 'BEGIN { printf "@test \"first\" {\n  :\n}\n"; for (i = 0; i < 4000; i++) printf "@test \"filler test number %d\" {\n  :\n}\n", i }' \
    >"$SBX/tests/many.bats"
  allow $'many.bats\tfirst\twaits on purpose'
  run "$SBX/scripts/test-cost-guard.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}
