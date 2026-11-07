# The host's env file: rendered from 1Password and the pin, read back by key, never sourced and never printed.
# shellcheck disable=SC2034,SC2088 # the tilde stays literal; globals are shared through the script that sources this file

OS_STORAGE_ACCESS_KEY=openseo
# Compose expands $ in an unquoted value, so a value outside this class is refused rather than quoted.
OS_SAFE_RE='^[A-Za-z0-9+/=._:@-]+$'

# os_item ITEM TITLE FIELD VAR reads one 1Password field into VAR. The value reaches no output and no argument list.
os_item() {
  local out
  if ! out=$("$OP_SKILL/read_field.sh" "$1" "$3" 2>/dev/null) || [ -z "$out" ]; then
    os_fail item-unreadable "1Password item $1 ($2), field $3, could not be read; nothing changed; safe to rerun" \
      "~/.claude/skills/1password/scripts/get_item.sh $1" "$1"
  fi
  if ! [[ $out =~ $OS_SAFE_RE ]]; then
    OS_ACTION=supply-input
    os_fail value-unsafe "1Password item $1 ($2), field $3, holds a character an env file cannot carry safely; nothing changed" \
      "change the field to letters, digits, and + / = . _ : @ - only" "$1"
  fi
  printf -v "$4" '%s' "$out"
}

# os_env_get FILE KEY prints the last value KEY has in FILE, or nothing.
os_env_get() {
  local line v=
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) v=${line#*=} ;; esac
  done <"$1"
  printf '%s' "$v"
}

# os_keep_storage KEY NEW: an existing env file keeps its storage credentials, because upstream restores a backup only
# into an installation with the same ones.
os_keep_storage() {
  local old
  old=$(os_env_get "$OS_LOCAL_ENV" "$1")
  [ -z "$old" ] || [ "$old" = "$2" ] || {
    OS_ACTION=supply-input
    os_fail storage-key-changed "$OS_LOCAL_ENV has a different $1 than 1Password item $OS_STORAGE_ITEM (OpenSEO - Storage Secret (openseo)); a restore needs the original storage credentials, so nothing was written" \
      "put the previous value back in the item from its 1Password history, or restore from a backup (docs/runbooks/openseo.md#storage-key-changed)" "$1"
  }
}

# os_optional ITEM TITLE FIELD VAR [NOTE]: like os_item, but an item with no UUID yet leaves VAR empty and says NOTE.
os_optional() {
  if [ -n "$1" ]; then os_item "$1" "$2" "$3" "$4"; elif [ -n "${5:-}" ]; then os_note "$5"; fi
}

os_render() {
  local secret dfs='' gid='' gsec='' image
  [ "$(uname -s)" = Linux ] || os_fail unsupported-host "only the Linux server runs OpenSEO; this host is $(os_mask "$(uname -s)")" "run $OS_DEPLOY on the Linux server" "$(uname -s)"
  pin_load "$OS_PIN"
  pin_verify "$OS_COMPOSE_FILE"
  os_need jq tailscale
  os_need_suffix
  os_item "$OS_STORAGE_ITEM" "OpenSEO - Storage Secret (openseo)" password secret
  os_optional "$OS_DATAFORSEO_ITEM" "DataForSEO API Key" credential dfs "DATAFORSEO_API_KEY renders empty: its 1Password item's UUID is not committed yet, so only the crawl-only audit works"
  os_optional "$OS_GOOGLE_ITEM" "OpenSEO - Google OAuth Client (openseo)" client_id gid "GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET render empty: their 1Password item's UUID is not committed yet, so Search Console cannot connect"
  os_optional "$OS_GOOGLE_ITEM" "OpenSEO - Google OAuth Client (openseo)" client_secret gsec
  os_keep_storage STORAGE_ACCESS_KEY "$OS_STORAGE_ACCESS_KEY"
  os_keep_storage STORAGE_SECRET_KEY "$secret"
  image=$(os_env_get "$OS_LOCAL_ENV" OPENSEO_IMAGE)
  : "${image:=$PIN_IMAGE}"
  mkdir -p "$OS_ENV_DIR"
  chmod 700 "$OS_ENV_DIR"
  OS_TMP=$(mktemp "$OS_ENV_DIR/.local.env.XXXXXX")
  {
    printf 'AUTH_MODE=password\nPORT=%s\n' "$OS_PORT"
    printf 'STORAGE_ACCESS_KEY=%s\nSTORAGE_SECRET_KEY=%s\n' "$OS_STORAGE_ACCESS_KEY" "$secret"
    printf 'BETTER_AUTH_URL=https://openseo.%s\nOPENSEO_IMAGE=%s\n' "$OS_SUFFIX" "$image"
    printf 'DATAFORSEO_API_KEY=%s\nGOOGLE_CLIENT_ID=%s\nGOOGLE_CLIENT_SECRET=%s\n' "$dfs" "$gid" "$gsec"
  } >"$OS_TMP"
  mv -f "$OS_TMP" "$OS_LOCAL_ENV"
  echo "==> wrote $OS_ENV_SHOWN (mode 600; keys: $(sed -n 's/=.*//p' "$OS_LOCAL_ENV" | tr '\n' ' '))"
}

os_require_env() {
  [ -f "$OS_LOCAL_ENV" ] || os_fail env-missing "this host has no rendered config ($(os_mask "$OS_ENV_SHOWN")); nothing changed" "$OS_DEPLOY render" "$OS_ENV_SHOWN"
}
