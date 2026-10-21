#!/usr/bin/env bash
# Check the public webhook hostname from outside the tailnet (any machine with curl).
#
#   bash public-webhook-check.sh [https://n8n.22112002.xyz]
#
# Passes when only webhooks are public and each one refuses a call without its
# secret: the editor, login, REST API and health page answer 404 (Caddy on srv1),
# and every production webhook answers 403 (n8n's header auth).

set -uo pipefail

BASE=${1:-https://n8n.22112002.xyz}
BASE=${BASE%/}
fail=0

check() {  # expected method path [curl args...]
  local want=$1 method=$2 path=$3; shift 3
  local got
  got=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X "$method" "$@" "$BASE$path")
  if [[ $got == "$want" ]]; then
    printf '  ok    %s %-32s %s\n' "$method" "$path" "$got"
  else
    printf '  FAIL  %s %-32s %s (want %s)\n' "$method" "$path" "$got" "$want"
    fail=1
  fi
}

echo "==> Private paths must be hidden ($BASE)"
for p in / /signin /home/workflows /rest/settings /rest/login /api/v1/workflows /healthz /metrics; do
  check 404 GET "$p"
done

echo "==> Webhooks must refuse a call without their secret"
for p in work-email telegram whatsapp; do
  check 403 POST "/webhook/$p" -H 'Content-Type: application/json' -d '{}'
done

echo
if (( fail )); then
  echo "Something is exposed or open that should not be. See docs/PUBLIC-WEBHOOKS.md."
  exit 1
fi
echo "All good: only webhooks are public, and they check their secret."
