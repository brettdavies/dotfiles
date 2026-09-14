#!/usr/bin/env -S PYTHONDONTWRITEBYTECODE=1 uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate or update CHANGELOG.md using git-cliff with PR body expansion.

Usage:
    generate-changelog.py [--tag vX.Y.Z] [repo-path]
    generate-changelog.py --check [repo-path]
    generate-changelog.py --dry-run [--tag vX.Y.Z] [repo-path]
    generate-changelog.py --print-tag [--tag TAG] [repo-path]
    generate-changelog.py --from-dev-prs [--dev-branch dev] [--tag vX.Y.Z] [repo-path]

Options:
    --tag vX.Y.Z   Override version tag (default: extracted from branch name).
    --print-tag    Print the resolved version tag and exit (no git-cliff run).
    --from-dev-prs Build the version section from the PRs merged into the
                   integration branch since the previous release, instead of
                   from the release branch's commits. This is the mode for an
                   overlay-built release branch, whose single commit carries no
                   per-PR history. No git-cliff run.
    --dev-branch   Integration branch --from-dev-prs reads (default: dev).
    --check        Verify CHANGELOG.md has a versioned section
                   (exit 1 if only [Unreleased]).
    --dry-run      Run the regen flow against the current CHANGELOG.md and
                   restore the original on exit. Exit 0 if regeneration
                   produces identical content (idempotent), exit 1 with a
                   unified diff if it would drift. Requires an existing
                   CHANGELOG.md.

Version detection: the branch name must match release/vN.N.N (with optional
suffix like release/v1.0.5-ci-migration). Pass --tag when not on a release
branch.

Pipeline:
    1. git-cliff emits a versioned section from commits since the last tag
       (prepended onto CHANGELOG.md, or created if missing).
    2. PR numbers in that section are fetched from GitHub; each PR body's
       ## Changelog section is parsed for ### Added / ### Changed / ### Fixed /
       ### Documentation bullets.
    3. The version section in CHANGELOG.md is rewritten with the aggregated,
       attributed bullets and a Full Changelog compare link.

Falls back to a flat ## Changes list when a PR uses the older template shape.

