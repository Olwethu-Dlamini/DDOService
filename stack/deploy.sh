#!/usr/bin/env bash
# Deploy the automation stack (Qdrant + Ollama + n8n + WAHA + bridge + SearXNG + Vane) to /opt/automation,
# pull the model, then run the guide's Part 5 checks.
#
#   sudo bash deploy.sh
#
# Safe to re-run: keeps an existing .env and its secrets, adds any settings
# that are new since it was created, and refreshes docker-compose.yml.

set -euo pipefail

RAW="https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/stack"
DIR=/opt/automation

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: su -  (or sudo bash $0)" >&2
  exit 1
fi
command -v docker &>/dev/null || { echo "Docker missing: run docker-install.sh first" >&2; exit 1; }

mkdir -p "$DIR"
cd "$DIR"

echo "==> Fetching compose file and the bridge"
curl -fsSL "$RAW/docker-compose.yml" -o docker-compose.yml
mkdir -p bridge
curl -fsSL "$RAW/bridge/bridge.py" -o bridge/bridge.py
mkdir -p searxng
curl -fsSL "$RAW/searxng/settings.yml" -o searxng/settings.yml

curl -fsSL "$RAW/.env.example" -o .env.example
if [[ ! -f .env ]]; then
  echo "==> Creating .env"
  cp .env.example .env
else
  echo "==> Keeping existing .env, adding new settings"
  # Append any variable the template has and .env lacks (e.g. WAHA_* on an
  # older install). Existing values are never touched.
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)= ]] || continue
    grep -q "^${BASH_REMATCH[1]}=" .env || { echo "$line" >> .env; echo "    added ${BASH_REMATCH[1]}"; }
  done < .env.example
fi
# Fill every empty secret with a new random value.
for key in QDRANT_API_KEY WAHA_API_KEY WAHA_DASHBOARD_PASSWORD WAHA_HOOK_SECRET BRIDGE_SECRET SEARXNG_SECRET; do
  if grep -q "^${key}=$" .env; then
    sed -i "s/^${key}=$/${key}=$(openssl rand -hex 32)/" .env
    echo "    generated ${key}"
  fi
done
chmod 600 .env
# shellcheck disable=SC1091
source .env

# The bridge only runs when there is a Telegram bot to poll.
COMPOSE=(docker compose)
if [[ -n ${TELEGRAM_BOT_TOKEN:-} ]]; then
  COMPOSE+=(--profile telegram)
  echo "==> TELEGRAM_BOT_TOKEN is set: the bridge will run"
else
  echo "==> TELEGRAM_BOT_TOKEN is empty: the bridge stays off"
fi

echo "==> Pulling images"
"${COMPOSE[@]}" pull

echo "==> Starting stack"
"${COMPOSE[@]}" up -d

echo "==> Waiting for Ollama"
for _ in $(seq 1 30); do
  curl -fs http://localhost:11434/api/tags >/dev/null && break
  sleep 2
done

echo "==> Pulling model ${OLLAMA_MODEL:-mistral} (about 4.4GB on first run)"
docker exec ollama ollama pull "${OLLAMA_MODEL:-mistral}"

echo "==> Waiting for n8n"
for _ in $(seq 1 60); do
  curl -fs http://localhost:5678/healthz >/dev/null && break
  sleep 2
done

echo "==> Waiting for WAHA"
for _ in $(seq 1 60); do
  curl -fs -o /dev/null -H "X-Api-Key: $WAHA_API_KEY" http://localhost:3000/api/server/version && break
  sleep 2
done

echo "==> Waiting for SearXNG and Vane"
for _ in $(seq 1 30); do
  curl -fs -o /dev/null http://localhost:8888/healthz && break
  sleep 2
done
for _ in $(seq 1 60); do
  curl -fs -o /dev/null http://localhost:3001/ && break
  sleep 2
done
# Vane has no login: reach it over Tailscale only, with HTTPS from Tailscale.
if command -v tailscale &>/dev/null; then
  tailscale serve --bg --https=8443 http://127.0.0.1:3001 >/dev/null && echo "    tailscale serve: Vane on port 8443"
fi

echo
echo "==> Checks"
printf '  Qdrant:  '; curl -fs http://localhost:6333/healthz || echo "NOT OK"; echo
printf '  Ollama:  '; docker exec ollama ollama list | tail -n +2 | awk '{print $1, $3, $4}' | paste -sd' ' || echo "NOT OK"
printf '  n8n:     '; curl -fs http://localhost:5678/healthz || echo "NOT OK"; echo
printf '  WAHA:    '; curl -fs -H "X-Api-Key: $WAHA_API_KEY" http://localhost:3000/api/server/version || echo "NOT OK"; echo
if [[ -n ${TELEGRAM_BOT_TOKEN:-} ]]; then
  printf '  bridge:  '
  for _ in $(seq 1 15); do
    docker exec bridge python -c 'import urllib.request;print(urllib.request.urlopen("http://localhost:8025/healthz",timeout=3).read().decode())' 2>/dev/null && break
    sleep 2
  done || echo "NOT OK (docker logs bridge)"
fi
# A real query: SearXNG must return JSON with results, or Vane and n8n get nothing.
printf '  SearXNG: '
n=$(curl -fs 'http://localhost:8888/search?q=proxmox&format=json' | grep -o '"url":' | wc -l || true)
[[ ${n:-0} -gt 0 ]] && echo "$n results for 'proxmox'" || echo "NOT OK (no JSON results: docker logs searxng)"
printf '  Vane:    '; curl -fs -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:3001/ || echo "NOT OK (docker logs vane)"
echo
"${COMPOSE[@]}" ps
echo
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'

echo
echo "Done."
echo "  n8n:              http://${N8N_HOST:-ai}:5678   (create the owner account on first visit)"
[[ -n ${N8N_WEBHOOK_URL:-} ]] && echo "  Public webhooks:  ${N8N_WEBHOOK_URL}webhook/...   (check from any machine: stack/public-webhook-check.sh)"
echo "  Qdrant dashboard: http://${N8N_HOST:-ai}:6333/dashboard   (API key in $DIR/.env)"
echo "  WhatsApp:         http://${N8N_HOST:-ai}:3000/dashboard   (user admin, password WAHA_DASHBOARD_PASSWORD in $DIR/.env)"
echo "  In n8n, use Qdrant URL http://qdrant:6333, Ollama URL http://ollama:11434, WAHA URL http://waha:3000, SearXNG URL http://searxng:8080"
ts=$(tailscale status --self=true --peers=false --json 2>/dev/null | grep -m1 -o '"DNSName": *"[^"]*"' | cut -d'"' -f4 | sed 's/\.$//' || true)
echo "  Vane:             https://${ts:-ai.your-tailnet.ts.net}:8443   (first visit: choose Ollama, URL http://ollama:11434, and the model)"
