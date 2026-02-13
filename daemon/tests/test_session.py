"""Tests for nuketown_daemon.session."""

from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from nuketown_daemon.session import (
    _server_name,
    _session_name,
    launch_session,
    session_exists,
)


def test_server_name() -> None:
    assert _server_name("ada") == "portal-ada"


def test_session_name() -> None:
    assert _session_name(Path("/agents/ada/projects/nuketown")) == "nuketown"
    assert _session_name(Path("/home/josh/dev/myproject")) == "myproject"


@pytest.mark.asyncio
@patch("nuketown_daemon.session._run_tmux", new_callable=AsyncMock)
async def test_session_exists_true(mock_tmux: AsyncMock) -> None:
    mock_tmux.return_value = (0, "", "")
    result = await session_exists("ada", Path("/projects/nuketown"))
    assert result is True
    mock_tmux.assert_called_once_with(
        ["-L", "portal-ada", "has-session", "-t", "nuketown"]
    )


@pytest.mark.asyncio
@patch("nuketown_daemon.session._run_tmux", new_callable=AsyncMock)
async def test_session_exists_false(mock_tmux: AsyncMock) -> None:
    mock_tmux.return_value = (1, "", "no session")
    result = await session_exists("ada", Path("/projects/nuketown"))
    assert result is False


@pytest.mark.asyncio
@patch("nuketown_daemon.session._run_tmux", new_callable=AsyncMock)
async def test_launch_session(mock_tmux: AsyncMock) -> None:
    mock_tmux.return_value = (0, "", "")
    session = await launch_session(
        "ada", Path("/projects/nuketown"), command="claude-code"
    )
    assert session == "nuketown"
    # First call: new-session
    assert mock_tmux.call_args_list[0].args[0] == [
        "-L", "portal-ada",
        "new-session", "-ds", "nuketown",
        "-c", "/projects/nuketown",
        "claude-code",
    ]
    # Second call: set status off
    assert mock_tmux.call_args_list[1].args[0] == [
        "-L", "portal-ada", "set", "-g", "status", "off",
    ]


@pytest.mark.asyncio
@patch("nuketown_daemon.session._run_tmux", new_callable=AsyncMock)
async def test_launch_session_with_prompt(mock_tmux: AsyncMock) -> None:
    mock_tmux.return_value = (0, "", "")
    session = await launch_session(
        "ada",
        Path("/projects/nuketown"),
        command="claude-code",
        prompt="fix the bug",
    )
    assert session == "nuketown"
    new_session_args = mock_tmux.call_args_list[0].args[0]
    assert new_session_args[-1] == "claude-code fix the bug"


@pytest.mark.asyncio
@patch("nuketown_daemon.session._run_tmux", new_callable=AsyncMock)
async def test_launch_session_already_exists(mock_tmux: AsyncMock) -> None:
    mock_tmux.return_value = (1, "", "duplicate session: nuketown")
    session = await launch_session("ada", Path("/projects/nuketown"))
    assert session == "nuketown"
