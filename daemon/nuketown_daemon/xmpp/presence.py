"""XMPP presence publisher for nuketown agents.

Maps daemon states to XMPP show/status values:

| State    | Show   | Status                    |
|----------|--------|---------------------------|
| IDLE     | chat   | Ready                     |
| WORKING  | dnd    | Working: <task>           |
| BLOCKED  | away   | Waiting: <reason>         |
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .client import AgentXMPPClient

log = logging.getLogger(__name__)

# Maximum length for the status text (XMPP has no strict limit,
# but clients truncate long statuses)
MAX_STATUS_LENGTH = 140


class PresencePublisher:
    """Publishes XMPP presence based on daemon state transitions."""

    def __init__(self, client: AgentXMPPClient) -> None:
        self._client = client

    def update(self, state: str, detail: str = "") -> None:
        """Send a presence update for the given state.

        Args:
            state: One of "idle", "working", "blocked".
            detail: Optional context (task name, reason for block).
        """
        show, status = state_to_presence(state, detail)
        log.info("presence update: show=%s status=%s", show, status)
        self._client.send_presence(show=show, status=status)


def state_to_presence(state: str, detail: str = "") -> tuple[str, str]:
    """Convert a daemon state to (show, status) tuple.

    Returns:
        Tuple of (show, status) for the XMPP presence stanza.
    """
    if state == "idle":
        return ("chat", "Ready")

    if state == "working":
        status = "Working"
        if detail:
            suffix = _truncate(detail, MAX_STATUS_LENGTH - len("Working: "))
            status = f"Working: {suffix}"
        return ("dnd", status)

    if state == "blocked":
        status = "Waiting"
        if detail:
            suffix = _truncate(detail, MAX_STATUS_LENGTH - len("Waiting: "))
            status = f"Waiting: {suffix}"
        return ("away", status)

    # Unknown state — treat as available with no show
    log.warning("unknown state for presence: %s", state)
    return ("", state)


def _truncate(text: str, max_len: int) -> str:
    """Truncate text to max_len, adding ellipsis if needed."""
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "\u2026"
