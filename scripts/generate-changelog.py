#!/usr/bin/env -S PYTHONDONTWRITEBYTECODE=1 uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate or update CHANGELOG.md using git-cliff with PR body expansion.

Usage:
    generate-changelog.py [--tag TAG] [repo-path]
    generate-changelog.py --check [repo-path]
    generate-changelog.py --dry-run [--tag TAG] [repo-path]
    generate-changelog.py --print-tag [--tag TAG] [repo-path]

Options:
    --tag TAG      Override version tag (default: extracted from branch name).
    --check        Verify CHANGELOG.md has a versioned section
                   (exit 1 if only [Unreleased]).
    --dry-run      Run the regen flow against the current CHANGELOG.md and
                   restore the original on exit. Exit 0 if regeneration
                   produces identical content (idempotent), exit 1 with a
                   unified diff if it would drift. Requires an existing
                   CHANGELOG.md.
    --print-tag    Print the resolved version tag and exit (no git-cliff run).
                   Useful for confirming branch detection or scripting.

Version detection: the branch name must match release/YYYY.MM.DD (CalVer, with
an optional same-day suffix like release/2026.06.16.1) or release/vN.N.N
(SemVer). Pass --tag when not on a release branch.

Pipeline:
    1. git-cliff emits a versioned section from commits since the last tag
       (prepended onto CHANGELOG.md, or created if missing).
    2. PR numbers in that section are fetched from GitHub; each PR body's
       ## Changelog section is parsed for ### Added / ### Changed / ### Fixed /
       ### Documentation bullets.
    3. The version section in CHANGELOG.md is rewritten with the aggregated,
       attributed bullets and a Full Changelog compare link.

Falls back to a flat ## Changes list when a PR uses the older template shape.

Run on a release/YYYY.MM.DD branch before opening the PR to main.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

CATEGORIES = ["Added", "Changed", "Fixed", "Documentation"]

# CalVer YYYY.MM.DD with an optional same-day .N suffix; no leading "v".
CALVER_RE = re.compile(r"^release/(\d{4}\.\d{2}\.\d{2}(?:\.\d+)?)")
# SemVer release/vN.N.N, kept so the generator stays portable across repos.
SEMVER_RE = re.compile(r"^release/v(\d+\.\d+\.\d+)")


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def have(cmd: str) -> bool:
    return run(["bash", "-c", f"command -v {cmd}"]).returncode == 0


def detect_tag_from_branch() -> str:
    proc = run(["git", "branch", "--show-current"])
    branch = proc.stdout.strip() if proc.returncode == 0 else ""
    calver = CALVER_RE.match(branch)
    if calver:
        tag = calver.group(1)
        print(f"Detected version {tag} from branch {branch}")
        return tag
    semver = SEMVER_RE.match(branch)
    if semver:
        tag = f"v{semver.group(1)}"
        print(f"Detected version {tag} from branch {branch}")
        return tag
    fail(
        f"could not detect version from branch '{branch}'\n"
        "Either use a release/YYYY.MM.DD (or release/vX.Y.Z) branch or pass --tag"
    )
    raise AssertionError("unreachable")  # fail() exits; satisfies type checkers


def check_mode(changelog: Path) -> int:
    if not changelog.exists():
        print("FAIL: CHANGELOG.md does not exist", file=sys.stderr)
        return 1
    for line in changelog.read_text().splitlines():
        if line.startswith("## ["):
            if "[Unreleased]" in line:
                print(
                    "FAIL: CHANGELOG.md has [Unreleased] instead of a versioned section",
                    file=sys.stderr,
                )
                print(
                    "Run: generate-changelog.py (on a release/YYYY.MM.DD branch)",
                    file=sys.stderr,
                )
                return 1
            print("OK: CHANGELOG.md has versioned section")
            return 0
    print("FAIL: CHANGELOG.md has no versioned section", file=sys.stderr)
    return 1


def ensure_github_token() -> None:
    if os.environ.get("GITHUB_TOKEN"):
        return
    if not have("gh"):
        return
    if run(["gh", "auth", "status"]).returncode != 0:
        return
    token = run(["gh", "auth", "token"]).stdout.strip()
    if token:
        os.environ["GITHUB_TOKEN"] = token


def run_git_cliff(tag: str, changelog: Path) -> None:
    args = ["git", "cliff", "--unreleased", "--tag", tag]
    if changelog.exists():
        args += ["--prepend", str(changelog)]
    else:
        args += ["-o", str(changelog)]
    if subprocess.run(args).returncode != 0:
        sys.exit(1)


