"""Approval manager for urn:nuketown:approval stanza handling.

Tracks pending approval requests as futures, resolved when the
corresponding approval-response stanza arrives (or on timeout).
"""

from __future__ import annotations

import asyncio
import logging
import secrets
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .client import AgentXMPPClient

log = logging.getLogger(__name__)


def _generate_id() -> str:
    """Generate a short hex ID for approval request correlation."""
    return secrets.token_hex(6)


class ApprovalManager:
    """Manages pending approval requests over XMPP.

    Each request gets an asyncio.Future that resolves when a matching
    approval-response arrives, or raises TimeoutError.
    """

    def __init__(self) -> None:
        self._pending: dict[str, asyncio.Future[str]] = {}

    async def request(
        self,
        client: AgentXMPPClient,
        to_jid: str,
        kind: str,
        command: str,
        agent_name: str,
        timeout: int = 120,
    ) -> bool:
        """Send an approval request and wait for the response.

        Args:
            client: The XMPP client to send through.
            to_jid: JID of the approver (human).
            kind: Request kind (sudo, delegate, scale, network).
            command: The command or action being requested.
            agent_name: Name of the requesting agent.
            timeout: Seconds to wait before auto-deny.

        Returns:
            True if approved, False if denied or timed out.
        """
        request_id = _generate_id()
        future: asyncio.Future[str] = asyncio.get_event_loop().create_future()
        self._pending[request_id] = future

        client.send_approval_request(
            to_jid=to_jid,
            request_id=request_id,
            kind=kind,
            command=command,
            agent=agent_name,
            timeout=timeout,
        )

        try:
            result = await asyncio.wait_for(future, timeout=timeout)
            approved = result == "approved"
            log.info(
                "approval %s: id=%s kind=%s command=%s",
                "granted" if approved else "denied",
                request_id,
                kind,
                command,
            )
            return approved
        except asyncio.TimeoutError:
            log.warning(
                "approval timed out after %ds: id=%s kind=%s command=%s",
                timeout,
                request_id,
                kind,
                command,
            )
            return False
        finally:
            self._pending.pop(request_id, None)

    async def handle_response(self, request_id: str, result: str) -> None:
        """Handle an incoming approval-response stanza.

        Called by the XMPP client when it receives an approval-response.

        Args:
            request_id: The correlation ID from the response.
            result: The result string ("approved" or "denied").
        """
        future = self._pending.get(request_id)
        if future is None:
            log.warning(
                "received approval response for unknown request: id=%s", request_id
            )
            return

        if future.done():
            log.warning(
                "received approval response for already-resolved request: id=%s",
                request_id,
            )
            return

        future.set_result(result)

    @property
    def pending_count(self) -> int:
        """Number of pending approval requests."""
        return len(self._pending)
