#!/usr/bin/env bash
# Canonical version: 2026.09.14 (generic)
#
# Concurrency-group namespacing guard.
#
# Fails when a workflow's `concurrency.group` begins with an expression rather
# than a literal token naming the workflow that owns it, and when a caller
# invokes one reusable several times while that reusable owns a group.
#
# Why the rule exists: inside a called workflow, `github.workflow` resolves to
# the *caller's* workflow name. A group keyed only on context is therefore a key
# a caller also produces for itself, both land in one group, and when either
# side cancels in progress the called workflow's queue cancels the run that
# called it. The run concludes failure with every visible job green and the
# called workflow's jobs missing, and nothing in the logs names a cause.
#
# A literal prefix is the part a caller and a callee cannot both produce by
# accident, because it names a file rather than a run.
#
# Exit codes: 0 = every group is namespaced and owned (or none is declared),
# 1 = a violation, named with its file and line.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

violations=0
ownership_violations=0

for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  # Only `group:` lines inside a concurrency block, so a `group:` key
  # belonging to anything else is never matched.
  while IFS=: read -r lineno value; do
    [ -n "${lineno:-}" ] || continue
    case "$value" in
      '$'*)
        echo "FAIL: $wf:$lineno concurrency group starts with an expression: $value" >&2
        violations=$((violations + 1))
        ;;
    esac
  done < <(
    awk '
            /^concurrency:/ { inblock = 1; next }
            /^[^[:space:]#]/ { inblock = 0 }
            inblock && /^[[:space:]]+group:/ {
                line = $0
                sub(/^[[:space:]]+group:[[:space:]]*/, "", line)
                print NR ":" line
            }
        ' "$wf"
  )
done

# A reusable's `concurrency:` block evaluates in the *caller's* context, so every
# call one caller makes produces the same key: `github.workflow` and
# `github.ref` are the caller's and identical across them. A caller that invokes
# one reusable more than once puts all of those calls in a single group. With
# `cancel-in-progress: true` a later call cancels an earlier one; with the
# default `queue: single` a third call cancels the pending second. Either way a
# job vanishes from a run that reports nothing failed.
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  while read -r count target; do
    [ -n "${count:-}" ] || continue
    [ "$count" -gt 1 ] || continue
    case "$target" in
      ./*)
        callee="${target#./}"
        if [ -f "$callee" ] && grep -q '^concurrency:' "$callee"; then
          echo "FAIL: $wf calls $target $count times, and $callee declares a workflow-level concurrency group" >&2
          ownership_violations=$((ownership_violations + 1))
        fi
        ;;
      *)
        echo "WARN: $wf calls $target $count times; that reusable must declare no workflow-level concurrency group" >&2
        ;;
    esac
  done < <(
    grep -oE '^[[:space:]]+uses:[[:space:]]+[^[:space:]]+\.ya?ml(@[^[:space:]]+)?' "$wf" 2>/dev/null \
      | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' | sort | uniq -c | awk '{print $1, $2}'
  )
done

if [ "$violations" -gt 0 ]; then
  cat >&2 <<'EOF'

Key each concurrency group on a literal token naming the workflow that owns it:

  concurrency:
    group: ci-${{ github.ref }}

Keep any context parts that separate callers and refs; lead with the literal.
EOF
fi

if [ "$ownership_violations" -gt 0 ]; then
  cat >&2 <<'EOF'

A reusable a caller invokes more than once per run declares no workflow-level
group: nothing available in that block distinguishes one call from another, so
every call collides. Let the caller own the group, or move the group onto a job
inside the reusable and key it on inputs that differ between calls:

  jobs:
    deploy:
      concurrency:
        group: deploy-${{ inputs.environment }}-${{ inputs.config-path }}
EOF
fi

if [ "$violations" -gt 0 ] || [ "$ownership_violations" -gt 0 ]; then
  exit 1
fi

echo "OK: every concurrency group is namespaced with a literal token"