def read_remote_github(cliff_toml: Path) -> tuple[str | None, str | None]:
    data = tomllib.loads(cliff_toml.read_text())
    remote = data.get("remote", {}).get("github", {})
    return remote.get("owner"), remote.get("repo")


def extract_version_section(content: str, version: str) -> str:
    out: list[str] = []
    in_section = False
    needle = f"[{version}]"
    for line in content.splitlines():
        if line.startswith("## ["):
            if in_section:
                break
            if needle in line:
                in_section = True
        if in_section:
            out.append(line)
    return "\n".join(out)


def pr_numbers_from_section(section: str) -> list[int]:
    seen: dict[int, None] = {}
    for m in re.finditer(r"\(#(\d+)\)", section):
        seen[int(m.group(1))] = None
    return sorted(seen)


def fetch_pr(owner: str, repo: str, num: int) -> dict | None:
    proc = run(
        [
            "gh",
            "api",
            f"repos/{owner}/{repo}/pulls/{num}",
            "--jq",
            "{body: .body, author: .user.login}",
        ],
        timeout=10,
    )
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def slice_below(body: str, header_pattern: str) -> str | None:
    match = re.search(header_pattern, body, re.MULTILINE)
    if not match:
        return None
    rest = body[match.end() :]
    next_h2 = re.search(r"^## ", rest, re.MULTILINE)
    return rest[: next_h2.start()] if next_h2 else rest


