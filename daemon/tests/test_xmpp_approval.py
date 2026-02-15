"""Tests for nuketown_daemon.xmpp.approval."""

import asyncio
from unittest.mock import MagicMock, patch

import pytest

from nuketown_daemon.xmpp.approval import ApprovalManager, _generate_id


def test_generate_id_length():
    """Generated IDs are 12-char hex strings."""
    rid = _generate_id()
    assert len(rid) == 12
    int(rid, 16)  # Should not raise


def test_generate_id_unique():
    """Generated IDs are unique."""
    ids = {_generate_id() for _ in range(100)}
    assert len(ids) == 100


@pytest.mark.asyncio
@patch("nuketown_daemon.xmpp.approval._generate_id", return_value="test123")
async def test_request_approved(_mock_id):
    """Approved requests return True."""
    manager = ApprovalManager()
    client = MagicMock()

    request_task = asyncio.create_task(
        manager.request(client, "josh@6bit.com", "sudo", "whoami", "ada", timeout=5)
    )

    # Let the request send
    await asyncio.sleep(0.01)

    # Verify the request was sent
    client.send_approval_request.assert_called_once_with(
        to_jid="josh@6bit.com",
        request_id="test123",
        kind="sudo",
        command="whoami",
        agent="ada",
        timeout=5,
    )
    assert manager.pending_count == 1

    # Simulate approval response
    await manager.handle_response("test123", "approved")

    result = await request_task
    assert result is True
    assert manager.pending_count == 0


@pytest.mark.asyncio
@patch("nuketown_daemon.xmpp.approval._generate_id", return_value="deny456")
async def test_request_denied(_mock_id):
    """Denied requests return False."""
    manager = ApprovalManager()
    client = MagicMock()

    request_task = asyncio.create_task(
        manager.request(
            client, "josh@6bit.com", "sudo", "rm -rf /", "ada", timeout=5
        )
    )

    await asyncio.sleep(0.01)
    await manager.handle_response("deny456", "denied")

    result = await request_task
    assert result is False


@pytest.mark.asyncio
@patch("nuketown_daemon.xmpp.approval._generate_id", return_value="timeout789")
async def test_request_timeout(_mock_id):
    """Timed-out requests return False."""
    manager = ApprovalManager()
    client = MagicMock()

    result = await manager.request(
        client, "josh@6bit.com", "sudo", "slow-command", "ada", timeout=0.1
    )

    assert result is False
    assert manager.pending_count == 0


@pytest.mark.asyncio
async def test_response_unknown_id():
    """Responses for unknown request IDs are ignored gracefully."""
    manager = ApprovalManager()
    # Should not raise
    await manager.handle_response("nonexistent", "approved")
    assert manager.pending_count == 0


@pytest.mark.asyncio
@patch("nuketown_daemon.xmpp.approval._generate_id", return_value="dup123")
async def test_response_already_resolved(_mock_id):
    """Duplicate responses for already-resolved requests are ignored."""
    manager = ApprovalManager()
    client = MagicMock()

    request_task = asyncio.create_task(
        manager.request(client, "josh@6bit.com", "sudo", "whoami", "ada", timeout=5)
    )

    await asyncio.sleep(0.01)
    await manager.handle_response("dup123", "approved")
    result = await request_task
    assert result is True

    # Second response should be harmless (future already cleaned up)
    await manager.handle_response("dup123", "denied")


@pytest.mark.asyncio
async def test_multiple_concurrent_requests():
    """Multiple pending requests are tracked independently."""
    manager = ApprovalManager()
    client = MagicMock()

    ids = ["req_a", "req_b", "req_c"]
    tasks = []

    for i, rid in enumerate(ids):
        with patch(
            "nuketown_daemon.xmpp.approval._generate_id", return_value=rid
        ):
            # Start and immediately await a sleep to ensure the task
            # body runs while patch is active
            t = asyncio.ensure_future(
                manager.request(
                    client, "josh@6bit.com", "sudo", f"cmd_{i}", "ada", timeout=5
                )
            )
            tasks.append(t)
            # Give the task a chance to start and register the pending future
            await asyncio.sleep(0.01)

    assert manager.pending_count == 3

    # Approve first, deny second
    await manager.handle_response("req_a", "approved")
    await manager.handle_response("req_b", "denied")

    result_a = await tasks[0]
    result_b = await tasks[1]
    assert result_a is True
    assert result_b is False

    # Cancel the third to avoid waiting for timeout
    tasks[2].cancel()
    try:
        await tasks[2]
    except asyncio.CancelledError:
        pass
