---
title: "Replace sequential op read with op inject for zero-disk secret loading"
category: performance-issues
tags: [shell-startup, 1password-cli, op-inject, secret-management, bash-compatibility, zsh-compatibility, heredoc, eval-safety]
module: stow/secrets/dot-secrets
symptom: "Shell startup took ~5.7s due to 9 sequential op read calls; intermediate parallel fix wrote plaintext secrets to disk via temp files"
root_cause: "9 sequential op read CLI calls during shell initialization; parallel workaround used mktemp + background processes that wrote secrets to $TMPDIR"
date: 2026-02-15
---

# Replace sequential op read with op inject for zero-disk secret loading

## Problem Symptom

Shell startup took ~5.7 seconds on both macOS and Ubuntu. Profiling showed `source ~/.secrets` was the bottleneck — 9 sequential `op read` calls to 1Password, each taking ~700ms.

An intermediate fix parallelized the calls with background processes writing to temp files (~0.9s), but this introduced a security concern: plaintext secrets were written to disk in `$TMPDIR`.

```text
Current flow:
  mktemp -d → 9x (op read > tmpfile &) → wait → 9x (cat tmpfile) → export → rm -rf

Issues:
  1. Secrets written as plaintext files in $TMPDIR
  2. 9 background processes + wait + cleanup = complex
  3. If shell is killed before rm -rf, secrets persist on disk
```

## Root Cause

The `op read` command fetches a single field per invocation. With 9 secrets from 2 1Password items, this meant 9 separate CLI calls. Each call includes CLI startup, authentication, and network round-trip overhead (~700ms each).

The parallel workaround reduced wall-clock time but introduced disk writes as an intermediary — the only way to capture output from background processes in POSIX shell is via files.

## Investigation Steps

1. **Profiled shell startup** — `time (source ~/.secrets)` showed 5.7s, dominated by sequential `op read`
2. **First fix: parallel op read** — backgrounded all 9 calls writing to temp files, reduced to ~0.9s
3. **User identified disk write concern** — temp files in `$TMPDIR` contain plaintext secrets
4. **Researched alternatives:**
   - `op inject` — template-based resolution via stdin/stdout (selected)
   - `op run` — secrets scoped to subprocess only, cannot export to current shell (rejected)
   - `op item get --fields` — CSV parsing fragile, manual field mapping (rejected)
   - Named pipes/FIFOs — filesystem objects, more complex (rejected)
   - Process substitution `<()` — not POSIX, bash/zsh specific (rejected)
5. **Discovered heredoc incompatibility** — `eval "$(op inject <<'TPL' ... TPL)"` fails on bash 3.2 and zsh 5.9
6. **Found working two-step pattern** — `_tpl=$(cat <<'TPL' ... TPL); eval "$(printf '%s\n' "$_tpl" | op inject)"`
7. **Discovered all-or-nothing failure** — `op inject` returns exit 1 with zero output if any single reference fails
8. **Found wrong field reference** — `X_API_OAUTH2_USER_ACCESS_REFRESH_TOKEN` should be `X_API_OAUTH2_REFRESH_TOKEN`
9. **Split into 2 calls** — one per 1Password item for failure isolation
10. **Verified on all 3 shells** — bash 3.2, bash 5.3, zsh 5.9, all 9 tokens SET

## Solution

```bash
# X (Twitter) API Keys — resolved from 1Password via op inject, zero disk writes
# Split by item for failure isolation (op inject is all-or-nothing per call)
if command -v op >/dev/null 2>&1 && [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    # Item 1: x_twitter_app_bird_dev (5 fields)
    _op_tpl="$(cat <<'TPL'
export X_API_BIRD_DEV_BEARER_TOKEN="{{ op://secrets-dev/x_twitter_app_bird_dev/credential }}"
export X_API_BIRD_DEV_CONSUMER_KEY="{{ op://secrets-dev/x_twitter_app_bird_dev/consumer_key }}"
export X_API_BIRD_DEV_CONSUMER_KEY_SECRET="{{ op://secrets-dev/x_twitter_app_bird_dev/secret_key }}"
export X_API_BIRD_DEV_OAUTH2_CLIENT_ID="{{ op://secrets-dev/x_twitter_app_bird_dev/oauth2_client_id }}"
export X_API_BIRD_DEV_OAUTH2_CLIENT_SECRET="{{ op://secrets-dev/x_twitter_app_bird_dev/oauth2_client_secret }}"
TPL
)"
    eval "$(printf '%s\n' "$_op_tpl" | op inject 2>/dev/null)" || true

    # Item 2: x_twitter_user_brettdavies (4 fields)
    _op_tpl="$(cat <<'TPL'
export X_API_USER_ACCESS_TOKEN="{{ op://secrets-dev/x_twitter_user_brettdavies/X_API_USER_ACCESS_TOKEN }}"
export X_API_USER_ACCESS_TOKEN_SECRET="{{ op://secrets-dev/x_twitter_user_brettdavies/X_API_USER_ACCESS_TOKEN_SECRET }}"
export X_API_OAUTH2_USER_ACCESS_TOKEN="{{ op://secrets-dev/x_twitter_user_brettdavies/X_API_OAUTH2_USER_ACCESS_TOKEN }}"
export X_API_OAUTH2_USER_ACCESS_REFRESH_TOKEN="{{ op://secrets-dev/x_twitter_user_brettdavies/X_API_OAUTH2_REFRESH_TOKEN }}"
TPL
)"
    eval "$(printf '%s\n' "$_op_tpl" | op inject 2>/dev/null)" || true

    unset _op_tpl
fi
```

