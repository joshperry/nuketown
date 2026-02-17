"""Tests for nuketown_daemon.xmpp.client."""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch
from xml.etree import ElementTree as ET

import pytest

from nuketown_daemon.xmpp.client import APPROVAL_NS, AgentXMPPClient


@pytest.fixture
def client():
    """Create an AgentXMPPClient with mocked slixmpp internals."""
    with patch("nuketown_daemon.xmpp.client.slixmpp") as mock_slixmpp:
        mock_xmpp = MagicMock()
        mock_slixmpp.ClientXMPP.return_value = mock_xmpp
        mock_slixmpp.JID.return_value = MagicMock(user="ada")
        mock_slixmpp.xmlstream.ET = ET

        # Make plugin access return mocks with async methods
        mock_disco = MagicMock()
        mock_muc = MagicMock()
        mock_muc.join_muc = AsyncMock()
        mock_ping = MagicMock()
        mock_mam = MagicMock()

        plugins = {"xep_0030": mock_disco, "xep_0045": mock_muc, "xep_0199": mock_ping, "xep_0313": mock_mam}
        mock_xmpp.__getitem__ = MagicMock(side_effect=lambda key: plugins[key])

        # Track registered event handlers
        handlers = {}

        def add_event_handler(event, handler):
            handlers[event] = handler

        mock_xmpp.add_event_handler = add_event_handler

        c = AgentXMPPClient(
            jid="ada@6bit.com",
            password="secret",
            rooms=["agents@conference.6bit.com"],
        )
        c._handlers = handlers  # expose for testing
        yield c


@pytest.fixture
def client_with_callbacks():
    """Create an AgentXMPPClient with message and approval callbacks."""
    msg_cb = AsyncMock()
    approval_cb = AsyncMock()

    with patch("nuketown_daemon.xmpp.client.slixmpp") as mock_slixmpp:
        mock_xmpp = MagicMock()
        mock_slixmpp.ClientXMPP.return_value = mock_xmpp
        mock_slixmpp.JID.return_value = MagicMock(user="ada")
        mock_slixmpp.xmlstream.ET = ET

        handlers = {}
        mock_xmpp.add_event_handler = lambda e, h: handlers.update({e: h})

        c = AgentXMPPClient(
            jid="ada@6bit.com",
            password="secret",
            rooms=[],
            message_callback=msg_cb,
            approval_callback=approval_cb,
        )
        c._handlers = handlers
        c._msg_cb = msg_cb
        c._approval_cb = approval_cb
        yield c


def test_client_creation(client):
    """Client initialises with correct JID and rooms."""
    assert client.jid == "ada@6bit.com"
    assert client.rooms == ["agents@conference.6bit.com"]
    assert not client.connected


def test_plugins_registered(client):
    """Service discovery, MUC, and MAM plugins are registered."""
    calls = client._xmpp.register_plugin.call_args_list
    registered = [call.args[0] for call in calls]
    assert "xep_0030" in registered
    assert "xep_0045" in registered
    assert "xep_0313" in registered


def test_event_handlers_registered(client):
    """session_start, message, and disconnected handlers are set."""
    assert "session_start" in client._handlers
    assert "message" in client._handlers
    assert "disconnected" in client._handlers


@pytest.mark.asyncio
async def test_session_start_sends_presence(client):
    """On session start, presence is sent and rooms are joined."""
    await client._on_session_start({})

    client._xmpp.send_presence.assert_called_once()
    assert client.connected


@pytest.mark.asyncio
async def test_session_start_advertises_approval_feature(client):
    """On session start, the approval namespace is advertised."""
    await client._on_session_start({})

    client._xmpp["xep_0030"].add_feature.assert_called_with(APPROVAL_NS)


@pytest.mark.asyncio
async def test_session_start_joins_rooms(client):
    """On session start, configured MUC rooms are joined."""
    await client._on_session_start({})

    client._xmpp["xep_0045"].join_muc.assert_called_once_with(
        "agents@conference.6bit.com", "ada"
    )


