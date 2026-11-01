"""Headless tests for nuketown-prompter's text model (no display needed).

The card itself (GTK, focus, the review landing in place, timeouts) is
covered by the vm-approval-prompter NixOS test.
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nuketown_prompter as p  # noqa: E402

REQ = {"id": "x", "requester": "ada", "origin": "agent", "run_as": {"user": "root"},
       "argv": ["sh", "-c", "ls /var/lib/nuketown-approval"], "display": "sh -c 'ls /var/lib/nuketown-approval'",
       "why": "read the saved reviews", "kind": None, "snapshots": [], "decrypt": [], "prompt_timeout": 120}

REVIEW = {"status": "ok", "headline": "Read-only, but shows ada other agents' approval records.",
          "summary": "Prints the two newest approval records.", "risk": "low", "recommendation": "approve",
          "notes": ["Output returns to ada, including other agents' requests and reviews."], "not_shown": []}


class Model(unittest.TestCase):
    def test_top(self):
        m = p.card_model(REQ, None)
        self.assertEqual(m["who"], "ada wants to run as root")
        self.assertEqual(m["why"], "Reason: read the saved reviews")
        self.assertEqual(m["kind"], "")
        m = p.card_model(dict(REQ, origin="root", requester="loom-update", run_as={"user": "bob"},
                              kind={"name": "demo"}), None)
        self.assertEqual(m["who"], "loom-update (via root) asks to run as bob")
        self.assertTrue(m["why"].startswith("Stated reason: "))
        self.assertEqual(m["kind"], "Kind: demo")

    def test_reviewed(self):
        r = p.card_model(REQ, REVIEW)["review"]
        self.assertEqual((r["state"], r["risk"], r["recommendation"]), ("ok", "low", "approve"))
        self.assertEqual(r["headline"], REVIEW["headline"])
        self.assertTrue(r["has_headline"])
        self.assertEqual(r["notes"], REVIEW["notes"])

    def test_old_review_without_headline(self):
        old = {k: v for k, v in REVIEW.items() if k != "headline"}
        r = p.review_model(old)
        self.assertEqual(r["headline"], old["summary"])
        self.assertFalse(r["has_headline"])
        r = p.review_model(dict(old, headline=""))
        self.assertEqual(r["headline"], old["summary"])
        r = p.review_model(dict(old, headline=None, notes=None, not_shown="nope"))
        self.assertEqual((r["notes"], r["not_shown"]), ([], []))

    def test_statuses(self):
        cases = [
            ({"status": "pending"}, "pending", "Reviewer is reading this request\u2026"),
            ({"status": "disabled"}, "none", "No reviewer configured."),
            ({"status": "skipped", "by": "collector", "reason": "rollback to generation 41"}, "none",
             "No review: rollback to generation 41"),
            ({"status": "skipped", "reason": "requested by the human"}, "none",
             "Not reviewed: requested by the human."),
            ({"status": "unavailable", "reason": "reviewer timed out after 6s"}, "none",
             "No review: reviewer timed out after 6s"),
            (None, "none", "No review."),
            ({"status": "something-new"}, "none", "No review: something-new"),
        ]
        for rev, state, line in cases:
            r = p.review_model(rev)
            self.assertEqual((r["state"], r["line"]), (state, line), rev)

    def test_unknown_risk(self):
        self.assertEqual(p.review_model(dict(REVIEW, risk="catastrophic"))["risk"], "unknown")

    def test_caps(self):
        m = p.card_model(dict(REQ, display="x" * 5000, why="w" * 5000),
                         dict(REVIEW, headline="h" * 900, summary="s" * 9000, notes=["n" * 900] * 3))
        self.assertEqual(len(m["command"]), 801)
        self.assertEqual(len(m["why"]), len("Reason: ") + 401)
        r = m["review"]
        self.assertEqual((len(r["headline"]), len(r["summary"]), len(r["notes"][0])), (201, 1501, 301))
        self.assertEqual(len(m["command_full"]), 5000)

    def test_text_stays_plain_and_visible(self):
        m = p.card_model(dict(REQ, why="<b>bold</b> &amp; <i>x</i>", display="echo a\nb\u202ec\x1b[31m"),
                         dict(REVIEW, headline="<span foreground='red'>x</span>", notes=["note <b>"]))
        self.assertEqual(m["why"], "Reason: <b>bold</b> &amp; <i>x</i>")
        self.assertEqual(m["command"], "echo a\\nb\\u{202e}c\\e[31m")
        self.assertEqual(m["review"]["headline"], "<span foreground='red'>x</span>")
        self.assertEqual(m["review"]["notes"], ["note <b>"])
        self.assertEqual(p.clean("a\nb\tc"), "a b c")
        self.assertEqual(p.clean("a\nb", mode="block"), "a\nb")

    def test_note(self):
        self.assertEqual(p.card_model(REQ, None, "This also unlocks secrets.")["note"], "This also unlocks secrets.")


class Contract(unittest.TestCase):
    def test_reason(self):
        self.assertEqual(p.clip_reason(" too risky\ntoday "), "too risky today")
        self.assertEqual(p.clip_reason(None), "")
        r = p.clip_reason("\u00e9" * 400)            # 2 bytes each: cut on a character
        self.assertLessEqual(len(r.encode()), 500)
        self.assertEqual(r, "\u00e9" * 250)
        self.assertEqual(len(p.clip_reason("x" * 900).encode()), 500)

    def test_timeout(self):
        self.assertEqual(p.prompt_timeout({}), 120)
        self.assertEqual(p.prompt_timeout({"prompt_timeout": 0}), 0)
        self.assertEqual(p.prompt_timeout({"prompt_timeout": 7}), 7)
        for bad in ("7", -1, 1.5, True, None):
            self.assertEqual(p.prompt_timeout({"prompt_timeout": bad}), 120, bad)


class Files(unittest.TestCase):
    def test_snapshots_and_kind(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(f"{d}/snapshots/1")
            os.makedirs(f"{d}/kind")
            with open(f"{d}/snapshots/1/s.sh", "w") as f:
                f.write("#!/bin/sh\necho hi\u202e\n")
            with open(f"{d}/kind/diff.txt", "w") as f:
                f.write("DIFF\n")
            os.symlink("/etc/passwd", f"{d}/kind/link")
            req = dict(REQ, snapshots=[
                {"path": "/agents/ada/s.sh", "snapshot": "snapshots/1/s.sh", "sha256": "ab", "executed": True},
                {"path": "/etc/shadow", "snapshot": "../../etc/shadow", "sha256": "cd", "executed": False},
                {"path": "/x", "snapshot": "snapshots/../../x", "sha256": "ef", "executed": False},
            ])
            t = p.files_text(d, req)
            self.assertIn("==== /agents/ada/s.sh (runs; the snapshot is what runs)\n==== sha256 ab\n", t)
            self.assertIn("echo hi\\u{202e}", t)
            self.assertIn("==== kind/diff.txt\n\nDIFF", t)
            self.assertNotIn("shadow", t)
            self.assertNotIn("root:", t)
            self.assertNotIn("kind/link", t)
            self.assertEqual(p.files_text(d, dict(REQ)).count("===="), 1)

    def test_cut(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(f"{d}/kind")
            with open(f"{d}/kind/big", "w") as f:
                f.write("x" * (p.FILE_CAP + 10))
            t = p.files_text(d, REQ)
            self.assertIn("[\u2026 cut at 1048576 bytes]", t)

    def test_load_json(self):
        with tempfile.TemporaryDirectory() as d:
            with open(f"{d}/r.json", "w") as f:
                json.dump(REVIEW, f)
            self.assertEqual(p.load_json(f"{d}/r.json"), REVIEW)
            self.assertIsNone(p.load_json(f"{d}/missing.json"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
