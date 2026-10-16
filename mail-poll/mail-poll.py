#!/usr/bin/env python3
"""Tell n8n about new email in a POP3 mailbox: one webhook POST per new message.

For mail servers that n8n's IMAP trigger can't follow. It runs once a minute
from a systemd timer (see install.sh), lists the mailbox with POP3's UIDL,
reads the start of each message it hasn't seen (TOP n BODY_LINES: the headers
and the first lines of the body, never a whole attachment), and posts each
one's From, To, Subject, Date, Message-ID, References and the beginning of
its text to n8n. It never deletes a message or marks it read, so it can share
the mailbox with a mail client that also uses POP3.

The first run records what is already in the mailbox and posts nothing, so
turning it on doesn't send an alert for every old message.

Settings come from the environment (on the server: /etc/mail-poll.env):

    MAIL_HOST        POP3 server
    MAIL_PORT        default 110 (plain POP3; 995 switches to TLS)
    MAIL_USER        login
    MAIL_PASSWORD    or MAIL_PASSWORD_FILE, a file holding only the password
    WEBHOOK_URL      n8n webhook to POST to
    WEBHOOK_SECRET   sent as the X-Mail-Secret header; n8n rejects anything without it
    STATE_FILE       ids already seen (default: $STATE_DIRECTORY/seen.json, else ./seen.json)
    BODY_LINES       lines of each message fetched after the headers (default 400; 0 = headers only)
    BODY_CHARS       characters of text posted as "body" (default 1500)

    mail-poll.py                 check once and post new mail
    mail-poll.py --dry-run       print new mail; post nothing, remember nothing
    mail-poll.py --latest 3      print the newest 3 messages' headers and stop

Python standard library only.
"""

import argparse
import email.parser
import email.policy
import html
import json
import os
import poplib
import re
import sys
import urllib.request
from pathlib import Path

TIMEOUT = 30
HEADER_FIELDS = ("From", "To", "Cc", "Reply-To", "Subject", "Date", "Message-ID", "References")


def setting(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        sys.exit(f"{name} is not set")
    return value


def password():
    path = os.environ.get("MAIL_PASSWORD_FILE")
    if path:
        return Path(path).read_text().strip()
    return setting("MAIL_PASSWORD")


def connect():
    host, port = setting("MAIL_HOST"), int(setting("MAIL_PORT", "110"))
    pop = (poplib.POP3_SSL if port == 995 else poplib.POP3)(host, port, timeout=TIMEOUT)
    pop.user(setting("MAIL_USER"))
    pop.pass_(password())
    return pop


def mailbox(pop):
    """[(message number, unique id)] in server order, oldest first."""
    _, lines, _ = pop.uidl()
    pairs = []
    for line in lines:
        num, uid = line.decode().split(maxsplit=1)
        pairs.append((int(num), uid))
    return pairs


def text_of(msg):
    """The message's text: its text/plain part, else its HTML with the tags
    stripped, else nothing. Only the first lines were fetched, so a part may
    end mid-way; the parser copes and the text is simply cut there."""
    plain, rich = None, None
    for part in msg.walk():
        if part.get_content_maintype() != "text" or part.get_content_disposition() == "attachment":
            continue
        try:
            content = part.get_content()
        except Exception:
            try:
                content = part.get_payload(decode=True).decode(part.get_content_charset() or "utf-8", "replace")
            except Exception:
                continue
        if part.get_content_subtype() == "plain" and plain is None:
            plain = content
        elif part.get_content_subtype() == "html" and rich is None:
            rich = content
    if plain is None and rich is not None:
        rich = re.sub(r"(?is)<(script|style).*?</\1>", "", rich)
        rich = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>", "\n", rich)
        plain = html.unescape(re.sub(r"<[^>]+>", "", rich))
    if plain is None:
        return ""
    # Collapse the whitespace that HTML and quoted-printable leave behind.
    plain = plain.replace("\r\n", "\n")
    plain = re.sub(r"[ \t]+\n", "\n", plain)
    plain = re.sub(r"\n{3,}", "\n\n", plain)
    return plain.strip()


def message(pop, num):
    """The fields n8n gets for one message. BODY_LINES=0 posts headers only."""
    body_lines = int(setting("BODY_LINES", "400"))
    body_chars = int(setting("BODY_CHARS", "1500"))
    _, lines, _ = pop.top(num, body_lines)
    raw = b"\r\n".join(lines)
    parser = email.parser.BytesParser if body_lines else email.parser.BytesHeaderParser
    msg = parser(policy=email.policy.default).parsebytes(raw)

    def get(name):
        # The default policy decodes =?UTF-8?B?...?= words; a malformed header
        # makes it raise, and then the raw text is better than nothing.
        try:
            return str(msg.get(name, "")).strip()
        except Exception:
            return str(msg.get_all(name, [""])[0]).strip()

    item = {k.lower(): get(k) for k in HEADER_FIELDS}
    text = text_of(msg) if body_lines else ""
    item["body"] = text[:body_chars]
    item["body_truncated"] = len(text) > body_chars or bool(body_lines and len(lines) >= body_lines)
    return item


def post(item):
    req = urllib.request.Request(
        setting("WEBHOOK_URL"),
        data=json.dumps(item).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "X-Mail-Secret": setting("WEBHOOK_SECRET")},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        resp.read()


def state_path():
    default = Path(os.environ.get("STATE_DIRECTORY", ".")) / "seen.json"
    return Path(os.environ.get("STATE_FILE", default))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--latest", type=int, metavar="N")
    args = ap.parse_args()

    pop = connect()
    try:
        box = mailbox(pop)
        if args.latest:
            for num, _ in box[-args.latest:]:
                print(json.dumps(message(pop, num), ensure_ascii=False))
            return

        path = state_path()
        on_server = {uid for _, uid in box}
        if not path.exists():
            if not args.dry_run:
                path.write_text(json.dumps({"seen": sorted(on_server)}))
            print(f"First run: {len(box)} messages already in the mailbox, recorded as seen")
            return

        seen = set(json.loads(path.read_text())["seen"])
        new = [(num, uid) for num, uid in box if uid not in seen]
        posted = set()
        try:
            for num, uid in new:
                item = message(pop, num)
                if args.dry_run:
                    print(json.dumps(item, ensure_ascii=False))
                    continue
                post(item)
                posted.add(uid)
                print(f"posted: {item['from']} | {item['subject']}")
        finally:
            # Remember what was posted even if a later message failed, so a
            # retry next minute doesn't send it twice. Forget ids no longer
            # on the server, so the file doesn't grow forever.
            if not args.dry_run:
                path.write_text(json.dumps({"seen": sorted((seen | posted) & on_server)}))
        if not new:
            print(f"No new mail ({len(box)} in the mailbox)")
    finally:
        try:
            pop.quit()
        except Exception:
            pass


if __name__ == "__main__":
    main()
