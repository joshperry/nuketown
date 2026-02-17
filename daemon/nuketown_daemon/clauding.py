"""Event-driven clauding.md evaluation for nuketown-daemon.

Parses clauding.md for active watchers, applies cheap pre-filters, and
uses a single Haiku API call to triage whether an incoming event (mail,
XMPP, etc.) matches a watcher. On match, builds an action prompt for
execution via HeadlessSession.
"""

from __future__ import annotations

import logging
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

import anthropic

log = logging.getLogger(__name__)

TRIAGE_MODEL = "claude-haiku-4-5-20251001"
TRIAGE_MAX_TOKENS = 256


# ── Data structures ──────────────────────────────────────────────


@dataclass
class Event:
    """An incoming event to evaluate against watchers."""

    source: str  # "mail", "xmpp", "socket"
    sender: str  # email address, JID, etc.
    subject: str
    body: str  # snippet
    trusted: bool
    timestamp: float  # time.monotonic()


@dataclass
class ClaudingEntry:
    """A parsed entry from clauding.md."""

    name: str
    watch: str  # natural language watch description
    tags: list[str] = field(default_factory=list)
    since: str = ""
    status: str = ""
    full_text: str = ""  # entire entry markdown for the action prompt


# ── Parsing ──────────────────────────────────────────────────────


def parse_entries(text: str) -> list[ClaudingEntry]:
    """Parse clauding.md text for entries with status: waiting."""
    entries = []
    # Split on ## headers
    sections = re.split(r"^## ", text, flags=re.MULTILINE)

    for section in sections[1:]:  # skip preamble before first ##
        lines = section.strip().split("\n")
        if not lines:
            continue

        name = lines[0].strip()
        full_text = "## " + section.strip()

        watch = ""
        tags: list[str] = []
        since = ""
        status = ""

        for line in lines[1:]:
            stripped = line.strip()
            # Match **watch**: ... or **watch**: `pattern`
            if stripped.startswith("- **watch**:"):
                watch = _extract_field(stripped, "watch")
            elif stripped.startswith("- **tags**:"):
                tags = _extract_tags(stripped)
            elif stripped.startswith("- **since**:"):
                since = _extract_field(stripped, "since")
            elif stripped.startswith("- **status**:"):
                status = _extract_field(stripped, "status")

        if status.lower() == "waiting" and watch:
            entries.append(
                ClaudingEntry(
                    name=name,
                    watch=watch,
                    tags=tags,
                    since=since,
                    status=status,
                    full_text=full_text,
                )
            )

    return entries


def _extract_field(line: str, field_name: str) -> str:
    """Extract value from a '- **field**: value' line."""
    # Remove the prefix
    prefix = f"- **{field_name}**:"
    value = line[len(prefix) :].strip()
    # Strip backticks if present
    if value.startswith("`") and value.endswith("`"):
        value = value[1:-1]
    return value


def _extract_tags(line: str) -> list[str]:
    """Extract backtick-delimited tags from a tags line."""
    return re.findall(r"`([^`]+)`", line)


# ── Pre-filter ───────────────────────────────────────────────────


def pre_filter(
    event: Event,
    entries: list[ClaudingEntry],
    last_eval: float,
    debounce_seconds: float,
) -> bool:
    """Cheap checks before making an API call.

    Returns True if the event should proceed to triage.
    """
    if not entries:
        log.debug("clauding: no waiting entries, skipping")
        return False

    if not event.trusted:
        log.debug("clauding: untrusted sender %s, skipping", event.sender)
        return False

    # Debounce: skip if we evaluated very recently
    if last_eval > 0 and (event.timestamp - last_eval) < debounce_seconds:
        log.debug("clauding: debounce window, skipping")
        return False

    # Tag pre-filter: if ALL entries have tags, and no entry has a matching
    # tag in the event text, skip. If any entry has no tags, always evaluate.
    event_text = f"{event.sender} {event.subject} {event.body}".lower()
    any_tagless = False
    any_tag_match = False

    for entry in entries:
        if not entry.tags:
            any_tagless = True
            break
        for tag in entry.tags:
            if tag.lower() in event_text:
                any_tag_match = True
                break
        if any_tag_match:
            break

    if not any_tagless and not any_tag_match:
        log.debug("clauding: no tag matches, skipping")
        return False

    return True


# ── Triage ───────────────────────────────────────────────────────


