"""Tests for nuketown_daemon.xmpp.presence."""

from unittest.mock import MagicMock

from nuketown_daemon.xmpp.presence import (
    MAX_STATUS_LENGTH,
    PresencePublisher,
    _truncate,
    state_to_presence,
)


def test_idle_presence():
    """Idle state maps to show=chat, status=Ready."""
    show, status = state_to_presence("idle")
    assert show == "chat"
    assert status == "Ready"


def test_idle_ignores_detail():
    """Idle state ignores any detail text."""
    show, status = state_to_presence("idle", "some detail")
    assert show == "chat"
    assert status == "Ready"


def test_working_no_detail():
    """Working state without detail shows just 'Working'."""
    show, status = state_to_presence("working")
    assert show == "dnd"
    assert status == "Working"


def test_working_with_detail():
    """Working state includes task detail."""
    show, status = state_to_presence("working", "fix udev rules")
    assert show == "dnd"
    assert status == "Working: fix udev rules"


def test_blocked_no_detail():
    """Blocked state without detail shows just 'Waiting'."""
    show, status = state_to_presence("blocked")
    assert show == "away"
    assert status == "Waiting"


def test_blocked_with_detail():
    """Blocked state includes reason."""
    show, status = state_to_presence("blocked", "sudo approval")
    assert show == "away"
    assert status == "Waiting: sudo approval"


def test_unknown_state():
    """Unknown states produce empty show with state as status."""
    show, status = state_to_presence("weird")
    assert show == ""
    assert status == "weird"


def test_truncate_short():
    """Short text is returned unchanged."""
    assert _truncate("hello", 10) == "hello"


def test_truncate_exact():
    """Text at exactly max length is returned unchanged."""
    assert _truncate("12345", 5) == "12345"


def test_truncate_long():
    """Long text is truncated with ellipsis."""
    result = _truncate("a" * 200, 10)
    assert len(result) == 10
    assert result.endswith("\u2026")


def test_working_long_detail_truncated():
    """Very long task descriptions are truncated."""
    long_detail = "x" * 300
    show, status = state_to_presence("working", long_detail)
    assert show == "dnd"
    assert len(status) <= MAX_STATUS_LENGTH
    assert status.startswith("Working: ")


def test_publisher_sends_presence():
    """PresencePublisher delegates to client.send_presence."""
    mock_client = MagicMock()
    pub = PresencePublisher(mock_client)

    pub.update("idle")
    mock_client.send_presence.assert_called_with(show="chat", status="Ready")

    pub.update("working", "nuketown build")
    mock_client.send_presence.assert_called_with(
        show="dnd", status="Working: nuketown build"
    )

    pub.update("blocked", "sudo approval")
    mock_client.send_presence.assert_called_with(
        show="away", status="Waiting: sudo approval"
    )
