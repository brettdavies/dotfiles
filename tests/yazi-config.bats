#!/usr/bin/env bats
# Tests for stow/yazi/dot-config/yazi/yazi.toml, the file manager config that
# deploys to both the Linux server and the Mac.
#
# Run: bats tests/yazi-config.bats
#
# CI has no yazi and the repo has no TOML linter, so the file is parsed with
# Python's standard tomllib and checked as data. The routing table replaces
# yazi's built-in rules, so the tests pin it whole, and they pin every opener
# entry that is not Linux-only, because those are what yazi on the Mac runs.

CONFIG="$BATS_TEST_DIRNAME/../stow/yazi/dot-config/yazi/yazi.toml"

# check <python>: run a check against the parsed file, bound to `cfg`, with
# `openers` (the [opener] table) and `rules` ([open] rules) as shorthands.
check() {
  run python3 -B -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)
openers = cfg.get("opener", {})
rules = cfg.get("open", {}).get("rules", [])
def entries(name, platform):
    return [e for e in openers.get(name, []) if e.get("for") == platform]
'"$1" "$CONFIG"
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}

@test "yazi.toml parses as TOML" {
  check 'pass'
}

@test "the routing table is the explicit table, row for row" {
  check '
archives = "application/{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}"
expected = [
    {"mime": "folder/*", "use": ["edit-local", "open", "reveal"]},
    {"mime": "text/*", "use": ["edit", "reveal"]},
    {"mime": "application/{json,ndjson,javascript,wine-extension-ini}", "use": ["edit", "reveal"]},
    {"mime": "inode/empty", "use": ["edit", "reveal"]},
    {"mime": "application/pdf", "use": ["read-pdf"]},
    {"mime": "image/*", "use": ["mac-view", "open", "reveal"]},
    {"mime": "{audio,video}/*", "use": ["mac-view", "play", "reveal"]},
    {"mime": archives, "use": ["extract", "reveal"]},
    {"mime": "vfs/{absent,stale}", "use": ["download"]},
    {"mime": "trash/**", "use": ["open", "trash"]},
    {"url": "*", "use": ["mac-view", "open", "reveal"]},
]
normalized = [dict(r, use=[r["use"]] if isinstance(r["use"], str) else r["use"]) for r in rules]
assert normalized == expected, "rules differ:\n" + "\n".join(map(str, normalized))
'
}

@test "[open] declares rules and no prepend_rules, ending in the catch-all" {
  check '
section = cfg["open"]
assert "prepend_rules" not in section and "append_rules" not in section, section.keys()
keys = [r.get("mime", r.get("url")) for r in rules]
assert keys[-1] == "*" and "url" in rules[-1], keys
for k in ("text/*", "vfs/{absent,stale}", "trash/**"):
    assert keys.index(k) < len(keys) - 1, k
'
}

@test "every opener entry yazi on the Mac can run is unchanged" {
  check '
editor = {"run": "$EDITOR %s", "block": True, "desc": "$EDITOR", "for": "unix"}
expected = {
    "edit": [editor],
    "edit-local": [editor],
    "read-pdf": [{"run": "open %s", "desc": "Preview.app", "for": "macos"}],
    "mac-view": [],
}
actual = {name: [e for e in es if e.get("for") != "linux"] for name, es in openers.items()}
assert actual == expected, actual
'
}

@test "the edit opener goes to the Mac first on Linux, with the local editor as its fallback" {
  check '
first = openers["edit"][0]
assert first["for"] == "linux" and first["block"] is True, first
assert first["run"] == "mac-open edit %s || ${EDITOR:-micro} %s", first["run"]
'
}

@test "the edit opener still offers the local \$EDITOR entry" {
  check '
assert any(e["run"] == "$EDITOR %s" for e in openers["edit"]), openers["edit"]
'
}

@test "mac-view exists on Linux only and blocks" {
  check '
es = openers["mac-view"]
assert es and all(e["for"] == "linux" for e in es), es
assert es[0]["run"] == "mac-open view %s" and es[0]["block"] is True, es
'
}

@test "every opener entry carries a desc for the O picker" {
  check '
missing = [(n, e["run"]) for n, es in openers.items() for e in es if not e.get("desc")]
assert not missing, missing
'
}

@test "directories open with edit-local, which never reaches mac-open" {
  check '
folder = next(r for r in rules if r.get("mime") == "folder/*")
assert folder["use"][0] == "edit-local", folder
assert all("mac-open" not in e["run"] for e in openers["edit-local"]), openers["edit-local"]
'
}

@test "read-pdf on Linux tries the Mac, then the local text view as one group" {
  check '
(linux,) = entries("read-pdf", "linux")
run = linux["run"]
assert run.startswith("mac-open view %s || {") and run.endswith("; }"), run
inner = run[len("mac-open view %s || {"):]
assert "pdftotext -layout %s" in inner and "micro" in inner, run
assert linux["block"] is True, linux
'
}
