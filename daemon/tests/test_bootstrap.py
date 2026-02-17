"""Tests for nuketown_daemon.bootstrap."""

import asyncio
import os
import subprocess
from pathlib import Path

import pytest

from nuketown_daemon.bootstrap import BootstrapError, resolve_workspace
from nuketown_daemon.config import DaemonConfig, RepoConfig


def _init_repo(path: Path) -> None:
    """Create a bare-minimum git repo at path."""
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", str(path)], check=True, capture_output=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"],
        cwd=path,
        check=True,
        capture_output=True,
        env={**os.environ,
             "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@t",
             "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@t",
             "HOME": str(path.parent)},
    )


@pytest.fixture
def cfg(tmp_path: Path) -> DaemonConfig:
    projects = tmp_path / "projects"
    projects.mkdir()
    return DaemonConfig(projects_dir=projects)


@pytest.mark.asyncio
async def test_existing_repo(cfg: DaemonConfig) -> None:
    repo_path = cfg.projects_dir / "myrepo"
    _init_repo(repo_path)
    result = await resolve_workspace(cfg, "myrepo")
    assert result == repo_path


@pytest.mark.asyncio
async def test_existing_repo_with_branch(cfg: DaemonConfig) -> None:
    repo_path = cfg.projects_dir / "myrepo"
    _init_repo(repo_path)
    result = await resolve_workspace(cfg, "myrepo", branch="feature")
    assert result == repo_path
    # Verify we're on the new branch
    proc = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=repo_path,
        capture_output=True,
        text=True,
    )
    assert proc.stdout.strip() == "feature"


@pytest.mark.asyncio
async def test_clone_from_config(cfg: DaemonConfig, tmp_path: Path) -> None:
    # Create a "remote" repo to clone from
    remote = tmp_path / "remote.git"
    _init_repo(remote)

    cfg.repos["myrepo"] = RepoConfig(
        name="myrepo",
        url=str(remote),
        branch="main",
    )
    result = await resolve_workspace(cfg, "myrepo")
    assert result == cfg.projects_dir / "myrepo"
    assert (result / ".git").exists()


@pytest.mark.asyncio
async def test_unknown_project(cfg: DaemonConfig) -> None:
    with pytest.raises(BootstrapError, match="unknown project"):
        await resolve_workspace(cfg, "nonexistent")
