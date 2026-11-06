#!/usr/bin/env bats
# scripts/tailscale-serve-setup.sh re-asserts this host's Tailscale Serve bindings. Its OpenSEO block binds svc:openseo
# last, only on the host that runs OpenSEO, and only through the bind gate in scripts/openseo/lib/gate.sh. The suite
# stubs hostname, tailscale, and curl, so it binds nothing and calls no service.
#
# Run: bats tests/tailscale-serve-setup.bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/tailscale-serve-setup.sh"

setup_file() {
  load lib/platform
  require_linux "the setup script's OpenSEO block parses the gate's JSON with GNU tools and a Homebrew jq"
}

_stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  BREW="$BATS_TEST_TMPDIR/brew"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUBS" "$BREW" "$BATS_TEST_TMPDIR/openseo"
  export OPENSEO_ENV_DIR="$BATS_TEST_TMPDIR/openseo" OPENSEO_BREW_BIN="$BREW" CALLS
  export STUB_HOST=bigdaddy STUB_OLLAMA=up STUB_CODEX=up STUB_HEALTH=ok STUB_FIRST=false STUB_BOUND=0
  _stub hostname 'echo "$STUB_HOST"'
  _stub tailscale 'echo "tailscale $*" >>"$CALLS"
  [ "$1 $2" = "serve status" ] && [ "$STUB_BOUND" = 1 ] && echo "{\"Services\":{\"svc:openseo\":{}}}"
  if [ "$1 $2" = "status --json" ]; then
    echo "{\"MagicDNSSuffix\":\"tail-test.ts.net\",\"Self\":{\"CapMap\":{\"service-host\":[{\"svc:openseo\":[\"100.64.0.9\"]}]}}}"
  fi
  exit 0'
  _stub curl 'echo "curl ${*: -1}" >>"$CALLS"
  case "${*: -1}" in
    *:11500/api/tags) [ "$STUB_OLLAMA" = up ] || exit 22 ;;
    *:8080/health) [ "$STUB_CODEX" = up ] || exit 22 ;;
    *:8946/api/health) [ "$STUB_HEALTH" != down ] || exit 22; echo "{\"status\":\"$STUB_HEALTH\"}" ;;
    *:8946/api/sign-up-status) echo "{\"firstAccount\":$STUB_FIRST}" ;;
  esac'
  _stub jq 'echo "stub-jq-ran" >>"$CALLS"; exit 127'
  printf '#!/usr/bin/env bash\necho "brew-jq" >>"$CALLS"\nexec %q "$@"\n' "$(command -v jq)" >"$BREW/jq"
  chmod +x "$BREW/jq"
  PATH="$STUBS:$PATH"
}

_run() { run bash "$SCRIPT"; }
_serves() { grep -o 'serve --service=svc:[a-z-]*' "$CALLS" | sed 's/.*=//' | tr '\n' ' '; }
_with_openseo() { : >"$OPENSEO_ENV_DIR/local.env"; }
_never() { ! grep -qE "$1" "$CALLS"; }

@test "a host other than the expected one exits 0 with a NOTE and binds nothing" {
  STUB_HOST=somewhere-else _run
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE: tailscale-serve-setup is bigdaddy's config; this host is somewhere-else"* ]]
  _never "tailscale serve"
}

@test "with every upstream healthy and OpenSEO running, it binds ollama, codex-proxy, then openseo" {
  _with_openseo
  _run
  [ "$status" -eq 0 ]
  [ "$(_serves)" = "svc:ollama svc:codex-proxy svc:openseo " ]
  grep -qF 'tailscale serve --service=svc:openseo --https=443 --yes http://127.0.0.1:8946' "$CALLS"
}

@test "without an OpenSEO env file it binds the first two, prints a NOTE, and exits 0" {
  _run
  [ "$status" -eq 0 ]
  [ "$(_serves)" = "svc:ollama svc:codex-proxy " ]
  [[ "$output" == *"NOTE:"*"does not run OpenSEO. Skipping svc:openseo"* ]]
  _never 8946
}

@test "with OpenSEO unhealthy the first two stay bound and it fails naming openseo-deploy.sh up" {
  _with_openseo
  STUB_HEALTH=issues _run
  [ "$status" -ne 0 ]
  [ "$(_serves)" = "svc:ollama svc:codex-proxy " ]
  [[ "$output" == *"ERROR:"*"openseo-deploy.sh up"* ]]
}

@test "with no account yet it binds the first two, prints the create-admin NOTE, and exits 0" {
  _with_openseo
  STUB_FIRST=true _run
  [ "$status" -eq 0 ]
  [ "$(_serves)" = "svc:ollama svc:codex-proxy " ]
  [[ "$output" == *"NOTE:"*"openseo-deploy.sh create-admin"* ]]
}

@test "with no account yet and a binding in place it turns the binding off" {
  _with_openseo
  STUB_FIRST=true STUB_BOUND=1 _run
  [ "$status" -eq 0 ]
  grep -qF 'tailscale serve --service=svc:openseo --https=443 off' "$CALLS"
}

@test "jq comes from the Homebrew directory the block puts on PATH" {
  _with_openseo
  _run
  [ "$status" -eq 0 ]
  grep -q '^brew-jq$' "$CALLS"
  _never "^stub-jq-ran$"
}

@test "an Ollama proxy that is down fails before any binding" {
  _with_openseo
  STUB_OLLAMA=down _run
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"*"not responding"* ]]
  _never "tailscale serve"
}

@test "a codex-proxy that is down fails after ollama is bound and before openseo" {
  _with_openseo
  STUB_CODEX=down _run
  [ "$status" -eq 1 ]
  [ "$(_serves)" = "svc:ollama " ]
}
