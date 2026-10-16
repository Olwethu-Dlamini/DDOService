#!/usr/bin/env python3
"""Bridge between Telegram, n8n and a mail relay, for an owner who answers
work email from Telegram.

Two jobs, one small process (Python standard library only):

1. Telegram -> n8n. Asks Telegram for new messages continuously (long
   polling, so no public URL is needed) and posts each message from the
   owner's chat to an n8n webhook with the X-Bridge-Secret header. Messages
   from anyone else are logged and dropped.

2. n8n -> mail. A tiny HTTP API on port 8025, reachable only inside the
   Docker network: POST /send with the same header and a JSON body
   {to, subject, text, cc?, in_reply_to?, references?} sends an email
   through the relay with STARTTLS. Old relays with 1024-bit keys are
   accepted (OpenSSL security level 1), because modern defaults refuse them
   and n8n's own Send Email node can't be told otherwise. GET /healthz
   answers {"ok": true} with the time of the last Telegram poll.

Settings come from the environment (the stack's .env; see .env.example):

    TELEGRAM_BOT_TOKEN   from @BotFather
    OWNER_CHAT_ID        the one chat whose messages are forwarded
    BRIDGE_SECRET        shared with n8n in both directions
    N8N_WEBHOOK          default http://n8n:5678/webhook/telegram
    LISTEN_PORT          default 8025
    SMTP_HOST, SMTP_PORT (587), SMTP_USER, SMTP_PASSWORD
    SMTP_TLS_VERIFY      default true; false for a relay whose certificate chain is broken
    SMTP_SECURITY_LEVEL  default 1 (OpenSSL level; 2 is the modern default)
    MAIL_FROM            the address mail is sent as; MAIL_FROM_NAME its display name
    SMTP_DRY_RUN         true: build and log the email, send nothing (for tests)
"""

import hmac
import json
import logging
import os
import smtplib
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage
from email.utils import formataddr, formatdate, getaddresses, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger("bridge")


def setting(name, default=None):
    value = os.environ.get(name, default)
    if value is None or value == "":
        if default is None:
            sys.exit(f"{name} is not set")
        return default
    return value


def truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


TOKEN = setting("TELEGRAM_BOT_TOKEN", "")
OWNER = setting("OWNER_CHAT_ID", "")
SECRET = setting("BRIDGE_SECRET")
N8N_WEBHOOK = setting("N8N_WEBHOOK", "http://n8n:5678/webhook/telegram")
PORT = int(setting("LISTEN_PORT", "8025"))
DRY_RUN = truthy(setting("SMTP_DRY_RUN", "false"))

state = {"last_poll": None, "forwarded": 0, "sent": 0}


# --- Telegram -> n8n ---------------------------------------------------------

def telegram(method, params, timeout=30):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{TOKEN}/{method}", data=data)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        answer = json.loads(resp.read())
    if not answer.get("ok"):
        raise RuntimeError(answer.get("description", "Telegram said no"))
    return answer["result"]


def post_n8n(update):
    req = urllib.request.Request(
        N8N_WEBHOOK,
        data=json.dumps(update).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "X-Bridge-Secret": SECRET},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def forward(update):
    message = update.get("message")
    if not message:
        return
    chat = str(message.get("chat", {}).get("id"))
    if chat != OWNER:
        log.info("dropped a message from chat %s (not the owner)", chat)
        return
    for attempt in range(1, 6):
        try:
            post_n8n(update)
            state["forwarded"] += 1
            log.info("forwarded message %s to n8n", message.get("message_id"))
            return
        except Exception as err:
            log.warning("n8n didn't take message %s (try %d): %s", message.get("message_id"), attempt, err)
            time.sleep(3 * attempt)
    log.error("gave up on message %s", message.get("message_id"))
    try:
        telegram("sendMessage", {
            "chat_id": chat,
            "reply_to_message_id": message.get("message_id"),
            "text": "⚠️ n8n didn't take that message. Is the workflow active? Send it again in a minute.",
        })
    except Exception as err:
        log.warning("couldn't warn the owner: %s", err)


