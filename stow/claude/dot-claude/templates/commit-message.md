# Conventional Commit Messages

Follow the Conventional Commits specification. This file contains agent workflow instructions followed by the
specification reference.

## Agent Instructions

When generating commit messages, you MUST:

1. **Check the actual git diff** - Never rely on memory of changes made during the session. Always run:

- `git status` to see changed files
- `git diff` for unstaged changes
- `git diff --staged` for staged changes

1. **Apply Single Responsibility Principle** - Each commit should do one thing. If changes can be logically separated,
   propose multiple commits:

- Separate feature additions from refactors
- Separate documentation updates from code changes
- Separate formatting/style fixes from functional changes

1. **Propose partial staging when appropriate** - If a file contains unrelated changes:

- Use `git add -p <file>` to stage specific hunks
- Commit the first logical change
- Stage and commit the remaining changes separately

1. **Format for multiple commits** - When proposing separate commits, use this format:

   **Commit 1 of N:**

- Files: `file1.py`, `file2.py`, `file3.py (partial)`
- Message: `type(scope): description`

   **Commit 2 of N:**
- Files: `file3.py (partial)`, `file4.md`
- Message: `type(scope): description`

   Mark files as `(partial)` when only some changes in that file belong to that commit.

## Structure

```plaintext
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

## Commit Types

| Type | Purpose | SemVer |
|------|---------|--------|
| `feat` | New feature | MINOR |
| `fix` | Bug fix | PATCH |
| `docs` | Documentation only |  |
| `style` | Formatting, no code change |  |
| `refactor` | Code change, no new feature or fix |  |
| `perf` | Performance improvement |  |
| `test` | Adding or updating tests |  |
| `build` | Build system or dependencies |  |
| `ci` | CI configuration |  |
| `chore` | Maintenance tasks |  |

**Security advisory fixes use `fix`, not `chore`:**

```plaintext
fix(deps): update rustls-webpki to fix RUSTSEC-2026-0049
```

Dependency updates that fix security advisories are bug fixes (they appear in the changelog under "Fixed"). Routine
dependency bumps without security implications use `chore(deps):`.

## Scope

Optional context in parentheses after the type:

```plaintext
feat(parser): add ability to parse arrays
fix(api): handle null response
```

## Breaking Changes

Indicate breaking changes (MAJOR version bump) in one of two ways:

1. Append `!` after type/scope: `feat(api)!: remove deprecated endpoints`
2. Add footer: `BREAKING CHANGE: environment variables now take precedence over config files`

## Body and Footers

- Body: Optional extended description, separated by blank line from subject
- Footers: Optional metadata using `Token: value` or `Token #value` format
- Use hyphens for multi-word tokens: `Reviewed-by: Name`
- Exception: `BREAKING CHANGE` (no hyphen, must be uppercase)

## Examples

```plaintext
feat(auth): add OAuth2 support

Implements OAuth2 authentication flow with support for Google and GitHub providers.

Closes #123
```

```plaintext
fix!: correct request parsing

BREAKING CHANGE: request body is now parsed as JSON by default
```

```plaintext
docs: update API reference
```
