#!/usr/bin/env bash
# Bootstrap gogcli on a new machine using credentials from 1Password.
#
# Prerequisites: brew, op (1Password CLI) authenticated
#
# Usage: setup_gogcli.sh
set -euo pipefail

VAULT="secrets-dev"
ITEM="Google Workspace CLI OAuth (Streams)"
CONFIG_DIR="${HOME}/.config/gogcli"

echo "Installing gogcli..."
brew install gogcli 2>/dev/null || echo "  already installed"

echo "Setting up config directory..."
mkdir -p "${CONFIG_DIR}/keyring"

echo "Pulling credentials from 1Password..."
CLIENT_ID="$(op item get "$ITEM" --vault "$VAULT" --fields client_id --reveal)"
CLIENT_SECRET="$(op item get "$ITEM" --vault "$VAULT" --fields client_secret --reveal)"

# Write client_secret.json
cat > "${CONFIG_DIR}/client_secret.json" <<EOJSON
{"installed":{"client_id":"${CLIENT_ID}","project_id":"gws-agent-access","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","auth_provider_x509_cert_url":"https://www.googleapis.com/oauth2/v1/certs","client_secret":"${CLIENT_SECRET}","redirect_uris":["http://localhost"]}}
EOJSON
chmod 600 "${CONFIG_DIR}/client_secret.json"

# Write credentials.json (client ID + secret for gogcli)
cat > "${CONFIG_DIR}/credentials.json" <<EOJSON
{"client_id":"${CLIENT_ID}","client_secret":"${CLIENT_SECRET}"}
EOJSON
chmod 600 "${CONFIG_DIR}/credentials.json"

# Write config.json
cat > "${CONFIG_DIR}/config.json" <<'EOJSON'
{"keyring_backend":"file"}
EOJSON
chmod 600 "${CONFIG_DIR}/config.json"

# Restore encrypted keyring tokens
echo "Restoring encrypted keyring tokens..."
TOKEN_DEFAULT="$(op item get "$ITEM" --vault "$VAULT" --fields keyring_token_default --reveal)"
TOKEN_PLAIN="$(op item get "$ITEM" --vault "$VAULT" --fields keyring_token --reveal)"

echo "$TOKEN_DEFAULT" | base64 -d > "${CONFIG_DIR}/keyring/token:default:brett@streamsgrp.com"
echo "$TOKEN_PLAIN" | base64 -d > "${CONFIG_DIR}/keyring/token:brett@streamsgrp.com"
chmod 600 "${CONFIG_DIR}/keyring/"*

echo "Verifying connection..."
export GOG_KEYRING_PASSWORD="${CLIENT_SECRET}"
gog auth list

echo ""
echo "Done! The gog() shell wrapper is provided by config/shell/gogcli.sh."
echo "Run 'scripts/stow-deploy gogcli' to deploy, then open a new shell."
