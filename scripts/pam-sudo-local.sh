#!/usr/bin/env bash
# Compare /etc/pam.d/sudo_local, the file macOS keeps across OS updates and
# includes from /etc/pam.d/sudo, with config/pam.d/sudo_local, which turns on
# Touch ID for sudo.
#
# A bad PAM line can lock sudo out, so the repo file holds the one known-good
# line and both modes refuse any other content. --apply installs the repo file
# whole, replacing the target: a line added there by hand is dropped.
#
# Usage: scripts/pam-sudo-local.sh           report; exit 1 on drift
#        scripts/pam-sudo-local.sh --apply   install the repo file (sudo)
#
# Exit codes: 0 in sync or not macOS, 1 drift or a failed apply, 2 usage error,
#             3 the repo file or the template cannot be used.
# Errors read "ERROR: <reason>: <message>" and drift reads "WARNING: drift: ...".
# Reasons: bad-usage, repo-file-not-known-good, template-unreadable, apply-failed
# Env:   PAM_SUDO_LOCAL           the target (default /etc/pam.d/sudo_local)
#        PAM_SUDO_LOCAL_TEMPLATE  the template that sets the installed file's
#                                 owner, group and mode (default
#                                 /etc/pam.d/sudo_local.template). The bats
#                                 suite points both at per-test files.

set -euo pipefail

EXIT_DRIFT=1
EXIT_USAGE=2
EXIT_CONFIG=3

KNOWN_GOOD='auth       sufficient     pam_tid.so'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DECLARED_FILE="$REPO_ROOT/config/pam.d/sudo_local"
TARGET="${PAM_SUDO_LOCAL:-/etc/pam.d/sudo_local}"
TEMPLATE="${PAM_SUDO_LOCAL_TEMPLATE:-/etc/pam.d/sudo_local.template}"

# fail EXIT REASON MESSAGE
fail() {
  echo "ERROR: $2: $3" >&2
  exit "$1"
}

APPLY=false
case "$#:${1:-}" in
  0:) ;;
  1:--apply) APPLY=true ;;
  *)
    echo "ERROR: bad-usage: unknown or extra argument" >&2
    echo "usage: $0 [--apply]" >&2
    exit "$EXIT_USAGE"
    ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOTE: Touch ID for sudo is macOS-only; nothing to do on $(uname -s)." >&2
  exit 0
fi

# True when FILE holds KNOWN_GOOD and its newline, byte for byte. Comparing
# bytes keeps a NUL, which command substitution would drop, from passing.
is_known_good() {
  cmp -s "$1" <(printf '%s\n' "$KNOWN_GOOD") 2>/dev/null
}

is_known_good "$DECLARED_FILE" \
  || fail "$EXIT_CONFIG" repo-file-not-known-good \
    "$DECLARED_FILE must hold exactly the line '$KNOWN_GOOD' and a newline; nothing was changed"

if cmp -s "$DECLARED_FILE" "$TARGET" 2>/dev/null; then
  echo "sudo_local in sync: $TARGET"
  exit 0
fi

# attrs_usable OWNER GROUP MODE EXTRA: true for an account name pair and a mode
# of three octal digits whose group and other digits carry no write bit, with
# nothing after them. A fourth digit means setuid, setgid or sticky.
attrs_usable() {
  [ -z "$4" ] || return 1
  case "$1" in '' | *[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$2" in '' | *[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$3" in
    [0-7][0145][0145]) ;;
    *) return 1 ;;
  esac
}

# Sets owner, group and mode from the template, which carries what macOS
# expects of a sudo_local file. Anything BSD stat does not return as three
# plain words is refused, so a stat from another toolset cannot reach the
# install command.
read_template_attrs() {
  local attrs extra=""
  [ -e "$TEMPLATE" ] \
    || fail "$EXIT_CONFIG" template-unreadable \
      "$TEMPLATE does not exist; macOS 14 and later ship it, and without it there is no known file to install"
  [ -r "$TEMPLATE" ] \
    || fail "$EXIT_CONFIG" template-unreadable "$TEMPLATE is not readable by this user"
  attrs=$(stat -f '%Su %Sg %Lp' "$TEMPLATE" 2>/dev/null) || attrs=""
  read -r owner group mode extra <<<"$attrs"
  attrs_usable "$owner" "$group" "$mode" "$extra" \
    || fail "$EXIT_CONFIG" template-unreadable \
      "stat -f '%Su %Sg %Lp' returned no usable owner, group and mode for $TEMPLATE (a mode is three octal digits with no group or other write bit); the script needs macOS's /usr/bin/stat ahead of any other stat on PATH"
}

owner="" group="" mode=""
read_template_attrs

# GNU install, ahead of Apple's on a PATH that holds coreutils' gnubin, reads
# -S as a suffix option.
install_cmd=(sudo /usr/bin/install -S -o "$owner" -g "$group" -m "$mode" "$DECLARED_FILE" "$TARGET")
fix=$(printf '%q ' "${install_cmd[@]}")
fix=${fix% }

if [ "$APPLY" = false ]; then
  echo "WARNING: drift: $TARGET differs from config/pam.d/sudo_local" >&2
  if [ -f "$TARGET" ]; then
    diff -u -L installed -L config/pam.d/sudo_local "$TARGET" "$DECLARED_FILE" | sed 's/^/  /' >&2 || true
  else
    echo "  it does not exist" >&2
  fi
  echo "  fix: $fix" >&2
  echo "       (scripts/pam-sudo-local.sh --apply runs it and replaces the whole file; keep the first terminal open" >&2
  echo "       and test with \`sudo -k; sudo true\` from a second one before closing it)" >&2
  exit "$EXIT_DRIFT"
fi

echo "==> $fix"
"${install_cmd[@]}" \
  || fail "$EXIT_DRIFT" apply-failed "sudo install did not complete; check $TARGET before closing this terminal"
is_known_good "$TARGET" \
  || fail "$EXIT_DRIFT" apply-failed "$TARGET is not the known-good line after the install; undo it with: sudo rm $TARGET"

echo "sudo_local installed: $TARGET"
{
  echo "NOTE: keep this terminal open. From a second terminal run \`sudo -k; sudo true\`."
  echo "      If that fails, run \`sudo rm $TARGET\` in this terminal right away, while the sudo"
  echo "      credential from this install is cached, then test again from the second terminal."
  echo "      Close this one only after that prompt takes Touch ID or your password."
} >&2
