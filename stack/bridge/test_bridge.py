#!/usr/bin/env python3
"""Tests for the bridge's /send, in SMTP dry run: nothing leaves the machine.

    python3 stack/bridge/test_bridge.py
"""

import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

os.environ.update({
    "BRIDGE_SECRET": "test-secret",
    "SMTP_DRY_RUN": "true",
    "MAIL_FROM": "owner@example.com",
    "MAIL_COPY_TO": "self",
    "LISTEN_PORT": "0",
})
sys.path.insert(0, str(Path(__file__).parent))
import bridge  # noqa: E402


class SendMail(unittest.TestCase):
    def send(self, **req):
        return bridge.send_mail({"subject": "Re: Budget", "text": "Noted.", **req})

    def test_reply_all_keeps_the_others_in_cc(self):
        sent = self.send(to="Sipho <sipho@example.com>", cc="Thandi <thandi@example.com>, bob@example.com")
        self.assertEqual(sent["to"], ["Sipho <sipho@example.com>"])
        self.assertEqual(sent["cc"], ["Thandi <thandi@example.com>", "bob@example.com"])

    def test_own_address_is_dropped_from_cc(self):
        sent = self.send(to="sipho@example.com", cc="Owner <OWNER@example.com>, bob@example.com")
        self.assertEqual(sent["cc"], ["bob@example.com"])

    def test_to_and_repeats_are_dropped_from_cc(self):
        sent = self.send(to="sipho@example.com", cc="Sipho <sipho@example.com>, bob@example.com, BOB@example.com")
        self.assertEqual(sent["cc"], ["bob@example.com"])

    def test_no_cc(self):
        self.assertEqual(self.send(to="sipho@example.com")["cc"], [])
        self.assertEqual(self.send(to="sipho@example.com", cc="")["cc"], [])

    def test_bad_cc_is_refused(self):
        with self.assertRaises(ValueError):
            self.send(to="sipho@example.com", cc="not an address")

    def test_headers(self):
        captured = {}
        original = bridge.log.info
        bridge.log.info = lambda fmt, *args: captured.setdefault("text", args[0] if args else fmt)
        try:
            self.send(to="sipho@example.com", cc="bob@example.com", in_reply_to="<a@x>", references="<z@x>")
        finally:
            bridge.log.info = original
        text = captured["text"]
        self.assertIn("To: sipho@example.com", text)
        self.assertIn("Cc: bob@example.com", text)
        self.assertIn("Bcc: owner@example.com", text)      # the copy for the owner's mailbox
        self.assertIn("In-Reply-To: <a@x>", text)
        self.assertIn("References: <z@x> <a@x>", text)
        self.assertIn(".bridge@example.com", text)          # what the alert workflow skips on


class SendApi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = bridge.ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/send"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def post(self, body, secret="test-secret"):
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "X-Bridge-Secret": secret})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

    def test_answer_names_the_recipients(self):
        code, body = self.post({"to": "sipho@example.com", "cc": "owner@example.com, bob@example.com",
                                "subject": "Re: Budget", "text": "Noted."})
        self.assertEqual(code, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["to"], ["sipho@example.com"])
        self.assertEqual(body["cc"], ["bob@example.com"])
        self.assertIn(".bridge@", body["message_id"])

    def test_wrong_secret(self):
        code, _ = self.post({"to": "sipho@example.com", "subject": "x", "text": "y"}, secret="nope")
        self.assertEqual(code, 403)


if __name__ == "__main__":
    unittest.main(verbosity=2)
