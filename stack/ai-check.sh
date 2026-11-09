#!/usr/bin/env bash
# Why can't I reach the `ai` VM or n8n, and what failed in n8n lately? Run on a laptop on the tailnet.
#
#   bash stack/ai-check.sh [--days N]      # N = how far back to list failed executions (default 7)
#
# Checks four layers in order and stops at the first one that is down, because every layer
# above it would fail for the same reason:
#   1. this machine   is it online at all? (DNS, HTTPS, Tailscale's own netcheck)
#   2. tailnet        does `ai` answer over Tailscale? (tailscale ping)
#   3. n8n            does n8n answer on :5678? (/healthz)
#   4. executions     which runs failed in the last N days (n8n API)
#
# Settings: N8N_URL (default http://ai:5678), AI_HOST (default ai). The API key comes from
# N8N_API_KEY or ~/.config/ai-n8n-api-key, like n8n-chatbot's tools/n8n-sync.py, and is never
# printed. Needs bash, curl, tailscale and python3. Exit 0 = all good, 1 = something to fix,
# 2 = wrong arguments.
# How to read the output: docs/TROUBLESHOOTING.md.

set -uo pipefail

DAYS=7
case "${1:-}" in
  --days) DAYS=${2:-} ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--days N]" >&2; exit 2 ;;
esac
[[ $DAYS =~ ^[0-9]+$ ]] || { echo "--days needs a whole number" >&2; exit 2; }

N8N_URL=${N8N_URL:-http://ai:5678}
N8N_URL=${N8N_URL%/}
AI_HOST=${AI_HOST:-ai}

ok()   { printf '  ok    %s\n' "$*"; }
info() { printf '  info  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; }
stop() {  # layer hint...
  echo
  echo "Stopped at layer $1. Layers above it can't be checked until this one works."
  shift
  printf '  %s\n' "$@"
  exit 1
}

echo "==> 1. This machine: is it online?"
if command -v nmcli >/dev/null; then
  nets=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null |
    awk -F: '$2 ~ /wireless|ethernet/ {print $1}' | paste -sd, -)
  info "connected to: ${nets:-nothing}"
fi
down=0
if getent hosts github.com >/dev/null; then ok "DNS resolves github.com"; else fail "DNS can't resolve github.com"; down=1; fi
code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' https://github.com)
if [[ $code != 000 ]]; then ok "HTTPS to github.com answers ($code)"; else fail "HTTPS to github.com gets no answer"; down=1; fi
netcheck=$(timeout 25 tailscale netcheck 2>/dev/null)
udp=$(sed -n 's/^[[:space:]]*\* UDP: //p' <<<"$netcheck")
derp=$(sed -n 's/^[[:space:]]*\* Nearest DERP: //p' <<<"$netcheck")
if [[ $udp == true ]]; then ok "Tailscale netcheck: UDP works, nearest relay ${derp:-unknown}"
else warn "Tailscale netcheck: UDP ${udp:-unknown}, nearest relay ${derp:-none}"; fi
(( down )) && stop 1 \
  "This machine has no working internet, so nothing on the tailnet can answer either." \
  "Fix the Wi-Fi or cable first. What the Wi-Fi did recently:" \
  "  journalctl -u wpa_supplicant -u NetworkManager --since -2h | grep -iE 'beacon|lost|disconnect|activated'"

echo "==> 2. Tailnet: does $AI_HOST answer?"
listed=$(tailscale status --json 2>/dev/null | AI_HOST=$AI_HOST python3 -c '
import json, os, sys
try:
    peers = json.load(sys.stdin).get("Peer") or {}
except ValueError:  # tailscaled not running: no JSON at all
    sys.exit()
hit = [p for p in peers.values() if p.get("HostName") == os.environ["AI_HOST"]]
print(("online" if hit[0].get("Online") else "offline") if hit else "missing")')
info "Tailscale lists $AI_HOST as: ${listed:-unknown} (the coordination server's view, not proof)"
pings=$(tailscale ping -c 3 --timeout 5s "$AI_HOST" 2>&1)
pongs=$(grep -c '^pong from' <<<"$pings")
if (( pongs > 0 )); then
  via=$(grep -m1 -o 'via [^ ]*' <<<"$pings")
  ok "$pongs of 3 pings answered, ${via:-via unknown path}"
else
  fail "no answer to 3 pings"
  if [[ -z $listed ]]; then
    stop 2 "Tailscale isn't running on this machine, so no tailnet name can answer." \
      "Start it: sudo systemctl start tailscaled && tailscale up"
  fi
  if [[ $listed == online ]]; then
    stop 2 "Tailscale says $AI_HOST is online but it doesn't answer: the path is broken, or the VM is hung." \
      "On this machine: journalctl -u tailscaled --since -1h | grep -E 'timeout opening|lastRecv'" \
      "  (a growing lastRecv means nothing has arrived from $AI_HOST for that long)." \
      "Then look at VM 101 in the Proxmox web UI on pve:8006 (running? console responsive?)."
  fi
  stop 2 "$AI_HOST is not on the tailnet: the VM is off, or tailscaled stopped on it." \
    "Check VM 101 in the Proxmox web UI on pve:8006 and start it, or use its console."
fi

echo "==> 3. n8n: does $N8N_URL answer?"
reply=$(curl -s -m 10 -w '\n%{http_code}' "$N8N_URL/healthz"); rc=$?
code=${reply##*$'\n'}
if (( rc == 0 )) && [[ $code == 200 ]]; then
  ok "/healthz answers 200"
else
  case $rc in
    0)  fail "/healthz answers $code"
        stop 3 "n8n is up but unhealthy. On the VM: sudo docker logs --tail 50 n8n" ;;
    7)  fail "connection refused on ${N8N_URL#*://}"
        stop 3 "The VM answers but nothing listens there: n8n's container is stopped or restarting." \
          "On the VM (ssh oll@$AI_HOST): cd /opt/automation && sudo docker compose ps" \
          "Then: sudo docker logs --tail 50 n8n" ;;
    28) fail "no answer within 10 s"
        stop 3 "The VM answers pings but n8n doesn't: n8n is hung, or the VM is out of memory." \
          "On the VM: free -h; sudo docker stats --no-stream; sudo docker logs --tail 50 n8n" ;;
    *)  fail "curl failed with exit code $rc"
        stop 3 "Check N8N_URL (now $N8N_URL)." ;;
  esac
