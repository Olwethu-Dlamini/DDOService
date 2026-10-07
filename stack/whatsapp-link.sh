#!/usr/bin/env bash
# Link a WhatsApp number to WAHA's "default" session with a pairing code:
# no dashboard and no QR scan.
#
#   wget -qO- https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/stack/whatsapp-link.sh | sudo bash
#
# Asks for the number, prints an 8-character code, and waits while you
# enter it on the phone: WhatsApp > Settings > Linked devices > Link a
# device > "Link with phone number instead". Safe to re-run: it creates
# or starts the session as needed, and stops if it's already linked.

set -euo pipefail

DIR=/opt/automation
API=${WAHA_URL:-http://localhost:3000}/api
SESSION=default

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: su -  (or sudo bash $0)" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$DIR/.env"
H=(-H "X-Api-Key: $WAHA_API_KEY" -H "Content-Type: application/json")

status() {
  curl -fsS "${H[@]}" "$API/sessions/$SESSION" 2>/dev/null |
    grep -o '"status":"[A-Z_]*"' | head -1 | cut -d'"' -f4 || true
}

wait_for() { # wait_for STATUS SECONDS
  local want=$1 s
  for _ in $(seq 1 "$2"); do
    s=$(status)
    [[ $s == "$want" ]] && return 0
    [[ $s == FAILED ]] && { echo "Session FAILED; see: docker logs waha" >&2; exit 1; }
    sleep 1
  done
  return 1
}

current=$(status)
case $current in
  WORKING)
    echo "Session '$SESSION' is already linked:"
    curl -fsS "${H[@]}" "$API/sessions/$SESSION" | grep -o '"me":{[^}]*}'
    exit 0 ;;
  "")
    echo "==> Creating session '$SESSION'"
    curl -fsS "${H[@]}" -X POST "$API/sessions" -d "{\"name\":\"$SESSION\",\"start\":true}" >/dev/null ;;
  SCAN_QR_CODE | STARTING) ;;
  *)
    echo "==> Starting session '$SESSION' (was $current)"
    curl -fsS "${H[@]}" -X POST "$API/sessions/$SESSION/start" >/dev/null ;;
esac

printf '==> Waiting for WhatsApp to accept a new device'
wait_for SCAN_QR_CODE 60 || { echo; echo "Still '$(status)' after 60s; see: docker logs waha" >&2; exit 1; }
echo

read -rp "Your WhatsApp number with country code, digits only (e.g. 26876123456): " PHONE </dev/tty
PHONE=$(tr -cd '0-9' <<<"$PHONE")
if [[ ! $PHONE =~ ^[1-9][0-9]{9,14}$ ]]; then
  echo "That isn't a full number with country code." >&2
  exit 1
fi

reply=$(curl -sS "${H[@]}" -X POST "$API/$SESSION/auth/request-code" -d "{\"phoneNumber\":\"$PHONE\"}")
code=$(grep -o '"code":"[^"]*"' <<<"$reply" | cut -d'"' -f4 || true)
if [[ -z $code ]]; then
  echo "WhatsApp didn't give a pairing code: $reply" >&2
  echo "Fallback: scan the QR code in the dashboard, http://${N8N_HOST:-ai}:3000/dashboard" >&2
  exit 1
fi

cat <<EOF

    Pairing code:  $code

On the phone, now (the code expires quickly):
  WhatsApp > Settings > Linked devices > Link a device
  > "Link with phone number instead" > type the code

EOF
printf '==> Waiting for the phone (3 minutes)'
if wait_for WORKING 180; then
  echo
  echo "Linked:"
  curl -fsS "${H[@]}" "$API/sessions/$SESSION" | grep -o '"me":{[^}]*}'
  echo "Test it: send #ping in WhatsApp's \"Message yourself\" chat."
else
  echo
  echo "Not linked yet (status $(status)). Run this script again for a new code." >&2
  exit 1
fi
