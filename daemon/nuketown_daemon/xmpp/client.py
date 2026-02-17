"""XMPP client wrapper for nuketown agents.

Wraps slixmpp.ClientXMPP to provide:
- Connection lifecycle (connect, disconnect)
- MUC room joining
- Message dispatch (task requests, approval responses)
- Service discovery advertising for urn:nuketown:approval
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from typing import Any

import slixmpp
from slixmpp import Message

log = logging.getLogger(__name__)

APPROVAL_NS = "urn:nuketown:approval"

# Type for the callback that handles incoming task messages
MessageCallback = Callable[[dict[str, Any]], Awaitable[None]]

# Type for the callback that handles approval responses
ApprovalCallback = Callable[[str, str], Awaitable[None]]


class AgentXMPPClient:
    """XMPP client for a nuketown agent.

    Integrates with the daemon's asyncio event loop — call
    connect_and_run() to start, disconnect() to stop.
    """

    def __init__(
        self,
        jid: str,
        password: str,
        rooms: list[str] | None = None,
        message_callback: MessageCallback | None = None,
        approval_callback: ApprovalCallback | None = None,
    ) -> None:
        self.jid = jid
        self.rooms = rooms or []
        self._message_callback = message_callback
        self._approval_callback = approval_callback

        self._xmpp = slixmpp.ClientXMPP(jid, password)
        self._xmpp.add_event_handler("session_start", self._on_session_start)
        self._xmpp.add_event_handler("message", self._on_message)
        self._xmpp.add_event_handler("disconnected", self._on_disconnected)

        # Register plugins
        self._xmpp.register_plugin("xep_0030")  # Service Discovery
        self._xmpp.register_plugin("xep_0045")  # MUC
        self._xmpp.register_plugin("xep_0199")  # XMPP Ping (keepalive)
        self._xmpp.register_plugin("xep_0313")  # MAM

        self._connected = asyncio.Event()
        self._disconnected_event = asyncio.Event()
        self._stopping = False

    @property
    def connected(self) -> bool:
        """Whether the client is currently connected."""
        return self._connected.is_set()

    async def _on_session_start(self, _event: dict[str, Any]) -> None:
        """Handle successful XMPP session start."""
        log.info("XMPP session started: %s", self.jid)

        # Send initial presence
        self._xmpp.send_presence()

        # Enable keepalive pings (detect dead connections)
        self._xmpp["xep_0199"].enable_keepalive(interval=300, timeout=30)

        # Advertise approval namespace via service discovery
        self._xmpp["xep_0030"].add_feature(APPROVAL_NS)

        # Join configured MUC rooms
        for room in self.rooms:
            nick = slixmpp.JID(self.jid).user
            log.info("joining MUC room: %s as %s", room, nick)
            await self._xmpp["xep_0045"].join_muc(room, nick)

        self._connected.set()
        self._disconnected_event.clear()

    async def _on_message(self, msg: Message) -> None:
        """Dispatch incoming messages to appropriate handlers."""
        # Check for approval-response stanza
        approval_resp = msg.xml.find(f"{{{APPROVAL_NS}}}approval-response")
        if approval_resp is not None:
            request_id = approval_resp.get("id", "")
            result_elem = approval_resp.find(f"{{{APPROVAL_NS}}}result")
            result = result_elem.text if result_elem is not None else ""
            log.info("approval response: id=%s result=%s", request_id, result)
            if self._approval_callback:
                await self._approval_callback(request_id, result)
            return

        # Check for task request in message body (JSON)
        body = msg["body"]
        if not body:
            return

        try:
            data = json.loads(body)
        except (json.JSONDecodeError, TypeError):
            # Not JSON — ignore (normal chat message)
            return

        if not isinstance(data, dict):
            return

        log.info("task message from %s: %s", msg["from"], data.get("type", "unknown"))
        if self._message_callback:
            await self._message_callback(data)

    def _on_disconnected(self, _event: Any) -> None:
        """Handle XMPP disconnection and schedule reconnect."""
        log.warning("XMPP disconnected: %s", self.jid)
        self._connected.clear()
        self._disconnected_event.set()
        if not self._stopping:
            asyncio.ensure_future(self._reconnect())

    async def _reconnect(self, delay: float = 5, max_delay: float = 300) -> None:
        """Reconnect with exponential backoff."""
        current_delay = delay
        while not self._stopping:
            log.info("reconnecting in %.0fs...", current_delay)
            await asyncio.sleep(current_delay)
            if self._stopping:
                break
            log.info("reconnecting to XMPP as %s", self.jid)
            self._xmpp.connect()
            if await self.wait_connected(timeout=30):
                log.info("XMPP reconnected: %s", self.jid)
                return
            current_delay = min(current_delay * 2, max_delay)

    async def connect_and_run(self) -> None:
        """Connect to the XMPP server and process events.

        This integrates with the existing asyncio event loop —
        slixmpp runs its own processing within the loop.
        """
        self._stopping = False
        log.info("connecting to XMPP as %s", self.jid)
        self._xmpp.connect()

    async def wait_connected(self, timeout: float = 30) -> bool:
        """Wait for the XMPP session to be established."""
        try:
            await asyncio.wait_for(self._connected.wait(), timeout=timeout)
            return True
        except asyncio.TimeoutError:
            log.error("XMPP connection timed out after %.0fs", timeout)
            return False

    async def disconnect(self) -> None:
        """Disconnect from the XMPP server cleanly."""
        self._stopping = True
        log.info("disconnecting XMPP: %s", self.jid)
        self._xmpp.disconnect()

    def send_message(self, to_jid: str, body: str) -> None:
        """Send a plain text message."""
        self._xmpp.send_message(mto=to_jid, mbody=body, mtype="chat")

    def send_presence(self, show: str = "", status: str = "") -> None:
        """Send a presence stanza with optional show/status."""
        self._xmpp.send_presence(pshow=show, pstatus=status)

    def send_approval_request(
        self,
        to_jid: str,
        request_id: str,
        kind: str,
        command: str,
        agent: str,
        timeout: int = 120,
    ) -> None:
        """Send a structured approval request using urn:nuketown:approval.

        Builds and sends a <message> with a custom <approval> child element.
        """
        msg = self._xmpp.make_message(mto=to_jid, mtype="normal")
        msg["id"] = request_id

        # Build custom approval XML
        approval = slixmpp.xmlstream.ET.SubElement(
            msg.xml, f"{{{APPROVAL_NS}}}approval"
        )
        approval.set("id", request_id)

        agent_elem = slixmpp.xmlstream.ET.SubElement(approval, "agent")
        agent_elem.text = agent

        kind_elem = slixmpp.xmlstream.ET.SubElement(approval, "kind")
        kind_elem.text = kind

        command_elem = slixmpp.xmlstream.ET.SubElement(approval, "command")
        command_elem.text = command

        timeout_elem = slixmpp.xmlstream.ET.SubElement(approval, "timeout")
        timeout_elem.text = str(timeout)

        msg.send()
        log.info(
            "sent approval request: id=%s kind=%s command=%s to=%s",
            request_id,
            kind,
            command,
            to_jid,
        )
