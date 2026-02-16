"""Configuration loading for nuketown-daemon.

Reads identity.toml, repos.toml, env vars, and discovers git repos
in ~/projects/.
"""

from __future__ import annotations

import logging
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)


@dataclass
class RepoConfig:
    """A known repository."""

    name: str
    url: str = ""
    branch: str = ""


def _default_socket_path() -> Path:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    return Path(runtime_dir) / "nuketown-daemon.sock"


@dataclass
class XMPPConfig:
    """XMPP connection configuration."""

    jid: str = ""
    password: str = ""
    rooms: list[str] = field(default_factory=list)


@dataclass
class DaemonConfig:
    """Complete daemon configuration."""

    # Identity (from identity.toml)
    agent_name: str = ""
    role: str = ""
    email: str = ""
    domain: str = ""
    home: str = ""
    uid: int = 0

    # Paths
    projects_dir: Path = field(default_factory=lambda: Path.home() / "projects")
    socket_path: Path = field(default_factory=_default_socket_path)

    # Known repos (merged from repos.toml + discovered)
    repos: dict[str, RepoConfig] = field(default_factory=dict)

    # Command to launch in tmux sessions
    agent_command: str = "claude-code"

    # Headless session settings
    headless_timeout: int = 14400  # 4 hours
    headless_model: str = ""  # empty = use default

    # XMPP (None if not configured)
    xmpp: XMPPConfig | None = None


def load_identity(path: Path | None = None) -> dict:
    """Load identity.toml, returning raw dict."""
    if path is None:
        path = (
            Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
            / "nuketown"
            / "identity.toml"
        )
    if not path.exists():
        log.warning("identity.toml not found at %s", path)
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f)


def load_repos_toml(path: Path | None = None) -> dict[str, RepoConfig]:
    """Load repos.toml, returning dict of name -> RepoConfig."""
    if path is None:
        path = (
            Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
            / "nuketown"
            / "repos.toml"
        )
    if not path.exists():
        return {}
    with open(path, "rb") as f:
        data = tomllib.load(f)
    repos = {}
    for name, entry in data.items():
        if isinstance(entry, dict):
            repos[name] = RepoConfig(
                name=name,
                url=entry.get("url", ""),
                branch=entry.get("branch", ""),
            )
    return repos


def discover_repos(projects_dir: Path) -> dict[str, RepoConfig]:
    """Scan projects_dir for directories containing .git."""
    repos = {}
    if not projects_dir.is_dir():
        return repos
    for child in sorted(projects_dir.iterdir()):
        if child.is_dir() and (child / ".git").exists():
            repos[child.name] = RepoConfig(name=child.name)
    return repos


def load_xmpp_config(path: Path | None = None) -> XMPPConfig | None:
    """Load xmpp.toml and read password from file.

    Returns None if xmpp.toml doesn't exist or lacks required fields.
    """
    if path is None:
        path = (
            Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
            / "nuketown"
            / "xmpp.toml"
        )
    if not path.exists():
        return None

    with open(path, "rb") as f:
        data = tomllib.load(f)

    jid = data.get("jid", "")
    if not jid:
        log.warning("xmpp.toml missing 'jid'")
        return None

    password_file = data.get("password_file", "")
    password = ""
    if password_file:
        pw_path = Path(password_file)
        if pw_path.exists():
            password = pw_path.read_text().strip()
        else:
            log.warning("XMPP password file not found: %s", password_file)
            return None

    rooms = data.get("rooms", [])
    if isinstance(rooms, str):
        rooms = [rooms]

    return XMPPConfig(jid=jid, password=password, rooms=rooms)


def load_config() -> DaemonConfig:
    """Build DaemonConfig from all sources."""
    identity = load_identity()

    home = Path(identity.get("home", str(Path.home())))
    projects_dir = home / "projects"

    headless_timeout = int(os.environ.get("NUKETOWN_HEADLESS_TIMEOUT", "14400"))
    headless_model = os.environ.get("NUKETOWN_HEADLESS_MODEL", "")

    cfg = DaemonConfig(
        agent_name=identity.get("name", os.environ.get("USER", "agent")),
        role=identity.get("role", ""),
        email=identity.get("email", ""),
        domain=identity.get("domain", ""),
        home=str(home),
        uid=identity.get("uid", os.getuid()),
        projects_dir=projects_dir,
        headless_timeout=headless_timeout,
        headless_model=headless_model,
    )

    # Merge repos: toml entries take precedence over discovered
    discovered = discover_repos(projects_dir)
    configured = load_repos_toml()
    cfg.repos = {**discovered, **configured}

    # XMPP config (optional)
    cfg.xmpp = load_xmpp_config()

    return cfg