Run on a release/vX.Y.Z branch before opening the PR to main.
"""

from __future__ import annotations

import argparse
import difflib
from datetime import date
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

# Emitted in this order; any other `###` heading a PR body uses follows them.
# "Breaking changes" is also the git-cliff group for `type!:` commits in
# cliff.toml, so the skeleton and the PR-body pass agree on the label.
CATEGORIES = ["Breaking changes", "Added", "Changed", "Fixed", "Documentation"]
SKIPPED_TITLE_RE = re.compile(r"^(chore|ci|build|style|test)(\([^)]*\))?!?:")


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def have(cmd: str) -> bool:
    return run(["bash", "-c", f"command -v {cmd}"]).returncode == 0


SEMVER_BRANCH_RE = re.compile(r"^release/v(\d+\.\d+\.\d+)")
CALVER_BRANCH_RE = re.compile(r"^release/(\d{4}\.\d{2}\.\d{2}(?:\.\d+)?)")


def detect_tag_from_branch() -> str:
    """Read the version tag off a release branch name.

    `release/vX.Y.Z` yields `vX.Y.Z`; a CalVer branch `release/YYYY.MM.DD`
    (optionally `.N`) yields the bare date, since CalVer repos tag without
    a `v` prefix.
    """
    proc = run(["git", "branch", "--show-current"])
    branch = proc.stdout.strip() if proc.returncode == 0 else ""
    semver = SEMVER_BRANCH_RE.match(branch)
    calver = CALVER_BRANCH_RE.match(branch)
    if semver:
        tag = f"v{semver.group(1)}"
    elif calver:
        tag = calver.group(1)
    else:
        fail(
            f"could not detect version from branch '{branch}'\n"
            "Use a release/vX.Y.Z or release/YYYY.MM.DD branch, or pass --tag"
        )
    print(f"Detected version {tag} from branch {branch}", file=sys.stderr)
    return tag


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
                    "Run: generate-changelog.py (on a release/vX.Y.Z branch)",
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
    """Collect PR numbers from both bullet forms.

    git-cliff's skeleton emits `(#N)`; the expanded section rewrites those
    into `[#N](...)` links. Matching both keeps re-runs against an
    already-expanded section from silently finding zero PRs and skipping
    the refresh.
    """
    seen: dict[int, None] = {}
    for m in re.finditer(r"\(#(\d+)\)|\[#(\d+)\]", section):
        seen[int(m.group(1) or m.group(2))] = None
    return sorted(seen)


def fetch_pr(owner: str, repo: str, num: int) -> dict | None:
    proc = run(
        [
            "gh",
            "api",
            f"repos/{owner}/{repo}/pulls/{num}",
            "--jq",
            "{body: .body, author: .user.login, title: .title}",
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
            continue

        # No changelog content in the body: the PR title is the bullet, so a
        # shipped change is never silently absent from the section. Types the
        # cliff.toml policy skips (chore, ci, build, style, test) stay out here
        # too; a PR of those types that matters carries its own ## Changelog.
        title = (pr.get("title") or "").strip()
        if title and not SKIPPED_TITLE_RE.match(title):
            aggregated.setdefault("Changed", [])
            aggregated["Changed"].append(f"- {title}{attrib}")
    return aggregated


def resolve_version_tag(version: str) -> str | None:
    """Return the git tag for a released version, or None.

    Tries the `v`-prefixed spelling first, then the bare one (CalVer repos
    tag without a prefix). The existence check keeps the compare link from
    referencing a tag that does not exist (e.g. the first release, with no
    prior tag); the caller omits the link instead of emitting a dead ref.
    Repos with historical tags under another naming scheme should rename
    those tags rather than widen this lookup further.
    """
    for candidate in (f"v{version}", version):
        if run(["git", "tag", "-l", candidate]).stdout.strip():
            return candidate
    return None


def previous_tag(current_tag: str) -> str | None:
    """Newest release tag other than the one being cut, or None."""
    for candidate in run(["git", "tag", "--sort=-version:refname"]).stdout.split():
        if candidate != current_tag and re.match(r"^v?\d", candidate):
            return candidate
    return None


def release_window_start(owner: str, repo: str, prev_tag: str | None) -> str | None:
    """ISO timestamp from which PRs merged into the integration branch belong
    to the release being cut, or None when there is no previous release.

    The previous release branch was cut from the integration branch before
    its tag was pushed, so PRs merged in between belong to this release even
    though they predate the tag. Anchor on the earlier of the previous
    release PR's creation and the tag; PR numbers the changelog already
    lists are dropped afterwards, which covers the overlap.
    """
    if not prev_tag:
        return None
    tag_time = run(["git", "log", "-1", "--format=%cI", prev_tag]).stdout.strip()
    proc = run(
        [
            "gh", "pr", "list", "--repo", f"{owner}/{repo}", "--base", "main",
            "--state", "merged", "--search", f"head:release/{prev_tag}",
            "--limit", "1", "--json", "createdAt", "--jq", ".[0].createdAt // empty",
        ],
        timeout=30,
    )
    pr_time = proc.stdout.strip() if proc.returncode == 0 else ""
    candidates = [t for t in (tag_time, pr_time) if t]
    return min(candidates) if candidates else None


def merged_pr_numbers(owner: str, repo: str, base: str, since: str | None) -> list[int]:
    """PR numbers merged into BASE since SINCE, release bookkeeping excluded."""
    args = [
        "gh", "pr", "list", "--repo", f"{owner}/{repo}", "--base", base,
        "--state", "merged", "--limit", "200", "--json", "number,title",
    ]
    if since:
        args += ["--search", f"merged:>={since}"]
    proc = run(args, timeout=30)
    if proc.returncode != 0:
        fail(f"gh pr list failed: {proc.stderr.strip()}")
    bookkeeping = re.compile(r"^chore\(release\): (backport|sync dev)")
    return sorted(
        pr["number"] for pr in json.loads(proc.stdout) if not bookkeeping.match(pr["title"])
    )


def seed_version_section(changelog: Path, version: str) -> None:
    """Create CHANGELOG.md if needed and insert an empty `## [version]` section
    at the top, so rewrite_version_section has a header to fill."""
    header = (
        "# Changelog\n\n"
        "All notable changes to this project will be documented in this file.\n\n"
    )
    content = changelog.read_text() if changelog.exists() else header
    if re.search(rf"^## \[{re.escape(version)}\]", content, re.MULTILINE):
        return
    section = f"## [{version}] - {date.today().isoformat()}\n\n"
    first = re.search(r"^## \[", content, re.MULTILINE)
    if first:
        content = content[: first.start()] + section + content[first.start():]
    else:
        content = content.rstrip("\n") + "\n\n" + section
    changelog.write_text(content)


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

    prev_match = re.search(
        rf"## \[{re.escape(version)}\].*?\n## \[([^\]]+)\]", content, re.DOTALL
    )
    if prev_match:
        prev_tag = resolve_version_tag(prev_match.group(1))
        if prev_tag:
            new_section += (
                f"\n**Full Changelog**: "
                f"[{prev_tag}...{tag}]"
                f"(https://github.com/{owner}/{repo}/compare/"
                f"{prev_tag}...{tag})\n"
            )

    section_re = re.compile(
        rf"## \[{re.escape(version)}\].*?(?=\n## \[|\Z)", re.DOTALL
    )
    new_content = section_re.sub(new_section.rstrip() + "\n", content, count=1)
    changelog.write_text(new_content)


def from_dev_prs_mode(args, cliff_toml: Path, changelog: Path) -> int:
    """Fill the version section from PRs merged into the integration branch."""
    tag = args.tag or detect_tag_from_branch()
    version = tag[1:] if tag.startswith("v") else tag
    owner, repo_name = read_remote_github(cliff_toml)
    if not (owner and repo_name):
        fail("--from-dev-prs needs [remote.github] owner/repo in cliff.toml")
    if not have("gh"):
        fail("--from-dev-prs needs the gh CLI")
    ensure_github_token()

    dry_run_original: str | None = None
    if args.dry_run:
        if not changelog.exists():
            fail("--dry-run requires an existing CHANGELOG.md to compare against")
        dry_run_original = changelog.read_text()

    try:
        prev = previous_tag(tag)
        since = release_window_start(owner, repo_name, prev)
        seed_version_section(changelog, version)
        content = changelog.read_text()
        this_section = extract_version_section(content, version)
        already_listed = set(pr_numbers_from_section(content)) - set(
            pr_numbers_from_section(this_section)
        )
        pr_nums = [
            n for n in merged_pr_numbers(owner, repo_name, args.dev_branch, since)
            if n not in already_listed
        ]
        if not pr_nums:
            print(
                f"no PRs merged into {args.dev_branch} since {prev or 'the start'} "
                "that the changelog does not already list",
                file=sys.stderr,
            )
        entries = collect_entries(owner, repo_name, pr_nums) if pr_nums else {}
        if entries:
            rewrite_version_section(changelog, version, tag, owner, repo_name, entries)

        if dry_run_original is not None:
            new_content = changelog.read_text()
            if new_content == dry_run_original:
                print("DRY RUN: CHANGELOG.md is current (no regen drift)")
                return 0
            print("DRY RUN: CHANGELOG.md would change (regen drift detected)", file=sys.stderr)
            sys.stderr.writelines(
                difflib.unified_diff(
                    dry_run_original.splitlines(keepends=True),
                    new_content.splitlines(keepends=True),
                    fromfile="CHANGELOG.md (current)",
                    tofile="CHANGELOG.md (regenerated)",
                )
            )
            return 1

        print(f"Updated CHANGELOG.md from {len(pr_nums)} PRs merged into {args.dev_branch}")
        print("\nNext steps:")
        print("  git add CHANGELOG.md")
        print("  git commit -m 'docs: update CHANGELOG.md'")
        return 0
    finally:
        if dry_run_original is not None:
            changelog.write_text(dry_run_original)


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
    parser.add_argument(
        "--from-dev-prs",
        action="store_true",
        help=(
            "Build the version section from PRs merged into --dev-branch since the "
            "previous release (overlay-built release branches); no git-cliff run."
        ),
    )
    parser.add_argument("--dev-branch", default="dev")
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

    if args.from_dev_prs:
        return from_dev_prs_mode(args, cliff_toml, changelog)

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
    # doesn't append a second copy of the same version. The PR-body expansion
    # below still runs either way, so an existing section is refreshed from
    # the current PR bodies (and dry-run has something real to compare).
    section_header_re = re.compile(
        rf"^## \[{re.escape(version)}\]", re.MULTILINE
    )
    duplicate_section = (
        changelog.exists() and bool(section_header_re.search(changelog.read_text()))
    )
    if duplicate_section and not args.dry_run:
        print(
            f"CHANGELOG.md already has a [{version}] section; "
            "skipping prepend, refreshing from PR bodies"
        )

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
