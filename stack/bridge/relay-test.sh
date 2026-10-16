#!/usr/bin/env bash
# Try the mail relay login with the password the bridge container already
# has. No typing, prints no secret: only the password's length and its first
# and last character, so a paste mistake shows up. Then the bridge's last log
# lines.
#
#   wget -q https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/stack/bridge/relay-test.sh
#   sudo bash relay-test.sh

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0" >&2; exit 1; }
docker ps --filter name=bridge --format "bridge container: {{.Status}}" | grep . || {
  echo "The bridge container isn't running: cd /opt/automation && docker compose --profile telegram up -d bridge" >&2
  exit 1
}
# -i: the test program arrives on stdin.
docker exec -i bridge python - <<'PY' 2>&1
import os, smtplib, ssl
u, pw = os.environ.get("SMTP_USER", ""), os.environ.get("SMTP_PASSWORD", "")
print(f"saved login: user {u!r}, password {len(pw)} characters, first {pw[:1]!r}, last {pw[-1:]!r}")
try:
    ctx = ssl.create_default_context()
    ctx.set_ciphers("DEFAULT:@SECLEVEL=" + os.environ.get("SMTP_SECURITY_LEVEL", "1"))
    if os.environ.get("SMTP_TLS_VERIFY", "true").lower() not in ("1", "true", "yes", "on"):
        ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    s = smtplib.SMTP(os.environ.get("SMTP_HOST"), int(os.environ.get("SMTP_PORT", "587")), timeout=30)
    s.ehlo(); s.starttls(context=ctx); s.ehlo()
    print("relay offers:", s.esmtp_features.get("auth"))
    s.user, s.password = u, pw          # what auth_plain / auth_login read
    for method in ("plain", "login"):
        try:
            s.auth(method, getattr(s, "auth_" + method)); print(f"AUTH {method.upper()}: OK"); break
        except smtplib.SMTPAuthenticationError as e:
            print(f"AUTH {method.upper()}: REFUSED {e.smtp_code} {e.smtp_error.decode(errors='replace')}")
            s.ehlo()
    s.quit()
except Exception as e:
    print("TEST FAILED:", type(e).__name__, e)
PY
echo "==> bridge log, last 6 lines"
docker logs bridge --tail 6 2>&1
