"""Tmux session management for nuketown-daemon.

Matches the portal convention exactly:
  - Server socket: -L portal-<agent>
  - Session name:  basename of project path
  - Flags:         new-session -As (attach if exists)
  - Status bar:    set -g status off
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

log = logging.getLogger(__name__)


async def _run_tmux(args: list[str]) -> tuple[int, str, str]:
    """Run a tmux command, return (returncode, stdout, stderr)."""
    proc = await asyncio.create_subprocess_exec(
        "tmux",
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    return proc.returncode, stdout.decode().strip(), stderr.decode().strip()


def _server_name(agent_name: str) -> str:
    return f"portal-{agent_name}"


def _session_name(project_path: Path) -> str:
    return project_path.name


async def session_exists(agent_name: str, project_path: Path) -> bool:
    """Check if a tmux session already exists for this project."""
    server = _server_name(agent_name)
    session = _session_name(project_path)
    rc, _, _ = await _run_tmux(["-L", server, "has-session", "-t", session])
    return rc == 0


async def launch_session(
    agent_name: str,
    project_path: Path,
    command: str = "claude-code",
    prompt: str = "",
) -> str:
    """Launch (or attach to) a tmux session for the given project.

    Returns the session name.
    """
    server = _server_name(agent_name)
    session = _session_name(project_path)

    # Build the command to run inside the session
    cmd_parts = [command]
    if prompt:
        cmd_parts.append(prompt)
    inner_cmd = " ".join(cmd_parts)

    # new-session -As: attach if session exists, create if not
    # -d: detached (daemon doesn't have a terminal)
    # -c: start directory
    rc, _, stderr = await _run_tmux([
        "-L", server,
        "new-session",
        "-ds", session,
        "-c", str(project_path),
        inner_cmd,
    ])

    if rc != 0:
        if "duplicate session" in stderr or "already exists" in stderr:
            log.info("session %s already exists on %s", session, server)
        else:
            raise RuntimeError(f"tmux new-session failed: {stderr}")
    else:
        # Disable status bar for clean nesting
        await _run_tmux(["-L", server, "set", "-g", "status", "off"])
        log.info("launched session %s on server %s", session, server)

    return session


async def kill_session(agent_name: str, project_path: Path) -> None:
    """Kill a tmux session."""
    server = _server_name(agent_name)
    session = _session_name(project_path)
    await _run_tmux(["-L", server, "kill-session", "-t", session])
    log.info("killed session %s on server %s", session, server)
