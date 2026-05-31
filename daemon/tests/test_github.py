"""Tests for nuketown_daemon.github."""

import json
from unittest.mock import AsyncMock, patch

import pytest

from nuketown_daemon.github import (
    _ORG_INVITE_RE,
    _REPO_INVITE_RE,
    accept_org_invite,
    accept_repo_invite,
    detect_invite,
    handle_invite,
)
from nuketown_daemon.mail import AuthResult, MailNotification


# ── detect_invite ────────────────────────────────────────────────


def _notif(subject: str, dkim: str = "pass", from_domain: str = "github.com") -> MailNotification:
    """Helper to create a MailNotification with given subject and auth."""
    return MailNotification(
        uid="1",
        from_addr=f"Someone <noreply@{from_domain}>",
        subject=subject,
        date="Mon, 24 Feb 2026 08:58:37 -0800",
        auth=AuthResult(dkim=dkim, from_domain=from_domain),
    )


def test_detect_repo_invite():
    n = _notif("joshperry invited you to joshperry/inav")
    result = detect_invite(n)
    assert result == {"type": "repo", "repo": "joshperry/inav"}


def test_detect_repo_invite_with_org():
    n = _notif("joshperry invited you to loomtex/depot")
    result = detect_invite(n)
    assert result == {"type": "repo", "repo": "loomtex/depot"}


def test_detect_org_invite():
    n = _notif("[GitHub] @joshperry has invited you to join the @loomtex organization")
    result = detect_invite(n)
    assert result == {"type": "org", "org": "loomtex"}


def test_detect_not_invite():
    n = _notif("Re: [joshperry/nuketown] Some PR comment (PR #1)")
    result = detect_invite(n)
    assert result is None


def test_detect_untrusted_rejected():
    n = _notif("joshperry invited you to joshperry/inav", dkim="fail")
    result = detect_invite(n)
    assert result is None


def test_detect_wrong_domain_rejected():
    n = _notif("joshperry invited you to joshperry/inav", from_domain="evil.com")
    result = detect_invite(n)
    assert result is None


def test_detect_untrusted_wrong_domain_rejected():
    n = _notif("joshperry invited you to joshperry/inav", dkim="fail", from_domain="evil.com")
    result = detect_invite(n)
    assert result is None


# ── Regex patterns ───────────────────────────────────────────────


def test_repo_regex_captures():
    m = _REPO_INVITE_RE.match("alice invited you to alice/my-repo")
    assert m.group("user") == "alice"
    assert m.group("repo") == "alice/my-repo"


def test_repo_regex_no_match_extra_text():
    m = _REPO_INVITE_RE.match("alice invited you to alice/repo extra stuff")
    assert m is None


def test_org_regex_captures():
    m = _ORG_INVITE_RE.match("[GitHub] @alice has invited you to join the @myorg organization")
    assert m.group("org") == "myorg"


def test_org_regex_no_match_wrong_format():
    m = _ORG_INVITE_RE.match("@alice has invited you to join the @myorg organization")
    assert m is None


# ── accept_repo_invite ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_accept_repo_invite_success():
    api_response = json.dumps([
        {
            "id": 42,
            "repository": {"full_name": "joshperry/inav"},
            "permissions": "push",
        }
    ])

    async def mock_gh(*args):
        if args[0] == "/user/repository_invitations":
            return (0, api_response)
        if args[1] == "PATCH":
            return (0, "")
        return (1, "")

    with patch("nuketown_daemon.github._run_gh", side_effect=mock_gh):
        result = await accept_repo_invite("joshperry/inav")

    assert result is not None
    assert "joshperry/inav" in result
    assert "push" in result


@pytest.mark.asyncio
async def test_accept_repo_invite_no_matching_invite():
    api_response = json.dumps([
        {
            "id": 42,
            "repository": {"full_name": "other/repo"},
            "permissions": "push",
        }
    ])

    with patch("nuketown_daemon.github._run_gh", return_value=(0, api_response)):
        result = await accept_repo_invite("joshperry/inav")

    assert result is None


@pytest.mark.asyncio
async def test_accept_repo_invite_empty_list():
    with patch("nuketown_daemon.github._run_gh", return_value=(0, "[]")):
        result = await accept_repo_invite("joshperry/inav")

    assert result is None


@pytest.mark.asyncio
async def test_accept_repo_invite_api_failure():
    with patch("nuketown_daemon.github._run_gh", return_value=(1, "")):
        result = await accept_repo_invite("joshperry/inav")

    assert result is None


# ── accept_org_invite ────────────────────────────────────────────


@pytest.mark.asyncio
async def test_accept_org_invite_success():
    with patch("nuketown_daemon.github._run_gh", return_value=(0, "")):
        result = await accept_org_invite("loomtex")

    assert result is not None
    assert "loomtex" in result


@pytest.mark.asyncio
async def test_accept_org_invite_failure():
    with patch("nuketown_daemon.github._run_gh", return_value=(1, "")):
        result = await accept_org_invite("loomtex")

    assert result is None


# ── handle_invite (integration) ──────────────────────────────────


@pytest.mark.asyncio
async def test_handle_invite_repo():
    n = _notif("joshperry invited you to joshperry/inav")

    api_response = json.dumps([
        {"id": 99, "repository": {"full_name": "joshperry/inav"}, "permissions": "push"}
    ])

    call_count = 0

    async def mock_gh(*args):
        nonlocal call_count
        call_count += 1
        if "/user/repository_invitations" in args and "-X" not in args:
            return (0, api_response)
        return (0, "")

    with patch("nuketown_daemon.github._run_gh", side_effect=mock_gh):
        result = await handle_invite(n)

    assert result is not None
    assert "joshperry/inav" in result


@pytest.mark.asyncio
async def test_handle_invite_org():
    n = _notif("[GitHub] @joshperry has invited you to join the @loomtex organization")

    with patch("nuketown_daemon.github._run_gh", return_value=(0, "")):
        result = await handle_invite(n)

    assert result is not None
    assert "loomtex" in result


@pytest.mark.asyncio
async def test_handle_invite_not_invite():
    n = _notif("Re: [joshperry/nuketown] Some comment")

    result = await handle_invite(n)
    assert result is None


@pytest.mark.asyncio
async def test_handle_invite_untrusted():
    n = _notif("joshperry invited you to joshperry/inav", dkim="fail")

    result = await handle_invite(n)
    assert result is None
