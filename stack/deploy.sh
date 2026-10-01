#!/usr/bin/env bash
# Deploy the automation stack (Qdrant + Ollama + n8n) to /opt/automation,
# pull the model, then run the guide's Part 5 checks.
#
#   sudo bash deploy.sh
#
# Safe to re-run: keeps an existing .env (and its Qdrant key) and only
# refreshes docker-compose.yml.

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

echo "==> Fetching compose file"
curl -fsSL "$RAW/docker-compose.yml" -o docker-compose.yml

if [[ ! -f .env ]]; then
  echo "==> Creating .env with a new Qdrant API key"
  curl -fsSL "$RAW/.env.example" -o .env
  sed -i "s/^QDRANT_API_KEY=.*/QDRANT_API_KEY=$(openssl rand -hex 32)/" .env
  chmod 600 .env
else
  echo "==> Keeping existing .env"
fi
# shellcheck disable=SC1091
source .env

echo "==> Pulling images"
docker compose pull

echo "==> Starting stack"
docker compose up -d

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

echo
echo "==> Checks"
printf '  Qdrant:  '; curl -fs http://localhost:6333/healthz || echo "NOT OK"; echo
printf '  Ollama:  '; docker exec ollama ollama list | tail -n +2 | awk '{print $1, $3, $4}' | paste -sd' ' || echo "NOT OK"
printf '  n8n:     '; curl -fs http://localhost:5678/healthz || echo "NOT OK"; echo
echo
docker compose ps
echo
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'

echo
echo "Done."
echo "  n8n:              http://${N8N_HOST:-ai}:5678   (create the owner account on first visit)"
echo "  Qdrant dashboard: http://${N8N_HOST:-ai}:6333/dashboard   (API key in $DIR/.env)"
echo "  In n8n, use Qdrant URL http://qdrant:6333 and Ollama URL http://ollama:11434"
