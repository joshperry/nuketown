"""IMAP IDLE mail watcher for nuketown agents.

Maintains a persistent IMAP IDLE connection to watch for new mail.
When new messages arrive, parses headers and invokes a callback.
Reconnects automatically on connection loss.
"""

from __future__ import annotations

import asyncio
import email
import email.header
import email.policy
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

import aioimaplib

log = logging.getLogger(__name__)

# Re-IDLE every 25 minutes (servers typically timeout IDLE at 29min per RFC 2177)
IDLE_REFRESH_SECONDS = 25 * 60


@dataclass
class AuthResult:
    """Email authentication results from trusted headers."""

    dkim: str = ""  # "pass", "fail", "none", etc.
    spf: str = ""  # "pass", "fail", "softfail", "none", etc.
    dmarc: str = ""  # "pass", "fail", "none", etc.
    from_domain: str = ""  # Domain from the From header

    @property
    def trusted(self) -> bool:
        """Whether the message passes basic authentication checks.

        Requires at least DKIM or SPF pass. This indicates the sending
        server is authorized for the claimed domain — not that the
        content is safe, but that the sender identity is verified.
        """
        return self.dkim == "pass" or self.spf == "pass"

    @property
    def summary(self) -> str:
        parts = []
        if self.dkim:
            parts.append(f"dkim={self.dkim}")
        if self.spf:
            parts.append(f"spf={self.spf}")
        if self.dmarc:
            parts.append(f"dmarc={self.dmarc}")
        return " ".join(parts) if parts else "no-auth"


@dataclass
class MailNotification:
    """Parsed summary of a new email."""

    uid: str
    from_addr: str
    subject: str
    date: str
    to_addr: str = ""
    snippet: str = ""  # First ~200 chars of body
    auth: AuthResult = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.auth is None:
            self.auth = AuthResult()


# Callback type: receives a MailNotification
MailCallback = Callable[[MailNotification], Awaitable[None]]


