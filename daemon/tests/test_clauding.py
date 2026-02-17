"""Tests for nuketown_daemon.clauding."""

import time
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from nuketown_daemon.clauding import (
    ClaudingEntry,
    ClaudingEvaluator,
    Event,
    build_action_prompt,
    parse_entries,
    pre_filter,
    _build_triage_prompt,
    _extract_field,
    _extract_tags,
    _parse_triage_response,
    triage,
)

# ── Sample clauding.md content ───────────────────────────────────

SAMPLE_CLAUDING = """\
# clauding.md

Active watchers.

## k3s-nix-snapshotter

- **watch**: PR #172 in pdtpartners/nix-snapshotter gets merged
- **tags**: `github.com`, `nix-snapshotter`, `172`
- **since**: 2026-02-13
- **status**: waiting

### Context

We're adding nix-snapshotter support to k3s upstream.

### Action

1. Check what version pdtpartners released containing the fix
2. Bump go.mod in k3s branch

## already-done

- **watch**: some old watcher
- **since**: 2026-01-01
- **status**: done 2026-01-15

### Action

Nothing.

## no-tags-entry

- **watch**: Something happens in the universe
- **since**: 2026-02-14
- **status**: waiting

### Action

React to it.
"""


# ── Fixtures ─────────────────────────────────────────────────────


def _make_event(
    sender="notifications@github.com",
    subject="[pdtpartners/nix-snapshotter] Pull request merged: Fix gRPC (#172)",
    body="PR #172 has been merged",
    trusted=True,
    source="mail",
) -> Event:
    return Event(
        source=source,
        sender=sender,
        subject=subject,
        body=body,
        trusted=trusted,
        timestamp=time.monotonic(),
    )


# ── Parsing ──────────────────────────────────────────────────────


def test_parse_entries_finds_waiting():
    entries = parse_entries(SAMPLE_CLAUDING)
    names = [e.name for e in entries]
    assert "k3s-nix-snapshotter" in names
    assert "no-tags-entry" in names
    # "already-done" should be excluded (status: done)
    assert "already-done" not in names


def test_parse_entries_fields():
    entries = parse_entries(SAMPLE_CLAUDING)
    entry = next(e for e in entries if e.name == "k3s-nix-snapshotter")
    assert entry.watch == "PR #172 in pdtpartners/nix-snapshotter gets merged"
    assert entry.tags == ["github.com", "nix-snapshotter", "172"]
    assert entry.since == "2026-02-13"
    assert entry.status == "waiting"
    assert "### Action" in entry.full_text
    assert "## k3s-nix-snapshotter" in entry.full_text


def test_parse_entries_no_tags():
    entries = parse_entries(SAMPLE_CLAUDING)
    entry = next(e for e in entries if e.name == "no-tags-entry")
    assert entry.tags == []
    assert entry.watch == "Something happens in the universe"


def test_parse_entries_empty():
    assert parse_entries("") == []
    assert parse_entries("# Just a heading\nNo entries here.") == []


def test_extract_field():
    assert _extract_field("- **watch**: PR #172 merged", "watch") == "PR #172 merged"
    assert _extract_field("- **watch**: `gh-pr-merged:foo`", "watch") == "gh-pr-merged:foo"


def test_extract_tags():
    assert _extract_tags("- **tags**: `github.com`, `nix-snapshotter`, `172`") == [
        "github.com",
        "nix-snapshotter",
        "172",
    ]
    assert _extract_tags("- **tags**: none") == []


# ── Pre-filter ───────────────────────────────────────────────────


def test_pre_filter_no_entries():
    event = _make_event()
    assert pre_filter(event, [], 0.0, 60.0) is False


def test_pre_filter_untrusted():
    event = _make_event(trusted=False)
    entries = parse_entries(SAMPLE_CLAUDING)
    assert pre_filter(event, entries, 0.0, 60.0) is False


def test_pre_filter_debounce():
    event = _make_event()
    entries = parse_entries(SAMPLE_CLAUDING)
    # last_eval was very recent
    assert pre_filter(event, entries, event.timestamp - 10, 60.0) is False


def test_pre_filter_passes_with_tag_match():
    event = _make_event(subject="nix-snapshotter PR merged")
    entries = [
        ClaudingEntry(
            name="test",
            watch="PR merged",
            tags=["nix-snapshotter"],
            status="waiting",
        )
    ]
    assert pre_filter(event, entries, 0.0, 60.0) is True


def test_pre_filter_skips_no_tag_match():
    event = _make_event(sender="someone@example.com", subject="Hello", body="World")
    entries = [
        ClaudingEntry(
            name="test",
            watch="PR merged",
            tags=["nix-snapshotter", "github.com"],
            status="waiting",
        )
    ]
    assert pre_filter(event, entries, 0.0, 60.0) is False


def test_pre_filter_passes_tagless_entry():
    """If any entry has no tags, always evaluate."""
    event = _make_event(sender="random@example.com", subject="Unrelated", body="stuff")
    entries = [
        ClaudingEntry(
            name="no-tags",
            watch="Something happens",
            tags=[],
            status="waiting",
        )
    ]
    assert pre_filter(event, entries, 0.0, 60.0) is True


def test_pre_filter_mixed_tags_and_tagless():
    """Mix of tagged and tagless entries — tagless means always evaluate."""
    event = _make_event(sender="nobody@example.com", subject="nothing", body="here")
    entries = [
        ClaudingEntry(name="tagged", watch="X", tags=["specific"], status="waiting"),
        ClaudingEntry(name="tagless", watch="Y", tags=[], status="waiting"),
    ]
    assert pre_filter(event, entries, 0.0, 60.0) is True


# ── Triage prompt ────────────────────────────────────────────────


