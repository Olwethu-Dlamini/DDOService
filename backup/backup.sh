#!/usr/bin/env bash
# Back up the automation stack (Qdrant collections, n8n data, stack config)
# and upload it to an rclone remote: Google Drive, SFTP, Nextcloud, S3...
# Replaces the guide's Part 6 backup.sh. See backup/README.md.
#
#   sudo automation-backup             # run a backup now
#   sudo automation-backup --install   # run it daily at 03:30 (systemd timer)
#
# Settings live in /etc/automation-backup.env (all optional):
#   REMOTE=backup:          rclone remote (and optional path) to upload to; blank = local only
#   KEEP_LOCAL_DAYS=7
#   KEEP_REMOTE_DAYS=30

set -euo pipefail

STACK_DIR=/opt/automation
BACKUP_ROOT=/var/backups/automation
CONF=/etc/automation-backup.env
REMOTE=""
KEEP_LOCAL_DAYS=7
KEEP_REMOTE_DAYS=30
# shellcheck disable=SC1090
[[ -f $CONF ]] && source "$CONF"

log() { echo "[$(date '+%F %T')] $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: su -  (or sudo $0)" >&2
  exit 1
fi

if [[ ${1:-} == --install ]]; then
  cat > /etc/systemd/system/automation-backup.service <<'EOF'
[Unit]
Description=Back up the automation stack
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/automation-backup
EOF
  cat > /etc/systemd/system/automation-backup.timer <<'EOF'
[Unit]
Description=Daily automation stack backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now automation-backup.timer
  systemctl list-timers automation-backup.timer --no-pager
  exit 0
fi

for cmd in docker curl jq; do
  command -v "$cmd" &>/dev/null || { echo "Missing $cmd: apt install -y $cmd" >&2; exit 1; }
done
if [[ -n $REMOTE ]] && ! command -v rclone &>/dev/null; then
  echo "REMOTE is set but rclone is missing: see backup/README.md step 1" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$STACK_DIR/.env"
STAMP=$(date +%Y-%m-%d_%H%M)
DEST=$BACKUP_ROOT/$STAMP
mkdir -p "$DEST/qdrant"
chmod 700 "$BACKUP_ROOT"

# 1. Qdrant: one snapshot per collection, using Qdrant's own snapshot API so
#    the copy is consistent while Qdrant keeps running.
Q=http://localhost:6333
QH=(-H "api-key: $QDRANT_API_KEY")
collections=$(curl -fsS "${QH[@]}" "$Q/collections" | jq -r '.result.collections[].name')
if [[ -z $collections ]]; then
  log "Qdrant: no collections yet"
fi
for c in $collections; do
  snap=$(curl -fsS -X POST "${QH[@]}" "$Q/collections/$c/snapshots?wait=true" | jq -r '.result.name')
  curl -fsS "${QH[@]}" "$Q/collections/$c/snapshots/$snap" -o "$DEST/qdrant/$c.snapshot"
  curl -fsS -X DELETE "${QH[@]}" "$Q/collections/$c/snapshots/$snap" >/dev/null
  log "Qdrant: $c -> $(du -h "$DEST/qdrant/$c.snapshot" | cut -f1)"
done

# 2. n8n: portable JSON exports, then a full copy of its data volume
#    (SQLite database + the encryption key that unlocks saved credentials).
docker exec n8n sh -c 'rm -rf /tmp/export && mkdir -p /tmp/export'
docker exec n8n n8n export:workflow --all --output=/tmp/export/workflows.json >/dev/null \
  || log "n8n: no workflows to export"
docker exec n8n n8n export:credentials --all --output=/tmp/export/credentials.json >/dev/null \
  || log "n8n: no credentials to export"
docker cp n8n:/tmp/export "$DEST/n8n-export" >/dev/null
docker exec n8n rm -rf /tmp/export

# n8n is stopped for a few seconds so the SQLite file is copied whole.
N8N_VOL=$(docker inspect n8n --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Name}}{{end}}{{end}}')
trap 'docker compose -f "$STACK_DIR/docker-compose.yml" start n8n >/dev/null' EXIT
docker compose -f "$STACK_DIR/docker-compose.yml" stop n8n >/dev/null
docker run --rm -v "$N8N_VOL":/data:ro -v "$DEST":/out alpine \
  tar czf /out/n8n_data.tar.gz -C /data .
docker compose -f "$STACK_DIR/docker-compose.yml" start n8n >/dev/null
trap - EXIT
log "n8n: $(du -h "$DEST/n8n_data.tar.gz" | cut -f1)"

# 3. Stack config (.env holds the Qdrant API key).
cp "$STACK_DIR/docker-compose.yml" "$STACK_DIR/.env" "$DEST/"
chmod -R go-rwx "$DEST"

# Ollama models are not backed up: `ollama pull mistral` gets them back.

# 4. Upload, then prune old copies on both sides.
if [[ -n $REMOTE ]]; then
  if [[ $REMOTE == *: ]]; then target="$REMOTE$STAMP"; else target="${REMOTE%/}/$STAMP"; fi
  log "Uploading to $target"
  rclone copy "$DEST" "$target"
  rclone delete --min-age "${KEEP_REMOTE_DAYS}d" "$REMOTE"
  rclone rmdirs --leave-root "$REMOTE"
else
  log "REMOTE not set: backup kept on this VM only"
fi

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+$KEEP_LOCAL_DAYS" -exec rm -rf {} +

log "Done: $DEST ($(du -sh "$DEST" | cut -f1))"
