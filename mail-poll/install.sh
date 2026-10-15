#!/usr/bin/env bash
# Install mail-poll: every minute, post each new email's headers to n8n.
#
#   wget -q https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/mail-poll/install.sh
#   sudo bash install.sh
#
# Asks for the mailbox, its password and the n8n webhook secret, then runs
# mail-poll.py from a systemd timer. The password is stored in a root-only
# file and handed to the poller as a systemd credential. The poller runs as
# a throwaway user (DynamicUser) and never sees the rest of the system.
# Safe to re-run: it replaces the settings and the script.
#
#   journalctl -u mail-poll -f          watch it
#   systemctl list-timers mail-poll     when it runs next

set -euo pipefail

RAW=https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/mail-poll
ENV=/etc/mail-poll.env
PASS=/etc/mail-poll.pass

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

command -v python3 >/dev/null || apt-get install -y python3-minimal

# stdin may be this script, so read answers from the terminal.
ask() { # ask VAR PROMPT [DEFAULT]
  local reply
  read -rp "$2${3:+ [$3]}: " reply </dev/tty
  printf -v "$1" '%s' "${reply:-${3:-}}"
}
ask HOST "POP3 server"
ask PORT "POP3 port" 110
ask USER_ "Login (usually the full email address)"
read -rsp "Password (hidden): " PW </dev/tty
echo
ask URL "n8n webhook" "http://localhost:5678/webhook/work-email"
read -rsp "Webhook secret (hidden): " SECRET </dev/tty
echo
# A paste can carry bracketed-paste markers and stray whitespace.
SECRET=${SECRET//$'\e[200~'/}
SECRET=${SECRET//$'\e[201~'/}
SECRET=$(tr -d '[:space:]' <<<"$SECRET")
for v in HOST USER_ PW URL SECRET; do
  [[ -n ${!v} ]] || { echo "$v is empty; nothing installed." >&2; exit 1; }
done

echo "==> Script"
wget -qO /usr/local/bin/mail-poll.py "$RAW/mail-poll.py"
chmod 755 /usr/local/bin/mail-poll.py

echo "==> Settings ($ENV, $PASS: root only)"
umask 077
printf '%s' "$PW" >"$PASS"
cat >"$ENV" <<EOF
MAIL_HOST=$HOST
MAIL_PORT=$PORT
MAIL_USER=$USER_
WEBHOOK_URL=$URL
WEBHOOK_SECRET=$SECRET
EOF
umask 022

echo "==> systemd timer (every minute)"
cat >/etc/systemd/system/mail-poll.service <<'EOF'
[Unit]
Description=Post new email headers to n8n
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
DynamicUser=yes
StateDirectory=mail-poll
EnvironmentFile=/etc/mail-poll.env
LoadCredential=mail-pass:/etc/mail-poll.pass
Environment=MAIL_PASSWORD_FILE=%d/mail-pass
ExecStart=/usr/bin/python3 /usr/local/bin/mail-poll.py
TimeoutStartSec=90
MemoryMax=64M
EOF
cat >/etc/systemd/system/mail-poll.timer <<'EOF'
[Unit]
Description=Check for new email every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

# The first run only records what's already in the mailbox, so start it
# by hand and show what it said before the timer takes over.
echo "==> First run"
if systemctl start mail-poll.service; then
  journalctl -u mail-poll -n 3 --no-pager -o cat
  systemctl enable --now mail-poll.timer
  echo "Done. Send yourself an email; within a minute: journalctl -u mail-poll -n 5"
else
  journalctl -u mail-poll -n 15 --no-pager -o cat
  echo "The first run failed (above); the timer is not enabled. Fix and re-run." >&2
  exit 1
fi