fi

echo "==> 4. Executions that failed in the last $DAYS days"
N8N_URL=$N8N_URL DAYS=$DAYS python3 - <<'PY'
import json, os, sys, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

key = os.environ.get("N8N_API_KEY", "").strip()
key_file = Path.home() / ".config" / "ai-n8n-api-key"
if not key and key_file.exists():
    key = key_file.read_text().strip()
if not key:
    print(f"  SKIP  no API key: set N8N_API_KEY or create {key_file}")
    sys.exit(3)

base = os.environ["N8N_URL"] + "/api/v1"
cutoff = datetime.now(timezone.utc) - timedelta(days=int(os.environ["DAYS"]))

def call(path):
    req = urllib.request.Request(base + path, headers={"X-N8N-API-KEY": key, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        print(f"  FAIL  n8n API {path.split('?')[0]}: HTTP {err.code}"
              + (" (API key wrong or revoked)" if err.code == 401 else ""))
        sys.exit(1)
    except (urllib.error.URLError, TimeoutError) as err:
        print(f"  FAIL  n8n API {path.split('?')[0]}: {getattr(err, 'reason', err)}")
        sys.exit(1)

def when(stamp):
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))

def pages(path, keep=lambda item: True):
    """Every item of a paged API list, until keep() says no (lists come newest first)."""
    found, cursor = [], None
    while True:
        sep = "&" if "?" in path else "?"
        page = call(f"{path}{sep}limit=100" + (f"&cursor={urllib.parse.quote(cursor, safe='')}" if cursor else ""))
        for item in page["data"]:
            if not keep(item):
                return found
            found.append(item)
        cursor = page.get("nextCursor")
        if not cursor:
            return found

in_window = lambda e: when(e["startedAt"]) >= cutoff
workflows = {w["id"]: w for w in pages("/workflows")}
failed = sorted(pages("/executions?status=error", in_window) + pages("/executions?status=crashed", in_window),
                key=lambda e: e["startedAt"], reverse=True)

for e in failed:
    detail = call(f"/executions/{e['id']}?includeData=true")
    result = (detail.get("data") or {}).get("resultData") or {}
    error = result.get("error") or {}
    node = (error.get("node") or {}).get("name") or result.get("lastNodeExecuted") or "?"
    text = " ".join(filter(None, [error.get("message"), error.get("description")])) or e["status"]
    name = workflows.get(e["workflowId"], {}).get("name", e["workflowId"])
    stamp = when(e["startedAt"]).astimezone().strftime("%Y-%m-%d %H:%M")
    print(f"  {stamp}  {e['mode']:<8}  {name}  [{node}]")
    print(f"        {text[:220]}")

by_hand = ("manual", "retry")  # started from the editor: tests, not outages
automatic = [e for e in failed if e["mode"] not in by_hand]
if not failed:
    print("  ok    no failed executions")
else:
    print(f"\n  {len(failed)} failed, {len(failed) - len(automatic)} of them runs started from the editor (tests).")

quiet = sorted(w["name"] for w in workflows.values()
               if w.get("active") and (w.get("settings") or {}).get("saveDataSuccessExecution") == "none")
if quiet:
    print("  info  these active workflows keep no record of successful runs, so an empty list doesn't")
    print("        prove they ran: " + ", ".join(quiet))
sys.exit(1 if automatic else 0)
PY
rc=$?

echo
if (( rc == 3 )); then
  echo "Reachable: this machine is online, $AI_HOST answers, n8n is healthy. Executions not checked (no key)."
  exit 0
fi
if (( rc )); then
  echo "n8n is reachable, but something needs a look: see above."
  exit 1
fi
echo "All good: this machine is online, $AI_HOST answers, n8n is healthy, and no automatic run failed."
