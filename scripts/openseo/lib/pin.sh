# The one reader of config/openseo/openseo.pin. It never sources or evals the file: each line is split by `read`, and its
# value must match the shape listed here before it is kept. Anything else stops with the line number.
# shellcheck disable=SC2034 # globals are shared through the script that sources this file

pin_bad() {
  OS_VALUE=$(os_mask "$2")
  os_fail pin-invalid "the pin has an invalid $1${PIN_LINE:+ at line $PIN_LINE}; nothing changed" \
    "git checkout -- config/openseo/openseo.pin, or edit it to the shapes in docs/runbooks/openseo.md"
}

# pin_load PATH sets PIN_TAG, PIN_COMMIT, PIN_RELEASED, PIN_IMAGE, and PIN_COMPOSE_SHA.
pin_load() {
  local line key rest name hex extra re var seen=" " n=0
  PIN_TAG='' PIN_COMMIT='' PIN_RELEASED='' PIN_IMAGE='' PIN_COMPOSE_SHA='' PIN_LINE=''
  [ -r "$1" ] || pin_bad "file (it is not readable)" "$1"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    PIN_LINE=$n
    case "$line" in '' | '#'*) continue ;; esac
    read -r key rest <<<"$line"
    re=
    case "$key" in
      tag) re='^v[0-9]+\.[0-9]+\.[0-9]+$' var=PIN_TAG ;;
      commit) re='^[0-9a-f]{40}$' var=PIN_COMMIT ;;
      released) re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' var=PIN_RELEASED ;;
      image) re='^ghcr\.io/every-app/open-seo-standalone@sha256:[0-9a-f]{64}$' var=PIN_IMAGE ;;
      sha256)
        read -r name hex extra <<<"$rest"
        [ "$name" = compose.yaml ] && [[ $hex =~ ^[0-9a-f]{64}$ ]] && [ -z "$extra" ] || pin_bad sha256 "$rest"
        key="$key $name" var=PIN_COMPOSE_SHA rest=$hex
        ;;
      *) pin_bad "key (a line this parser does not know)" "$key" ;;
    esac
    [[ $seen != *" $key "* ]] || pin_bad "repeat of $key" "$key"
    seen+="$key "
    [ -z "$re" ] || [[ $rest =~ $re ]] || pin_bad "$key" "$rest"
    printf -v "$var" '%s' "$rest"
  done <"$1"
  PIN_LINE=
  for var in PIN_TAG PIN_COMMIT PIN_RELEASED PIN_IMAGE PIN_COMPOSE_SHA; do
    [ -n "${!var}" ] || pin_bad "pin (it lacks a required key, $var)" ""
  done
}

# pin_verify COMPOSE_FILE: the vendored file is the one the pin records.
pin_verify() {
  local sum
  sum=$(sha256sum "$1")
  sum=${sum%% *}
  [ "$sum" = "$PIN_COMPOSE_SHA" ] || {
    OS_VALUE=$sum
    os_fail pin-mismatch "config/openseo/compose.yaml has sha256 $sum but the pin records $PIN_COMPOSE_SHA; nothing changed" \
      "git checkout -- config/openseo/compose.yaml"
  }
}