def _decode_header(raw: str) -> str:
    """Decode RFC 2047 encoded header value."""
    parts = email.header.decode_header(raw)
    decoded = []
    for data, charset in parts:
        if isinstance(data, bytes):
            decoded.append(data.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(data)
    return " ".join(decoded)


def _extract_snippet(msg: email.message.EmailMessage, max_len: int = 200) -> str:
    """Extract a plain text snippet from an email message."""
    body = msg.get_body(preferencelist=("plain",))
    if body is None:
        return ""
    content = body.get_content()
    if not isinstance(content, str):
        return ""
    # Collapse whitespace and truncate
    text = " ".join(content.split())
    if len(text) > max_len:
        return text[:max_len] + "..."
    return text


def _parse_auth_results(msg: email.message.EmailMessage) -> AuthResult:
    """Parse Authentication-Results header for DKIM/SPF/DMARC verdicts.

    The Authentication-Results header is added by the receiving mail server
    (our server, which we trust). It contains the results of authentication
    checks performed on the incoming message.

    See RFC 8601 for the full spec.
    """
    auth = AuthResult()

    # Extract domain from From header
    from_addr = msg.get("From", "")
    if "@" in from_addr:
        # Handle "Name <user@domain>" format
        addr_part = from_addr.rsplit("<", 1)[-1].rstrip(">").strip()
        if "@" in addr_part:
            auth.from_domain = addr_part.split("@", 1)[1].lower()

    # Parse Authentication-Results (may appear multiple times)
    for ar_header in msg.get_all("Authentication-Results", []):
        ar_lower = ar_header.lower()
        # Extract DKIM result
        if "dkim=" in ar_lower and not auth.dkim:
            for part in ar_lower.split(";"):
                part = part.strip()
                if part.startswith("dkim="):
                    auth.dkim = part.split("=", 1)[1].split()[0].strip()
        # Extract SPF result
        if "spf=" in ar_lower and not auth.spf:
            for part in ar_lower.split(";"):
                part = part.strip()
                if part.startswith("spf="):
                    auth.spf = part.split("=", 1)[1].split()[0].strip()
        # Extract DMARC result
        if "dmarc=" in ar_lower and not auth.dmarc:
            for part in ar_lower.split(";"):
                part = part.strip()
                if part.startswith("dmarc="):
                    auth.dmarc = part.split("=", 1)[1].split()[0].strip()

    return auth


class MailWatcher:
    """Watches an IMAP mailbox via IDLE and notifies on new messages."""

    def __init__(
        self,
        host: str,
        username: str,
        password: str,
        port: int = 993,
        mailbox: str = "INBOX",
        callback: MailCallback | None = None,
    ) -> None:
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.mailbox = mailbox
        self._callback = callback
        self._stopping = False
        self._client: aioimaplib.IMAP4_SSL | None = None

    async def run(self) -> None:
        """Run the IMAP IDLE watcher with automatic reconnect."""
        self._stopping = False
        delay = 5.0
        max_delay = 300.0

        while not self._stopping:
            try:
                await self._connect_and_idle()
            except asyncio.CancelledError:
                break
            except Exception:
                log.exception("IMAP watcher error")

            if self._stopping:
                break

            log.info("IMAP reconnecting in %.0fs...", delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, max_delay)

    async def stop(self) -> None:
        """Signal the watcher to stop."""
        self._stopping = True
        if self._client:
            try:
                if self._client.has_pending_idle():
                    self._client.idle_done()
                await self._client.logout()
            except Exception:
                pass

    async def _connect_and_idle(self) -> None:
        """Connect to IMAP, select mailbox, and enter IDLE loop."""
        log.info("IMAP connecting to %s:%d as %s", self.host, self.port, self.username)
        self._client = aioimaplib.IMAP4_SSL(host=self.host, port=self.port, timeout=30)
        await self._client.wait_hello_from_server()

        resp = await self._client.login(self.username, self.password)
        if resp.result != "OK":
            log.error("IMAP login failed: %s", resp.lines)
            return

        log.info("IMAP connected, selecting %s", self.mailbox)
        resp = await self._client.select(self.mailbox)
        if resp.result != "OK":
            log.error("IMAP SELECT failed: %s", resp.lines)
            return

        # Note the current highest UID so we only notify on truly new mail
        last_seen = await self._get_max_uid()
        log.info("IMAP IDLE starting (last seen UID: %s)", last_seen)

        while not self._stopping:
            # Enter IDLE mode
            idle_task = await self._client.idle_start(timeout=IDLE_REFRESH_SECONDS)
            try:
                msg = await self._client.wait_server_push()
            except asyncio.TimeoutError:
                # Normal IDLE refresh — re-IDLE
                self._client.idle_done()
                await asyncio.wait_for(idle_task, timeout=10)
                continue

            self._client.idle_done()
            await asyncio.wait_for(idle_task, timeout=10)

            # Check if we got new mail
            has_new = any(
                b"EXISTS" in line if isinstance(line, bytes) else "EXISTS" in str(line)
                for line in msg
            )
            if has_new:
                last_seen = await self._process_new_mail(last_seen)

    async def _get_max_uid(self) -> int:
        """Get the highest UID in the current mailbox."""
        resp = await self._client.uid_search("ALL")
        if resp.result != "OK" or not resp.lines or not resp.lines[0]:
            return 0
        raw = resp.lines[0]
        if isinstance(raw, bytes):
            raw = raw.decode()
        uids = raw.split()
        if not uids:
            return 0
        return int(uids[-1])

    async def _process_new_mail(self, last_seen: int) -> int:
        """Fetch and process messages with UID > last_seen. Returns new max UID."""
        resp = await self._client.uid_search(f"UID {last_seen + 1}:*")
        if resp.result != "OK" or not resp.lines or not resp.lines[0]:
            return last_seen

        # aioimaplib may return UIDs as bytes or str depending on version
        raw_uids = resp.lines[0]
        if isinstance(raw_uids, bytes):
            raw_uids = raw_uids.decode()
        uids = [u for u in raw_uids.split() if int(u) > last_seen]
        if not uids:
            return last_seen

        max_uid = last_seen
        for uid in uids:
            try:
                notification = await self._fetch_notification(uid)
                if notification and self._callback:
                    await self._callback(notification)
                max_uid = max(max_uid, int(uid))
            except Exception:
                log.exception("error processing mail UID %s", uid)

        return max_uid

    async def _fetch_notification(self, uid: str) -> MailNotification | None:
        """Fetch headers + snippet for a single message by UID."""
        resp = await self._client.uid("fetch", uid, "(BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.1024>)")
        if resp.result != "OK":
            log.warning("IMAP FETCH failed for UID %s: %s", uid, resp.lines)
            return None

        # Parse the response — aioimaplib returns a list of response lines
        header_data = b""
        text_data = b""
        for line in resp.lines:
            if isinstance(line, bytes):
                if b"BODY[HEADER]" in line or (header_data and not text_data):
                    # Skip the FETCH response line itself
                    pass
                header_data += line + b"\n"

        # Simpler approach: fetch RFC822.HEADER and a text snippet separately
        header_resp = await self._client.uid("fetch", uid, "(RFC822.HEADER)")
        if header_resp.result != "OK":
            return None

        # Extract header bytes from response
        raw_headers = b""
        for line in header_resp.lines:
            if isinstance(line, bytes):
                raw_headers += line + b"\n"

        if not raw_headers:
            return None

        msg = email.message_from_bytes(raw_headers, policy=email.policy.default)
        from_addr = _decode_header(msg.get("From", ""))
        subject = _decode_header(msg.get("Subject", ""))
        date = msg.get("Date", "")
        to_addr = _decode_header(msg.get("To", ""))
        auth = _parse_auth_results(msg)

        # Fetch a snippet of the body
        snippet = ""
        body_resp = await self._client.uid("fetch", uid, "(BODY.PEEK[TEXT]<0.1024>)")
        if body_resp.result == "OK":
            body_bytes = b""
            for line in body_resp.lines:
                if isinstance(line, bytes):
                    body_bytes += line + b"\n"
            if body_bytes:
                try:
                    snippet = body_bytes.decode("utf-8", errors="replace")[:200]
                    snippet = " ".join(snippet.split())  # collapse whitespace
                except Exception:
                    pass

        log.info(
            "new mail: from=%s subject=%s auth=[%s] trusted=%s",
            from_addr, subject, auth.summary, auth.trusted,
        )
        return MailNotification(
            uid=uid,
            from_addr=from_addr,
            subject=subject,
            date=date,
            to_addr=to_addr,
            snippet=snippet,
            auth=auth,
        )