### How it works

1. `cat <<'TPL' ... TPL` captures multiline template into a variable (quoted heredoc prevents shell expansion of `{{ }}`)
2. `printf | op inject` pipes the template to `op inject` via stdin
3. `op inject` resolves all `op://` references, outputs resolved text to stdout
4. `eval` executes the `export` statements in the current shell
5. No temp files, no background processes, no cleanup

### Why the two-step pattern (not direct heredoc)

`eval "$(op inject <<'TPL' ... TPL)"` — the simpler form — **fails on bash 3.2 and zsh 5.9**. The heredoc inside `$()` doesn't pipe to `op inject`'s stdin. Error: `"expected data on stdin but none found"`.

The `_tpl=$(cat <<'TPL' ... TPL)` + `printf | op inject` workaround works on all target shells:

- macOS native bash 3.2.57
- macOS Homebrew bash 5.3.9
- macOS/Ubuntu zsh 5.9

### Why split into 2 calls

`op inject` is all-or-nothing: if any single `op://` reference fails, the entire call returns exit 1 and produces no output. Splitting by 1Password item means if one item has a problem, the other item's fields still load.

### Error handling

- `2>/dev/null` on `op inject` prevents error text from reaching `eval`
- `|| true` prevents failure propagation in `set -e` contexts
- `_op_tpl` holds only unresolved `op://` placeholders, not secrets
- Secrets exist only transiently in the `op inject` stdout to `eval` pipeline

## Key Insights

### 1. Heredoc-inside-`$()` is not portable

This is the most important takeaway. The pattern `command <<'DELIM' ... DELIM` inside `$()` command substitution does not reliably pipe to stdin on older shells. Always use the two-step pattern when piping heredoc content to a command inside `$()`.

### 2. op inject does NOT escape special characters

If a secret value contains `"`, the eval'd `export VAR="value"` line breaks. Low risk for API tokens (URL-safe characters) but a known limitation. See [1Password community discussion](https://1password.community/discussion/138753/op-inject-how-to-escape-resolved-secrets).

### 3. op daemon caches items

The `op` CLI daemon caches items after the first fetch. With 9 secrets from 2 items, the second call benefits from cache. This is why `op inject` (~1.2s for 2 calls) is comparable to parallel `op read` (~0.9s for 9 calls) — both reduce to ~2 item fetches.

### 4. Verify 1Password field names before deployment

Run `op item get <item-name> --format json | jq '.fields[] | .label'` to confirm field names. Wrong field references cause silent failures with `2>/dev/null`.

## Performance Comparison

| Approach | macOS bash 3.2 | macOS bash 5.3 | macOS zsh 5.9 | bigdaddy zsh | bigdaddy bash |
|----------|---------------|----------------|---------------|-------------|--------------|
| Sequential `op read` (original) | ~5.7s | ~5.7s | ~5.7s | ~5.7s | ~5.7s |
| Parallel `op read` + tmpfiles | ~0.9s | ~0.9s | ~0.9s | ~0.55s | ~0.55s |
| **`op inject` (final)** | **~1.2s** | **~1.2s** | **~1.3s** | **~1.1s** | **~1.0s** |

All 9 X_API tokens verified SET on all 5 shell targets. The `op inject` approach is ~300ms slower than parallel tmpfiles on macOS but eliminates disk writes and process complexity.

## Prevention Strategies

### 1. Use `op inject` for bulk secret loading

When loading multiple secrets from 1Password during shell startup, always prefer `op inject` over multiple `op read` calls. It resolves all references in a single invocation via stdin/stdout.

### 2. Split op inject calls by 1Password item

Group template references by 1Password item. This provides failure isolation and makes it clear which item a field belongs to.

### 3. Test heredoc patterns on all target shells

```bash
for shell in /bin/bash /opt/homebrew/bin/bash /bin/zsh; do
    echo -n "$shell: "
    $shell -c '_t="$(cat <<'"'"'T'"'"'
hello
T
)"; printf "%s\n" "$_t"' && echo "OK" || echo "FAIL"
done
```

### 4. Audit 1Password field references before deployment

```bash
# Dry-run: test that all op:// references resolve
printf '%s\n' "$_op_tpl" | op inject 2>&1 | head -1
```

## Cross-References

- Related solution: `docs/solutions/deployment-issues/post-deployment-shell-config-fixes.md`
- Related solution: `docs/solutions/deployment-issues/cross-platform-stow-dotfiles-deployment.md`
- Plan: `docs/plans/2026-02-15-perf-secrets-loading-no-disk-writes-plan.md`
- [1Password CLI: op inject reference](https://developer.1password.com/docs/cli/reference/commands/inject/)
- [1Password CLI: Secret reference syntax](https://developer.1password.com/docs/cli/secret-reference-syntax/)
- [op inject escaping discussion](https://1password.community/discussion/138753/op-inject-how-to-escape-resolved-secrets)
