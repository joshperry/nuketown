"""Tests for nuketown_daemon.headless."""

import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from nuketown_daemon.headless import (
    HeadlessSession,
    _extract_text,
    _resolve_path,
    _tool_summary,
    execute_tool,
)


@pytest.fixture
def workspace(tmp_path):
    """Create a temporary workspace with some files."""
    (tmp_path / "hello.py").write_text("print('hello')\n")
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "main.py").write_text("def main(): pass\n")
    return tmp_path


# ── Path resolution ─────────────────────────────────────────────


def test_resolve_relative(workspace):
    """Relative paths resolve within workspace."""
    p = _resolve_path(workspace, "hello.py")
    assert p == workspace / "hello.py"


def test_resolve_absolute(workspace):
    """Absolute paths are returned as-is."""
    p = _resolve_path(workspace, "/etc/hosts")
    assert p == Path("/etc/hosts")


# ── Tool execution ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_exec_bash(workspace):
    """bash tool executes commands in workspace."""
    result = await execute_tool(workspace, "bash", {"command": "echo hello"})
    assert "hello" in result


@pytest.mark.asyncio
async def test_exec_bash_cwd(workspace):
    """bash tool runs in workspace directory."""
    result = await execute_tool(workspace, "bash", {"command": "ls hello.py"})
    assert "hello.py" in result


@pytest.mark.asyncio
async def test_exec_bash_exit_code(workspace):
    """Non-zero exit codes are reported."""
    result = await execute_tool(workspace, "bash", {"command": "exit 42"})
    assert "exit code: 42" in result


@pytest.mark.asyncio
async def test_exec_read_file(workspace):
    """read_file returns file contents."""
    result = await execute_tool(workspace, "read_file", {"path": "hello.py"})
    assert "print('hello')" in result


@pytest.mark.asyncio
async def test_exec_read_file_not_found(workspace):
    """read_file handles missing files."""
    result = await execute_tool(workspace, "read_file", {"path": "nope.txt"})
    assert "not found" in result


@pytest.mark.asyncio
async def test_exec_write_file(workspace):
    """write_file creates/overwrites files."""
    result = await execute_tool(
        workspace, "write_file", {"path": "new.txt", "content": "hello world"}
    )
    assert "Wrote" in result
    assert (workspace / "new.txt").read_text() == "hello world"


@pytest.mark.asyncio
async def test_exec_write_file_creates_dirs(workspace):
    """write_file creates parent directories."""
    await execute_tool(
        workspace, "write_file", {"path": "deep/nested/file.txt", "content": "ok"}
    )
    assert (workspace / "deep" / "nested" / "file.txt").read_text() == "ok"


@pytest.mark.asyncio
async def test_exec_list_files(workspace):
    """list_files returns matching paths."""
    result = await execute_tool(workspace, "list_files", {"pattern": "**/*.py"})
    assert "hello.py" in result
    assert "src/main.py" in result


@pytest.mark.asyncio
async def test_exec_list_files_no_match(workspace):
    """list_files handles no matches."""
    result = await execute_tool(workspace, "list_files", {"pattern": "*.rs"})
    assert "no files" in result


@pytest.mark.asyncio
async def test_exec_search_files(workspace):
    """search_files finds content matches."""
    result = await execute_tool(
        workspace, "search_files", {"pattern": "def main"}
    )
    assert "main.py" in result


@pytest.mark.asyncio
async def test_exec_search_files_no_match(workspace):
    """search_files handles no matches."""
    result = await execute_tool(
        workspace, "search_files", {"pattern": "nonexistent_string_xyz"}
    )
    assert "no matches" in result


@pytest.mark.asyncio
async def test_exec_unknown_tool(workspace):
    """Unknown tool names return error."""
    result = await execute_tool(workspace, "unknown_tool", {})
    assert "unknown tool" in result


# ── Response helpers ────────────────────────────────────────────


def test_extract_text():
    """_extract_text pulls text from content blocks."""
    block = MagicMock()
    block.text = "Here is the summary."
    response = MagicMock()
    response.content = [block]
    assert _extract_text(response) == "Here is the summary."


def test_extract_text_no_text():
    """_extract_text returns default when no text blocks."""
    block = MagicMock(spec=[])  # no 'text' attribute
    response = MagicMock()
    response.content = [block]
    assert _extract_text(response) == "Task completed."


def test_tool_summary_bash():
    """_tool_summary returns command for bash."""
    block = MagicMock()
    block.name = "bash"
    block.input = {"command": "git status"}
    assert _tool_summary(block) == "git status"