def _build_triage_prompt(event: Event, entries: list[ClaudingEntry]) -> str:
    """Build the triage prompt for Haiku."""
    watchers = ""
    for i, entry in enumerate(entries, 1):
        watchers += f"{i}. {entry.name}: {entry.watch}\n"

    return (
        "You are evaluating whether a new event matches any active watcher.\n"
        "Your ONLY job is to decide if the event matches. Do NOT execute actions.\n"
        "\n"
        "## Event\n"
        f"Source: {event.source}\n"
        f"From: {event.sender}\n"
        f"Subject: {event.subject}\n"
        f"Snippet: {event.body[:500]}\n"
        "\n"
        "## Active Watchers\n"
        "\n"
        f"{watchers}"
        "\n"
        "## Respond with EXACTLY one of:\n"
        "- MATCH:<entry-name>\n"
        "- NO_MATCH\n"
    )


def _parse_triage_response(
    text: str, entries: list[ClaudingEntry]
) -> ClaudingEntry | None:
    """Parse triage response. Returns matched entry or None."""
    text = text.strip()
    if text.startswith("MATCH:"):
        name = text[len("MATCH:") :].strip()
        for entry in entries:
            if entry.name == name:
                return entry
        log.warning("clauding: triage returned unknown entry name: %s", name)
        return None
    return None


def _load_api_key() -> str | None:
    """Load API key from ANTHROPIC_API_KEY_FILE or ANTHROPIC_API_KEY."""
    key_file = os.environ.get("ANTHROPIC_API_KEY_FILE")
    if key_file:
        try:
            return Path(key_file).read_text().strip()
        except FileNotFoundError:
            log.error("API key file not found: %s", key_file)
            return None
    return os.environ.get("ANTHROPIC_API_KEY")


async def triage(
    event: Event,
    entries: list[ClaudingEntry],
    client: anthropic.AsyncAnthropic | None = None,
    model: str = TRIAGE_MODEL,
) -> ClaudingEntry | None:
    """Single Haiku API call to match event against entries.

    Returns the matched ClaudingEntry or None.
    """
    if client is None:
        key = _load_api_key()
        if not key:
            log.error("clauding: no API key for triage")
            return None
        client = anthropic.AsyncAnthropic(api_key=key)

    prompt = _build_triage_prompt(event, entries)
    log.debug("clauding triage prompt:\n%s", prompt)

    try:
        response = await client.messages.create(
            model=model,
            max_tokens=TRIAGE_MAX_TOKENS,
            messages=[{"role": "user", "content": prompt}],
        )
        text = ""
        for block in response.content:
            if hasattr(block, "text"):
                text += block.text
        log.info("clauding triage response: %s", text.strip())
        return _parse_triage_response(text, entries)
    except Exception:
        log.exception("clauding triage API call failed")
        return None


# ── Action prompt ────────────────────────────────────────────────


def build_action_prompt(entry: ClaudingEntry, event: Event) -> str:
    """Build the prompt for the headless action session."""
    return (
        "A clauding.md watcher has triggered.\n"
        "\n"
        "## Triggering Event\n"
        f"Source: {event.source}\n"
        f"From: {event.sender}\n"
        f"Subject: {event.subject}\n"
        f"Snippet: {event.body[:500]}\n"
        "\n"
        "## Entry\n"
        f"{entry.full_text}\n"
        "\n"
        "## Instructions\n"
        "1. Execute the action described above.\n"
        "2. Update status in ~/.claude/clauding.md to: done "
        + time.strftime("%Y-%m-%d")
        + "\n"
        "3. Provide a concise summary of what you did.\n"
    )


# ── Evaluator (stateful wrapper) ────────────────────────────────


class ClaudingEvaluator:
    """Stateful wrapper around clauding.md evaluation.

    Holds the file path, debounce state, and lazy API client.
    """

    def __init__(
        self,
        path: Path,
        triage_model: str = TRIAGE_MODEL,
        debounce_seconds: float = 60.0,
    ) -> None:
        self._path = path
        self._triage_model = triage_model
        self._debounce = debounce_seconds
        self._last_eval: float = 0.0
        self._client: anthropic.AsyncAnthropic | None = None

    def get_entries(self) -> list[ClaudingEntry]:
        """Parse clauding.md for waiting entries."""
        try:
            text = self._path.read_text()
        except FileNotFoundError:
            log.warning("clauding.md not found: %s", self._path)
            return []
        return parse_entries(text)

    def check_pre_filter(self, event: Event, entries: list[ClaudingEntry]) -> bool:
        """Run pre-filter checks."""
        return pre_filter(event, entries, self._last_eval, self._debounce)

    async def run_triage(
        self, event: Event, entries: list[ClaudingEntry]
    ) -> ClaudingEntry | None:
        """Run triage and update last_eval timestamp."""
        if self._client is None:
            key = _load_api_key()
            if not key:
                log.error("clauding: no API key available")
                return None
            self._client = anthropic.AsyncAnthropic(api_key=key)

        self._last_eval = event.timestamp
        return await triage(event, entries, self._client, self._triage_model)
