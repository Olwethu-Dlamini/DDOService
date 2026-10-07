#!/usr/bin/env bash
# Create the shared n8n credentials from /opt/automation/.env, so each
# secret goes from the VM's .env straight into n8n and is never copied
# anywhere else.
#
#   wget -qO- https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/stack/n8n-credentials.sh | sudo bash
#
# Asks for an n8n API key (n8n: Settings > n8n API > Create API key).
# Safe to re-run: a credential that already exists is updated in place,
# so workflows that use it keep working.

set -euo pipefail

DIR=/opt/automation
API=http://localhost:5678/api/v1

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: su -  (or sudo bash $0)" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$DIR/.env"

# stdin is this script when piped from wget, so read the key from the terminal.
read -rsp "n8n API key: " KEY </dev/tty
echo

existing=$(curl -fsS -H "X-N8N-API-KEY: $KEY" "$API/credentials?limit=250") || {
  echo "n8n rejected the API key, or isn't running on $API" >&2
  exit 1
}

# upsert NAME TYPE DATA_JSON
upsert() {
  local name=$1 type=$2 data=$3 id
  id=$(grep -o "\"id\":\"[^\"]*\",\"name\":\"${name}\"" <<<"$existing" | head -1 | cut -d'"' -f4 || true)
  if [[ -n $id ]]; then
    curl -fsS -o /dev/null -X PATCH -H "X-N8N-API-KEY: $KEY" -H 'Content-Type: application/json' \
      "$API/credentials/$id" -d "{\"name\":\"$name\",\"type\":\"$type\",\"data\":$data}"
    echo "  updated  $name"
  else
    id=$(curl -fsS -X POST -H "X-N8N-API-KEY: $KEY" -H 'Content-Type: application/json' \
      "$API/credentials" -d "{\"name\":\"$name\",\"type\":\"$type\",\"data\":$data}" | cut -d'"' -f4)
    echo "  created  $name"
  fi
  # n8n can test some credential types; header auth has nothing to connect to.
  if [[ $type != httpHeaderAuth ]]; then
    printf '           test: '
    curl -sS -X POST -H "X-N8N-API-KEY: $KEY" "$API/credentials/$id/test"
    echo
  fi
}

echo "==> Shared credentials"
upsert "Ollama (local)" ollamaApi '{"baseUrl":"http://ollama:11434"}'
upsert "Qdrant (local)" qdrantApi "{\"qdrantUrl\":\"http://qdrant:6333\",\"apiKey\":\"$QDRANT_API_KEY\"}"
upsert "WAHA" httpHeaderAuth "{\"name\":\"X-Api-Key\",\"value\":\"$WAHA_API_KEY\"}"
upsert "WAHA webhook secret" httpHeaderAuth "{\"name\":\"X-Waha-Secret\",\"value\":\"$WAHA_HOOK_SECRET\"}"
echo "Done. Workflows refer to these by name; see the n8n-chatbot repo's README."