def test_tool_summary_read():
    """_tool_summary returns path for read_file."""
    block = MagicMock()
    block.name = "read_file"
    block.input = {"path": "src/main.py"}
    assert _tool_summary(block) == "src/main.py"


def test_tool_summary_long_command():
    """_tool_summary truncates long bash commands."""
    block = MagicMock()
    block.name = "bash"
    block.input = {"command": "x" * 200}
    summary = _tool_summary(block)
    assert len(summary) == 80
    assert summary.endswith("...")


# ── HeadlessSession ─────────────────────────────────────────────


def test_session_requires_api_key(workspace):
    """HeadlessSession raises without API key."""
    with patch.dict("os.environ", {}, clear=True):
        with patch("nuketown_daemon.headless._load_api_key", return_value=None):
            with pytest.raises(ValueError, match="No API key"):
                HeadlessSession(workspace=workspace, agent_name="test")


@pytest.mark.asyncio
async def test_session_end_turn(workspace):
    """Session completes when model returns end_turn."""
    text_block = MagicMock()
    text_block.type = "text"
    text_block.text = "All done!"

    response = MagicMock()
    response.stop_reason = "end_turn"
    response.content = [text_block]

    mock_client = AsyncMock()
    mock_client.messages.create = AsyncMock(return_value=response)

    with patch("nuketown_daemon.headless.anthropic") as mock_anthropic:
        mock_anthropic.AsyncAnthropic.return_value = mock_client

        session = HeadlessSession(
            workspace=workspace, agent_name="test", api_key="test-key"
        )
        result = await session.run("do something")

    assert result == "All done!"
    mock_client.messages.create.assert_called_once()


@pytest.mark.asyncio
async def test_session_tool_use_then_end(workspace):
    """Session handles tool_use followed by end_turn."""
    # First response: tool_use
    tool_block = MagicMock()
    tool_block.type = "tool_use"
    tool_block.name = "bash"
    tool_block.input = {"command": "echo hello"}
    tool_block.id = "tool_1"

    response1 = MagicMock()
    response1.stop_reason = "tool_use"
    response1.content = [tool_block]

    # Second response: end_turn
    text_block = MagicMock()
    text_block.type = "text"
    text_block.text = "Done running bash."

    response2 = MagicMock()
    response2.stop_reason = "end_turn"
    response2.content = [text_block]

    mock_client = AsyncMock()
    mock_client.messages.create = AsyncMock(side_effect=[response1, response2])

    with patch("nuketown_daemon.headless.anthropic") as mock_anthropic:
        mock_anthropic.AsyncAnthropic.return_value = mock_client

        session = HeadlessSession(
            workspace=workspace, agent_name="test", api_key="test-key"
        )
        result = await session.run("run echo hello")

    assert result == "Done running bash."
    assert mock_client.messages.create.call_count == 2


@pytest.mark.asyncio
async def test_session_progress_callback(workspace):
    """Progress callback is called during execution."""
    text_block = MagicMock()
    text_block.type = "text"
    text_block.text = "Done."

    response = MagicMock()
    response.stop_reason = "end_turn"
    response.content = [text_block]

    mock_client = AsyncMock()
    mock_client.messages.create = AsyncMock(return_value=response)

    progress_calls = []

    async def progress_cb(event, detail=""):
        progress_calls.append((event, detail))

    with patch("nuketown_daemon.headless.anthropic") as mock_anthropic:
        mock_anthropic.AsyncAnthropic.return_value = mock_client

        session = HeadlessSession(
            workspace=workspace,
            agent_name="test",
            api_key="test-key",
            progress_callback=progress_cb,
        )
        await session.run("test prompt")

    events = [e for e, _ in progress_calls]
    assert "start" in events
    assert "complete" in events


@pytest.mark.asyncio
async def test_session_timeout(workspace):
    """Session returns timeout message when time expires."""

    async def slow_create(**kwargs):
        await asyncio.sleep(10)

    mock_client = AsyncMock()
    mock_client.messages.create = slow_create

    with patch("nuketown_daemon.headless.anthropic") as mock_anthropic:
        mock_anthropic.AsyncAnthropic.return_value = mock_client

        session = HeadlessSession(
            workspace=workspace,
            agent_name="test",
            api_key="test-key",
            timeout=0.1,
        )
        result = await session.run("slow task")

    assert "timed out" in result
