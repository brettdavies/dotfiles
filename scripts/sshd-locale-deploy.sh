#!/usr/bin/env bash
set -euo pipefail

# Stop sshd accepting locale variables (LANG, LC_*) from clients, so every
# session runs on the locale the server provides.
#
# Ubuntu's stock sshd_config carries `AcceptEnv LANG LC_*` and macOS's stock
# ssh_config sends them, so a session from a Mac arrives with en_US.UTF-8. A
# minimal server without the `locales` package generates only C.UTF-8, so
# glibc cannot set the forwarded locale and silently falls back to plain C:
# perl warns on every run, shellcheck aborts its report at the first
# non-ASCII character, and sort and grep lose multibyte awareness. Once the
# variables are no longer accepted, pam_env supplies LANG from
# /etc/default/locale (C.UTF-8) to each session.
#
# AcceptEnv accumulates across sshd_config and every sshd_config.d/*.conf
# drop-in, so a drop-in cannot cancel it; the directives themselves have to
# change. This script strips the LANG and LC_* tokens from every active
# AcceptEnv line in the main file and its drop-ins, comments a line out when
# nothing remains, validates with `sshd -t`, and reloads sshd. When sshd
# rejects the result it restores the originals. Sessions already open keep
# their LANG, as does a tmux server started from one.
#
# Usage: sudo scripts/sshd-locale-deploy.sh [--config PATH]
#
#   --config PATH   edit PATH and PATH's sibling sshd_config.d/ instead of
#                   /etc/ssh/sshd_config, with no root check, validation, or
#                   reload. tests/sshd-locale-deploy.bats drives this.
#
# Exit 0 on success, including when nothing needed changing; 1 on a failed
# pre-flight or a config sshd rejects; 2 on a usage error.

EXIT_FAILURE=1
EXIT_USAGE=2

LIVE_CONFIG=/etc/ssh/sshd_config
config="$LIVE_CONFIG"

usage() {
  echo "usage: $0 [--config PATH]" >&2
  exit "$EXIT_USAGE"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || usage
      config="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

live=0
[ "$config" = "$LIVE_CONFIG" ] && live=1

# --- Pre-flight checks ---

if [ "$live" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: This script must be run as root (use sudo)" >&2
  exit "$EXIT_FAILURE"
fi

if [ ! -f "$config" ]; then
  echo "FATAL: config not found: $config" >&2
  exit "$EXIT_FAILURE"
fi

# Every file sshd reads AcceptEnv from: the main file plus the drop-ins its
# Include line pulls in.
files=("$config")
dropin_dir="$(dirname "$config")/sshd_config.d"
if [ -d "$dropin_dir" ]; then
  shopt -s nullglob
  files+=("$dropin_dir"/*.conf)
  shopt -u nullglob
fi

# --- Rewrite ---

# Rewrite one file in place: drop the LANG and LC_* tokens from every active
# AcceptEnv line, comment the line out when no token is left, and leave every
# other byte alone. Returns 0 when the file changed, 1 when it did not.
strip_locale_tokens() {
  local file="$1" tmp
  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*AcceptEnv([[:space:]]|$)/ {
      keep = ""
      dropped = 0
      for (i = 2; i <= NF; i++) {
        if ($i == "LANG" || $i ~ /^LC_/) {
          dropped = 1
          continue
        }
        keep = keep " " $i
      }
      if (!dropped) {
        print
        next
      }
      if (keep == "") {
        print "#" $0
      } else {
        match($0, /^[[:space:]]*/)
        print substr($0, 1, RLENGTH) "AcceptEnv" keep
      }
      next
    }
    { print }
  ' "$file" > "$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # cat rather than mv keeps the file's owner, mode, and inode.
  cat "$tmp" > "$file"
  rm -f "$tmp"
  return 0
}

backup_dir="$(mktemp -d)"
for f in "${files[@]}"; do
  cp -p "$f" "$backup_dir/$(basename "$f")"
done

changed=()
for f in "${files[@]}"; do
  if strip_locale_tokens "$f"; then
    changed+=("$f")
    echo "NOTE: removed LANG and LC_* from AcceptEnv in $f"
  fi
done

if [ "${#changed[@]}" -eq 0 ]; then
  rm -rf "$backup_dir"
  echo "OK: no active AcceptEnv line names LANG or LC_* (nothing to change)"
  exit 0
fi

# --- Validate and reload (live config only) ---

if [ "$live" -eq 1 ]; then
  if ! sshd -t; then
    for f in "${changed[@]}"; do
      original="$backup_dir/$(basename "$f")"
      cat "$original" > "$f"
    done
    rm -rf "$backup_dir"
    echo "FATAL: sshd -t rejected the edited config; originals restored" >&2
    exit "$EXIT_FAILURE"
  fi
  unit=ssh
  systemctl cat ssh.service >/dev/null 2>&1 || unit=sshd
  if systemctl is-active --quiet "$unit"; then
    systemctl reload "$unit"
    echo "OK: $unit reloaded; new sessions take LANG from /etc/default/locale via pam_env"
  else
    echo "OK: $unit is not running; the next socket-activated connection reads the new config"
  fi
  echo "NOTE: sessions already open keep their LANG, as does a tmux server started from one"
fi
rm -rf "$backup_dir"
