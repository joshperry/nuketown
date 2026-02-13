"""Tests for nuketown_daemon.config."""

import os
import textwrap
from pathlib import Path

from nuketown_daemon.config import (
    DaemonConfig,
    RepoConfig,
    discover_repos,
    load_config,
    load_identity,
    load_repos_toml,
)


def test_load_identity(tmp_path: Path) -> None:
    toml_path = tmp_path / "identity.toml"
    toml_path.write_text(textwrap.dedent("""\
        name = "ada"
        role = "software"
        email = "ada@test.local"
        domain = "test.local"
        home = "/agents/ada"
        uid = 1100
    """))
    data = load_identity(toml_path)
    assert data["name"] == "ada"
    assert data["uid"] == 1100
    assert data["role"] == "software"


def test_load_identity_missing(tmp_path: Path) -> None:
    data = load_identity(tmp_path / "nonexistent.toml")
    assert data == {}


def test_load_repos_toml(tmp_path: Path) -> None:
    toml_path = tmp_path / "repos.toml"
    toml_path.write_text(textwrap.dedent("""\
        [nuketown]
        url = "git@github.com:example/nuketown.git"
        branch = "main"

        [myproject]
        url = "https://github.com/example/myproject.git"
    """))
    repos = load_repos_toml(toml_path)
    assert "nuketown" in repos
    assert repos["nuketown"].url == "git@github.com:example/nuketown.git"
    assert repos["nuketown"].branch == "main"
    assert repos["myproject"].branch == ""


def test_load_repos_toml_missing(tmp_path: Path) -> None:
    repos = load_repos_toml(tmp_path / "nonexistent.toml")
    assert repos == {}


def test_discover_repos(tmp_path: Path) -> None:
    # Create two "repos" and one non-repo dir
    (tmp_path / "alpha" / ".git").mkdir(parents=True)
    (tmp_path / "beta" / ".git").mkdir(parents=True)
    (tmp_path / "not-a-repo").mkdir()

    repos = discover_repos(tmp_path)
    assert set(repos.keys()) == {"alpha", "beta"}


def test_discover_repos_empty(tmp_path: Path) -> None:
    repos = discover_repos(tmp_path / "nonexistent")
    assert repos == {}


def test_default_socket_path() -> None:
    cfg = DaemonConfig()
    assert cfg.socket_path.name == "nuketown-daemon.sock"


def test_load_config_minimal(tmp_path: Path, monkeypatch: object) -> None:
    """load_config works with no identity.toml or repos.toml."""
    monkeypatch.setenv("HOME", str(tmp_path))  # type: ignore[attr-defined]
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / ".config"))  # type: ignore[attr-defined]
    (tmp_path / "projects").mkdir()
    cfg = load_config()
    assert isinstance(cfg, DaemonConfig)
    assert cfg.repos == {}
