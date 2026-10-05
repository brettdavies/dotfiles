#!/usr/bin/env bats
# A nested shell must inherit the environment its parent built, unchanged.
#
# .profile's loaded marker is not exported, so every new bash or zsh process
# sources the config/shell fragments again. A fragment that builds an exported
# value from the inherited one adds a copy per nesting level, and the copies
# matter: cargo keys every build on RUSTFLAGS and reruns build scripts when
# CFLAGS changes, so shells at different depths rebuild each other's work.
#
# Each fragment is sourced in a shell, then again in a child of that shell, and
# the child's exported environment must equal the parent's. The shells skip
# their startup files (bash --noprofile --norc, zsh -f, an empty BASH_ENV) so
# the deployed dotfiles stay out of the comparison. Values are compared by hash
# and only variable names are reported, because fragments export secrets.
#
# Run: bats tests/shell-nested-idempotence.bats

CONFIG_DIR="$BATS_TEST_DIRNAME/../config/shell"

setup_file() {
  # Skipped: the per-process variables every shell sets for itself, and
  # PIP_UPLOADED_PRIOR_TO, the rolling cutoff supply-chain.sh recomputes from
  # the clock in each shell, to the second.
  cat >"$BATS_FILE_TMPDIR/digest.py" <<'EOF'
import hashlib, os
SKIP = {"SHLVL", "_", "OLDPWD", "PWD", "PIP_UPLOADED_PRIOR_TO"}
for name in sorted(os.environ):
    if name not in SKIP:
        print(name, hashlib.sha256(os.environ[name].encode()).hexdigest())
EOF
  # nest.sh FRAGMENT DIGEST OUT SHELL...: source FRAGMENT and record the
  # exported environment in OUT.parent, then do the same in a child SHELL,
  # recording OUT.child.
  cat >"$BATS_FILE_TMPDIR/nest.sh" <<'EOF'
frag=$1 digest=$2 out=$3
shift 3
. "$frag" >/dev/null 2>&1
python3 -B "$digest" >"$out.parent"
BASH_ENV='' "$@" -c '. "$1" >/dev/null 2>&1; python3 -B "$2" >"$3"' child "$frag" "$digest" "$out.child"
EOF
}

# _drift SHELL...: one line per fragment whose child shell changes an exported
# variable, naming the variables.
_drift() {
  local frag out changed
  for frag in "$CONFIG_DIR"/*.sh; do
    out="$BATS_TEST_TMPDIR/$(basename "$frag")"
    BASH_ENV='' "$@" "$BATS_FILE_TMPDIR/nest.sh" "$frag" "$BATS_FILE_TMPDIR/digest.py" "$out" "$@"
    changed=$(comm -3 <(sort "$out.parent") <(sort "$out.child") | sed 's/^\t//' | cut -d' ' -f1 | sort -u | tr '\n' ' ')
    [ -z "$changed" ] || echo "$(basename "$frag"): $changed"
  done
}

@test "bash: a child shell re-sourcing each fragment inherits identical exports" {
  command -v python3 >/dev/null || skip "python3 not installed"
  run _drift bash --noprofile --norc
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "re-sourcing changed these exports in a child shell:"
    echo "$output"
    return 1
  fi
}

@test "zsh: a child shell re-sourcing each fragment inherits identical exports" {
  command -v python3 >/dev/null || skip "python3 not installed"
  command -v zsh >/dev/null || skip "zsh not installed"
  run _drift zsh -f
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "re-sourcing changed these exports in a child shell:"
    echo "$output"
    return 1
  fi
}