def test_build_triage_prompt():
    event = _make_event()
    entries = parse_entries(SAMPLE_CLAUDING)
    prompt = _build_triage_prompt(event, entries)
    assert "From: notifications@github.com" in prompt
    assert "k3s-nix-snapshotter:" in prompt
    assert "no-tags-entry:" in prompt
    assert "MATCH:<entry-name>" in prompt
    assert "NO_MATCH" in prompt


# ── Triage response parsing ─────────────────────────────────────


def test_parse_triage_match():
    entries = [ClaudingEntry(name="k3s-nix-snapshotter", watch="PR merged")]
    result = _parse_triage_response("MATCH:k3s-nix-snapshotter", entries)
    assert result is not None
    assert result.name == "k3s-nix-snapshotter"


def test_parse_triage_match_with_whitespace():
    entries = [ClaudingEntry(name="k3s-nix-snapshotter", watch="PR merged")]
    result = _parse_triage_response("  MATCH:k3s-nix-snapshotter  \n", entries)
    assert result is not None
    assert result.name == "k3s-nix-snapshotter"


def test_parse_triage_no_match():
    entries = [ClaudingEntry(name="test", watch="X")]
    result = _parse_triage_response("NO_MATCH", entries)
    assert result is None


def test_parse_triage_unknown_name():
    entries = [ClaudingEntry(name="test", watch="X")]
    result = _parse_triage_response("MATCH:nonexistent", entries)
    assert result is None


# ── Triage API call ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_triage_match():
    """Triage returns matched entry on MATCH response."""
    event = _make_event()
    entries = [ClaudingEntry(name="k3s-nix-snapshotter", watch="PR #172 merged")]

    text_block = MagicMock()
    text_block.text = "MATCH:k3s-nix-snapshotter"

    response = MagicMock()
    response.content = [text_block]

    mock_client = AsyncMock()
    mock_client.messages.create = AsyncMock(return_value=response)

    result = await triage(event, entries, client=mock_client)
    assert result is not None
    assert result.name == "k3s-nix-snapshotter"
    mock_client.messages.create.assert_called_once()


@pytest.mark.asyncio
async def test_triage_no_match():
    """Triage returns None on NO_MATCH response."""
    event = _make_event(subject="Unrelated email")
    entries = [ClaudingEntry(name="test", watch="Something specific")]

    text_block = MagicMock()
    text_block.text = "NO_MATCH"

    response = MagicMock()
    response.content = [text_block]

    mock_client = AsyncMock()
    mock_client.messages.create = AsyncMock(return_value=response)

    result = await triage(event, entries, client=mock_client)
    assert result is None


@pytest.mark.asyncio
async def test_triage_api_error():
    """Triage returns None on API error."""
    event = _make_event()
    entries = [ClaudingEntry(name="test", watch="X")]

    mock_client = AsyncMock()
    mock_client.messages.create = AsyncMock(side_effect=Exception("API down"))

    result = await triage(event, entries, client=mock_client)
    assert result is None


@pytest.mark.asyncio
async def test_triage_no_api_key():
    """Triage returns None when no API key available."""
    event = _make_event()
    entries = [ClaudingEntry(name="test", watch="X")]

    with patch.dict("os.environ", {}, clear=True):
        with patch("nuketown_daemon.clauding._load_api_key", return_value=None):
            result = await triage(event, entries, client=None)
    assert result is None


# ── Action prompt ────────────────────────────────────────────────


def test_build_action_prompt():
    event = _make_event()
    entry = ClaudingEntry(
        name="k3s-nix-snapshotter",
        watch="PR #172 merged",
        full_text="## k3s-nix-snapshotter\n\n- **watch**: ...\n\n### Action\n\n1. Do stuff",
    )
    prompt = build_action_prompt(entry, event)
    assert "clauding.md watcher has triggered" in prompt
    assert "From: notifications@github.com" in prompt
    assert "## k3s-nix-snapshotter" in prompt
    assert "Update status" in prompt


# ── ClaudingEvaluator ────────────────────────────────────────────


def test_evaluator_get_entries(tmp_path):
    path = tmp_path / "clauding.md"
    path.write_text(SAMPLE_CLAUDING)
    evaluator = ClaudingEvaluator(path)
    entries = evaluator.get_entries()
    assert len(entries) == 2  # k3s-nix-snapshotter and no-tags-entry


def test_evaluator_get_entries_missing_file(tmp_path):
    path = tmp_path / "nonexistent.md"
    evaluator = ClaudingEvaluator(path)
    entries = evaluator.get_entries()
    assert entries == []


def test_evaluator_pre_filter(tmp_path):
    path = tmp_path / "clauding.md"
    path.write_text(SAMPLE_CLAUDING)
    evaluator = ClaudingEvaluator(path)
    entries = evaluator.get_entries()
    event = _make_event()
    assert evaluator.check_pre_filter(event, entries) is True


@pytest.mark.asyncio
async def test_evaluator_run_triage(tmp_path):
    path = tmp_path / "clauding.md"
    path.write_text(SAMPLE_CLAUDING)
    evaluator = ClaudingEvaluator(path)
    entries = evaluator.get_entries()
    event = _make_event()

    text_block = MagicMock()
    text_block.text = "MATCH:k3s-nix-snapshotter"

    response = MagicMock()
    response.content = [text_block]

    mock_client = AsyncMock()
    mock_client.messages.create = AsyncMock(return_value=response)

    evaluator._client = mock_client
    result = await evaluator.run_triage(event, entries)
    assert result is not None
    assert result.name == "k3s-nix-snapshotter"
    # Verify debounce timestamp was set
    assert evaluator._last_eval == event.timestamp