def poll_telegram():
    offset = None
    log.info("polling Telegram for chat %s", OWNER)
    while True:
        try:
            params = {"timeout": 50, "allowed_updates": json.dumps(["message"])}
            if offset is not None:
                params["offset"] = offset
            for update in telegram("getUpdates", params, timeout=60):
                offset = update["update_id"] + 1
                forward(update)
            state["last_poll"] = time.time()
        except Exception as err:
            log.warning("getUpdates: %s", err)
            time.sleep(5)


# --- n8n -> mail -------------------------------------------------------------

def addresses(value):
    """'A <a@x>, b@y' -> ['A <a@x>', 'b@y'], refusing anything without an @."""
    found = []
    for name, addr in getaddresses([value or ""]):
        if "@" not in addr:
            raise ValueError(f"not an email address: {value!r}")
        found.append(formataddr((name, addr)) if name else addr)
    if not found:
        raise ValueError("no recipient")
    return found


def send_mail(req):
    sender = setting("MAIL_FROM")
    to = addresses(req.get("to"))
    cc = addresses(req["cc"]) if req.get("cc") else []
    subject = (req.get("subject") or "").strip()
    text = (req.get("text") or "").strip()
    if not subject:
        raise ValueError("no subject")
    if not text:
        raise ValueError("empty message")

    msg = EmailMessage()
    name = setting("MAIL_FROM_NAME", "")
    msg["From"] = formataddr((name, sender)) if name else sender
    msg["To"] = ", ".join(to)
    if cc:
        msg["Cc"] = ", ".join(cc)
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=sender.rsplit("@", 1)[-1])
    if req.get("in_reply_to"):
        # What makes the reply sit under the original in the other side's mailbox.
        msg["In-Reply-To"] = req["in_reply_to"]
        msg["References"] = " ".join(filter(None, [(req.get("references") or "").strip(), req["in_reply_to"]]))
    msg.set_content(text)

    if DRY_RUN:
        log.info("DRY RUN, not sent:\n%s", msg.as_string())
        return msg["Message-ID"]

    context = ssl.create_default_context()
    context.set_ciphers(f"DEFAULT:@SECLEVEL={setting('SMTP_SECURITY_LEVEL', '1')}")
    if not truthy(setting("SMTP_TLS_VERIFY", "true")):
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    with smtplib.SMTP(setting("SMTP_HOST"), int(setting("SMTP_PORT", "587")), timeout=30) as smtp:
        smtp.ehlo()
        if smtp.has_extn("starttls"):
            smtp.starttls(context=context)
            smtp.ehlo()
        user = setting("SMTP_USER", "")
        if user:
            smtp.login(user, setting("SMTP_PASSWORD"))
        smtp.send_message(msg)
    return msg["Message-ID"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quieter than the default access log
        pass

    def answer(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self):
        given = self.headers.get("X-Bridge-Secret", "")
        if hmac.compare_digest(given, SECRET):
            return True
        self.answer(403, {"ok": False, "error": "bad or missing X-Bridge-Secret"})
        return False

    def do_GET(self):
        if self.path != "/healthz":
            return self.answer(404, {"ok": False, "error": "not found"})
        age = None if state["last_poll"] is None else round(time.time() - state["last_poll"])
        self.answer(200, {"ok": True, "seconds_since_last_poll": age, **{k: state[k] for k in ("forwarded", "sent")}})

    def do_POST(self):
        if self.path != "/send":
            return self.answer(404, {"ok": False, "error": "not found"})
        if not self.authorised():
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(length) or b"{}")
            message_id = send_mail(req)
        except (ValueError, KeyError) as err:
            log.warning("refused a send: %s", err)
            return self.answer(400, {"ok": False, "error": str(err)})
        except Exception as err:
            log.error("send failed: %s", err)
            return self.answer(502, {"ok": False, "error": f"{type(err).__name__}: {err}"})
        state["sent"] += 1
        log.info("sent %s to %s%s", message_id, req.get("to"), " (dry run)" if DRY_RUN else "")
        self.answer(200, {"ok": True, "message_id": message_id})


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info("listening on :%d%s", PORT, " (SMTP dry run)" if DRY_RUN else "")
    if TOKEN and OWNER:
        poll_telegram()
    else:
        log.warning("TELEGRAM_BOT_TOKEN or OWNER_CHAT_ID not set: only the /send API runs")
        threading.Event().wait()


if __name__ == "__main__":
    main()
