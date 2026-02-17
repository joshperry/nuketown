"""Tests for nuketown_daemon.mail."""

import asyncio
import email
import email.policy
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from nuketown_daemon.mail import (
    AuthResult,
    MailNotification,
    MailWatcher,
    _decode_header,
    _extract_snippet,
    _parse_auth_results,
)


# ── AuthResult ───────────────────────────────────────────────────


def test_auth_trusted_dkim_pass():
    auth = AuthResult(dkim="pass", spf="none")
    assert auth.trusted is True


def test_auth_trusted_spf_pass():
    auth = AuthResult(dkim="none", spf="pass")
    assert auth.trusted is True


def test_auth_untrusted_all_fail():
    auth = AuthResult(dkim="fail", spf="fail")
    assert auth.trusted is False


def test_auth_untrusted_empty():
    auth = AuthResult()
    assert auth.trusted is False


def test_auth_summary():
    auth = AuthResult(dkim="pass", spf="pass", dmarc="pass")
    assert "dkim=pass" in auth.summary
    assert "spf=pass" in auth.summary
    assert "dmarc=pass" in auth.summary


def test_auth_summary_empty():
    auth = AuthResult()
    assert auth.summary == "no-auth"


# ── Header decoding ─────────────────────────────────────────────


def test_decode_header_plain():
    assert _decode_header("Hello World") == "Hello World"


def test_decode_header_encoded():
    # RFC 2047 encoded
    raw = "=?utf-8?B?SGVsbG8gV29ybGQ=?="
    assert _decode_header(raw) == "Hello World"


# ── Auth header parsing ─────────────────────────────────────────


def _make_msg_with_auth(auth_header: str) -> email.message.EmailMessage:
    raw = f"From: test@example.com\r\nAuthentication-Results: {auth_header}\r\n\r\n"
    return email.message_from_string(raw, policy=email.policy.default)


def test_parse_auth_dkim_pass():
    msg = _make_msg_with_auth("mx.example.com; dkim=pass header.d=github.com")
    auth = _parse_auth_results(msg)
    assert auth.dkim == "pass"
    assert auth.from_domain == "example.com"


def test_parse_auth_spf_pass():
    msg = _make_msg_with_auth("mx.example.com; spf=pass smtp.mailfrom=github.com")
    auth = _parse_auth_results(msg)
    assert auth.spf == "pass"


def test_parse_auth_dmarc_pass():
    msg = _make_msg_with_auth("mx.example.com; dmarc=pass header.from=github.com")
    auth = _parse_auth_results(msg)
    assert auth.dmarc == "pass"


def test_parse_auth_multiple_results():
    msg = _make_msg_with_auth(
        "mx.example.com; dkim=pass; spf=pass; dmarc=pass"
    )
    auth = _parse_auth_results(msg)
    assert auth.dkim == "pass"
    assert auth.spf == "pass"
    assert auth.dmarc == "pass"
    assert auth.trusted is True


def test_parse_auth_fail():
    msg = _make_msg_with_auth("mx.example.com; dkim=fail; spf=softfail")
    auth = _parse_auth_results(msg)
    assert auth.dkim == "fail"
    assert auth.spf == "softfail"
    assert auth.trusted is False


def test_parse_auth_no_header():
    raw = "From: test@example.com\r\n\r\n"
    msg = email.message_from_string(raw, policy=email.policy.default)
    auth = _parse_auth_results(msg)
    assert auth.dkim == ""
    assert auth.spf == ""
    assert auth.trusted is False


def test_parse_auth_from_domain_angle_brackets():
    raw = "From: Test User <test@github.com>\r\nAuthentication-Results: mx; dkim=pass\r\n\r\n"
    msg = email.message_from_string(raw, policy=email.policy.default)
    auth = _parse_auth_results(msg)
    assert auth.from_domain == "github.com"


# ── Snippet extraction ───────────────────────────────────────────


def test_extract_snippet():
    raw = "From: test@example.com\r\nContent-Type: text/plain\r\n\r\nHello world, this is a test."
    msg = email.message_from_string(raw, policy=email.policy.default)
    snippet = _extract_snippet(msg)
    assert "Hello world" in snippet


def test_extract_snippet_truncates():
    raw = "From: test@example.com\r\nContent-Type: text/plain\r\n\r\n" + "x" * 300
    msg = email.message_from_string(raw, policy=email.policy.default)
    snippet = _extract_snippet(msg, max_len=50)
    assert len(snippet) <= 54  # 50 + "..."
    assert snippet.endswith("...")


# ── MailNotification ─────────────────────────────────────────────


def test_notification_default_auth():
    n = MailNotification(uid="1", from_addr="test@example.com", subject="Test", date="now")
    assert n.auth is not None
    assert n.auth.trusted is False


def test_notification_with_auth():
    auth = AuthResult(dkim="pass", spf="pass")
    n = MailNotification(
        uid="1", from_addr="test@example.com", subject="Test", date="now", auth=auth
    )
    assert n.auth.trusted is True


# ── MailWatcher ──────────────────────────────────────────────────


def test_watcher_init():
    w = MailWatcher(
        host="mail.example.com",
        username="test@example.com",
        password="secret",
    )
    assert w.host == "mail.example.com"
    assert w.port == 993
    assert w.mailbox == "INBOX"


@pytest.mark.asyncio
async def test_watcher_stop():
    w = MailWatcher(
        host="mail.example.com",
        username="test@example.com",
        password="secret",
    )
    await w.stop()
    assert w._stopping is True