def extract_changelog_sections(body: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    content = slice_below(body, r"^## Changelog\s*$")
    if content is None:
        return sections
    current: str | None = None
    for line in content.split("\n"):
        h3 = re.match(r"^### (.+)", line)
        if h3:
            current = h3.group(1).strip()
            sections.setdefault(current, [])
        elif current and re.match(r"^- ", line):
            sections[current].append(line)
        elif current and sections.get(current) and re.match(r"^  \S", line):
            sections[current][-1] = sections[current][-1].rstrip() + " " + line.strip()
    return sections


def extract_flat_changes(body: str) -> list[str]:
    bullets: list[str] = []
    content = slice_below(body, r"^## Changes\s*$")
    if content is None:
        return bullets
    for line in content.split("\n"):
        if re.match(r"^- ", line):
            bullets.append(line)
        elif bullets and re.match(r"^  \S", line):
            bullets[-1] = bullets[-1].rstrip() + " " + line.strip()
    return bullets


def collect_entries(
    owner: str, repo: str, pr_numbers: list[int]
) -> dict[str, list[str]]:
    aggregated: dict[str, list[str]] = {}
    for num in pr_numbers:
        pr = fetch_pr(owner, repo, num)
        if not pr:
            continue
        body = pr.get("body") or ""
        author = pr.get("author") or ""
        attrib = (
            f" by @{author} in [#{num}](https://github.com/{owner}/{repo}/pull/{num})"
            if author
            else ""
        )

        sections = extract_changelog_sections(body)
        if sections:
            for category, bullets in sections.items():
                if not bullets:
                    continue
                aggregated.setdefault(category, [])
                first = True
                for bullet in bullets:
                    if first and " by @" not in bullet:
                        aggregated[category].append(bullet + attrib)
                    else:
                        aggregated[category].append(bullet)
                    first = False
            continue

        flat = extract_flat_changes(body)
        if flat:
            aggregated.setdefault("Changed", [])
            first = True
            for bullet in flat:
                if first and " by @" not in bullet:
                    aggregated["Changed"].append(bullet + attrib)
                else:
                    aggregated["Changed"].append(bullet)
                first = False
    return aggregated


def rewrite_version_section(
    changelog: Path,
    version: str,
    tag: str,
    owner: str,
    repo: str,
    entries: dict[str, list[str]],
) -> None:
    content = changelog.read_text()
    header_re = re.compile(rf"^## \[{re.escape(version)}\].*$", re.MULTILINE)
    header_match = header_re.search(content)
    if not header_match:
        return

    pieces: list[str] = [header_match.group(0)]
    seen: set[str] = set()
    for cat in CATEGORIES:
        bullets = entries.get(cat)
        if bullets:
            pieces.append(f"\n### {cat}\n")
            pieces.extend(bullets)
            seen.add(cat)
    for cat, bullets in entries.items():
        if cat in seen or not bullets:
            continue
        pieces.append(f"\n### {cat}\n")
        pieces.extend(bullets)

    new_section = "\n".join(pieces) + "\n"

    tag_prefix = "v" if tag.startswith("v") else ""
    prev_match = re.search(
        rf"## \[{re.escape(version)}\].*?\n## \[([^\]]+)\]", content, re.DOTALL
    )
    if prev_match:
        prev = prev_match.group(1)
        new_section += (
            f"\n**Full Changelog**: "
            f"[{tag_prefix}{prev}...{tag_prefix}{version}]"
            f"(https://github.com/{owner}/{repo}/compare/"
            f"{tag_prefix}{prev}...{tag_prefix}{version})\n"
        )

    section_re = re.compile(
        rf"## \[{re.escape(version)}\].*?(?=\n## \[|\Z)", re.DOTALL
    )
    new_content = section_re.sub(new_section.rstrip() + "\n", content, count=1)
    changelog.write_text(new_content)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Run regen against the current CHANGELOG.md and restore the original on exit. "
            "Exit 0 if idempotent, 1 with a unified diff if it would drift."
        ),
    )
    parser.add_argument(
        "--print-tag",
        action="store_true",
        help="Print the resolved version tag and exit (no git-cliff run).",
    )
    parser.add_argument("--tag")
    parser.add_argument("repo_path", nargs="?", default=".")
    args = parser.parse_args()

    repo = Path(args.repo_path).resolve()
    cliff_toml = repo / "cliff.toml"
    changelog = repo / "CHANGELOG.md"

    if not cliff_toml.exists():
        fail(f"cliff.toml not found in {repo}")

    if args.check:
        return check_mode(changelog)

    if args.print_tag:
        print(args.tag or detect_tag_from_branch())
        return 0

    if not have("git-cliff"):
        print("error: git-cliff is not installed", file=sys.stderr)
        print("  Install: cargo install git-cliff", file=sys.stderr)
        print("  Or:      brew install git-cliff", file=sys.stderr)
        return 1

    tag = args.tag or detect_tag_from_branch()
    version = tag[1:] if tag.startswith("v") else tag

    ensure_github_token()

    dry_run_original: str | None = None
    if args.dry_run:
        if not changelog.exists():
            fail("--dry-run requires an existing CHANGELOG.md to compare against")
        dry_run_original = changelog.read_text()

    # Duplicate-section guard: skip the git-cliff prepend when a section for
    # this tag already exists, so re-running against an already-released tag
    # doesn't append a second copy of the same version. In dry-run mode we
    # still need the PR-body expansion below to run so it can compare against
    # the current file.
    section_header_re = re.compile(
        rf"^## \[{re.escape(version)}\]", re.MULTILINE
    )
    duplicate_section = (
        changelog.exists() and bool(section_header_re.search(changelog.read_text()))
    )
    if duplicate_section and not args.dry_run:
        print(f"CHANGELOG.md already has a [{version}] section; skipping prepend")
        return 0

    try:
        if not duplicate_section:
            cwd = os.getcwd()
            try:
                os.chdir(repo)
                run_git_cliff(tag, changelog)
            finally:
                os.chdir(cwd)

        owner, repo_name = read_remote_github(cliff_toml)
        has_gh_integration = bool(owner and repo_name and have("gh"))

        if has_gh_integration:
            section = extract_version_section(changelog.read_text(), version)
            pr_nums = pr_numbers_from_section(section)
            if pr_nums:
                entries = collect_entries(owner, repo_name, pr_nums)
                if entries:
                    rewrite_version_section(
                        changelog, version, tag, owner, repo_name, entries
                    )

        if dry_run_original is not None:
            new_content = changelog.read_text()
            if new_content == dry_run_original:
                print("DRY RUN: CHANGELOG.md is current (no regen drift)")
                return 0
            print(
                "DRY RUN: CHANGELOG.md would change (regen drift detected)",
                file=sys.stderr,
            )
            sys.stderr.writelines(
                difflib.unified_diff(
                    dry_run_original.splitlines(keepends=True),
                    new_content.splitlines(keepends=True),
                    fromfile="CHANGELOG.md (current)",
                    tofile="CHANGELOG.md (regenerated)",
                )
            )
            return 1

        if has_gh_integration:
            print("Updated CHANGELOG.md")
        else:
            print(
                "Updated CHANGELOG.md (skipping PR expansion — missing [remote.github] or gh CLI)"
            )
        print("\nNext steps:")
        print("  git add CHANGELOG.md")
        print("  git commit -m 'docs: update CHANGELOG.md'")
        return 0
    finally:
        if dry_run_original is not None:
            changelog.write_text(dry_run_original)


if __name__ == "__main__":
    sys.exit(main())
