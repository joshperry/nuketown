"""Tests for nuketown_daemon.config."""

import os
import textwrap
from pathlib import Path

from nuketown_daemon.config import (
    DaemonConfig,
    RepoConfig,
    XMPPConfig,
    discover_repos,
    load_config,
    load_identity,
    load_repos_toml,
    load_xmpp_config,
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
    assert cfg.xmpp is None


def test_load_xmpp_config(tmp_path: Path) -> None:
    """load_xmpp_config reads jid, password file, and rooms."""
    pw_file = tmp_path / "xmpp-password"
    pw_file.write_text("s3cret\n")

    toml_path = tmp_path / "xmpp.toml"
    toml_path.write_text(textwrap.dedent(f"""\
        jid = "ada@6bit.com"
        password_file = "{pw_file}"
        rooms = ["agents@conference.6bit.com"]
    """))

    cfg = load_xmpp_config(toml_path)
    assert cfg is not None
    assert cfg.jid == "ada@6bit.com"
    assert cfg.password == "s3cret"
    assert cfg.rooms == ["agents@conference.6bit.com"]


def test_load_xmpp_config_missing(tmp_path: Path) -> None:
    """Returns None when xmpp.toml doesn't exist."""
    cfg = load_xmpp_config(tmp_path / "nonexistent.toml")
    assert cfg is None


def test_load_xmpp_config_no_jid(tmp_path: Path) -> None:
    """Returns None when jid is missing."""
    toml_path = tmp_path / "xmpp.toml"
    toml_path.write_text('password_file = "/dev/null"\n')
    cfg = load_xmpp_config(toml_path)
    assert cfg is None


def test_load_xmpp_config_missing_password_file(tmp_path: Path) -> None:
    """Returns None when password file doesn't exist."""
    toml_path = tmp_path / "xmpp.toml"
    toml_path.write_text(textwrap.dedent("""\
        jid = "ada@6bit.com"
        password_file = "/nonexistent/password"
    """))
    cfg = load_xmpp_config(toml_path)
    assert cfg is None


def test_load_xmpp_config_no_password_file(tmp_path: Path) -> None:
    """Works with empty password when no password_file is set."""
    toml_path = tmp_path / "xmpp.toml"
    toml_path.write_text('jid = "ada@6bit.com"\n')
    cfg = load_xmpp_config(toml_path)
    assert cfg is not None
    assert cfg.jid == "ada@6bit.com"
    assert cfg.password == ""


def test_load_xmpp_config_single_room_string(tmp_path: Path) -> None:
    """Handles rooms as a single string (converted to list)."""
    toml_path = tmp_path / "xmpp.toml"
    toml_path.write_text(textwrap.dedent("""\
        jid = "ada@6bit.com"
        rooms = "agents@conference.6bit.com"
    """))
    cfg = load_xmpp_config(toml_path)
    assert cfg is not None
    assert cfg.rooms == ["agents@conference.6bit.com"]
