"""Workspace bootstrap for nuketown-daemon.

Resolves a project name to a ready working directory:
  1. ~/projects/<name> exists → checkout branch (if specified)
  2. Name in repos config with URL → git clone + checkout
  3. Otherwise → error (LLM fallback deferred to Phase 2)
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from .config import DaemonConfig

log = logging.getLogger(__name__)


class BootstrapError(Exception):
    """Raised when a project cannot be resolved."""


async def _run_git(args: list[str], cwd: Path | None = None) -> str:
    """Run a git command, return stdout. Raises on non-zero exit."""
    proc = await asyncio.create_subprocess_exec(
        "git",
        *args,
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise BootstrapError(
            f"git {' '.join(args)} failed (rc={proc.returncode}): "
            f"{stderr.decode().strip()}"
        )
    return stdout.decode().strip()


async def resolve_workspace(
    cfg: DaemonConfig,
    project: str,
    branch: str = "",
) -> Path:
    """Resolve project name to a ready working directory.

    Returns the absolute path to the project directory.
    Raises BootstrapError if the project can't be resolved.
    """
    project_path = cfg.projects_dir / project

    # Fast path 1: directory already exists
    if project_path.is_dir() and (project_path / ".git").exists():
        log.info("project %s exists at %s", project, project_path)
        if branch:
            await _checkout(project_path, branch)
        return project_path

    # Fast path 2: known repo with URL
    repo = cfg.repos.get(project)
    if repo and repo.url:
        log.info("cloning %s from %s", project, repo.url)
        await _run_git(["clone", repo.url, str(project_path)])
        effective_branch = branch or repo.branch
        if effective_branch:
            await _checkout(project_path, effective_branch)
        return project_path

    raise BootstrapError(
        f"unknown project '{project}': not in ~/projects/ and no URL configured"
    )


async def _checkout(project_path: Path, branch: str) -> None:
    """Checkout a branch, creating it if it doesn't exist remotely."""
    try:
        await _run_git(["checkout", branch], cwd=project_path)
    except BootstrapError:
        # Branch might not exist locally — try creating from current HEAD
        log.info("branch %s not found, creating", branch)
        await _run_git(["checkout", "-b", branch], cwd=project_path)