@pytest.mark.asyncio
async def test_message_json_dispatch(client_with_callbacks):
    """JSON messages are parsed and dispatched to message_callback."""
    c = client_with_callbacks
    msg = MagicMock()
    msg.xml = ET.Element("message")
    msg.__getitem__ = lambda self, key: {
        "body": json.dumps({"type": "task", "project": "nuketown"}),
        "from": "josh@6bit.com",
    }.get(key, "")

    await c._on_message(msg)

    c._msg_cb.assert_called_once_with({"type": "task", "project": "nuketown"})


@pytest.mark.asyncio
async def test_message_non_json_ignored(client_with_callbacks):
    """Non-JSON messages are silently ignored."""
    c = client_with_callbacks
    msg = MagicMock()
    msg.xml = ET.Element("message")
    msg.__getitem__ = lambda self, key: {
        "body": "hello, just a chat message",
        "from": "josh@6bit.com",
    }.get(key, "")

    await c._on_message(msg)

    c._msg_cb.assert_not_called()


@pytest.mark.asyncio
async def test_message_empty_body_ignored(client_with_callbacks):
    """Empty-body messages are ignored."""
    c = client_with_callbacks
    msg = MagicMock()
    msg.xml = ET.Element("message")
    msg.__getitem__ = lambda self, key: {"body": "", "from": "x"}.get(key, "")

    await c._on_message(msg)

    c._msg_cb.assert_not_called()


@pytest.mark.asyncio
async def test_approval_response_dispatch(client_with_callbacks):
    """Approval response stanzas are dispatched to approval_callback."""
    c = client_with_callbacks

    # Build an XML message with approval-response child
    msg_xml = ET.Element("message")
    resp = ET.SubElement(msg_xml, f"{{{APPROVAL_NS}}}approval-response")
    resp.set("id", "abc123")
    result = ET.SubElement(resp, f"{{{APPROVAL_NS}}}result")
    result.text = "approved"

    msg = MagicMock()
    msg.xml = msg_xml
    msg.__getitem__ = lambda self, key: {"body": "", "from": "josh@6bit.com"}.get(
        key, ""
    )

    await c._on_message(msg)

    c._approval_cb.assert_called_once_with("abc123", "approved")
    c._msg_cb.assert_not_called()  # Should NOT also dispatch as task


def test_send_message(client):
    """send_message sends a chat message via slixmpp."""
    client.send_message("josh@6bit.com", "hello")

    client._xmpp.send_message.assert_called_once_with(
        mto="josh@6bit.com", mbody="hello", mtype="chat"
    )


def test_send_presence(client):
    """send_presence sends a presence stanza."""
    client.send_presence(show="dnd", status="Working: nuketown")

    client._xmpp.send_presence.assert_called_once_with(
        pshow="dnd", pstatus="Working: nuketown"
    )


def test_send_approval_request(client):
    """send_approval_request builds and sends the custom approval stanza."""
    mock_msg = MagicMock()
    mock_msg.xml = ET.Element("message")
    client._xmpp.make_message.return_value = mock_msg

    client.send_approval_request(
        to_jid="josh@6bit.com",
        request_id="a1b2c3",
        kind="sudo",
        command="nixos-rebuild switch",
        agent="ada",
        timeout=120,
    )

    # Verify make_message was called
    client._xmpp.make_message.assert_called_once_with(
        mto="josh@6bit.com", mtype="normal"
    )

    # Verify XML structure
    approval = mock_msg.xml.find(f"{{{APPROVAL_NS}}}approval")
    assert approval is not None
    assert approval.get("id") == "a1b2c3"
    assert approval.find("agent").text == "ada"
    assert approval.find("kind").text == "sudo"
    assert approval.find("command").text == "nixos-rebuild switch"
    assert approval.find("timeout").text == "120"

    # Verify sent
    mock_msg.send.assert_called_once()


def test_disconnect_calls_slixmpp(client):
    """disconnect() delegates to slixmpp."""
    asyncio.get_event_loop().run_until_complete(client.disconnect())
    client._xmpp.disconnect.assert_called_once()


def test_connect_and_run(client):
    """connect_and_run() calls slixmpp.connect()."""
    asyncio.get_event_loop().run_until_complete(client.connect_and_run())
    client._xmpp.connect.assert_called_once()


def test_disconnected_event(client):
    """Disconnection handler clears connected flag."""
    # First set connected
    client._connected.set()
    assert client.connected

    # Fire disconnected
    client._on_disconnected(None)
    assert not client.connected
