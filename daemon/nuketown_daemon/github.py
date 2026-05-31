"""GitHub invite auto-acceptance for nuketown agents.

Detects GitHub collaborator and organization invites from email
notifications, then accepts them via the GitHub API (gh CLI).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re

from .mail import MailNotification

log = logging.getLogger(__name__)

# Subject patterns for GitHub invites
# Repo invite: "joshperry invited you to joshperry/inav"
_REPO_INVITE_RE = re.compile(
    r"^(?P<user>\S+) invited you to (?P<repo>\S+/\S+)$"
)
# Org invite: "[GitHub] @joshperry has invited you to join the @loomtex organization"
_ORG_INVITE_RE = re.compile(
    r"^\[GitHub\] @\S+ has invited you to join the @(?P<org>\S+) organization$"
)


def detect_invite(notification: MailNotification) -> dict | None:
    """Check if a mail notification is a GitHub invite.

    Returns a dict describing the invite, or None if not an invite.
    The notification must be DKIM-verified from github.com.

    Returns:
        {"type": "repo", "repo": "owner/name"} for repository invites
        {"type": "org", "org": "orgname"} for organization invites
        None if not a GitHub invite
    """
    # Must be authenticated (DKIM or SPF pass)
    if not notification.auth.trusted:
        return None

    # Must be from github.com domain
    if notification.auth.from_domain != "github.com":
        return None

    m = _REPO_INVITE_RE.match(notification.subject)
    if m:
        return {"type": "repo", "repo": m.group("repo")}

    m = _ORG_INVITE_RE.match(notification.subject)
    if m:
        return {"type": "org", "org": m.group("org")}

    return None


async def _run_gh(*args: str) -> tuple[int, str]:
    """Run a gh CLI command, return (returncode, stdout)."""
    proc = await asyncio.create_subprocess_exec(
        "gh", "api", *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        log.warning("gh api %s failed (rc=%d): %s", " ".join(args), proc.returncode, stderr.decode().strip())
    return proc.returncode, stdout.decode().strip()


async def accept_repo_invite(repo_full_name: str) -> str | None:
    """Accept a pending repository invitation by repo full name.

    Lists pending invitations, finds the one matching the repo,
    and accepts it via PATCH.

    Returns a human-readable result string, or None on failure.
    """
    rc, output = await _run_gh("/user/repository_invitations")
    if rc != 0:
        return None

    try:
        invitations = json.loads(output)
    except json.JSONDecodeError:
        log.error("failed to parse repository invitations response")
        return None

    for inv in invitations:
        inv_repo = inv.get("repository", {}).get("full_name", "")
        if inv_repo == repo_full_name:
            inv_id = inv["id"]
            rc, _ = await _run_gh("-X", "PATCH", f"/user/repository_invitations/{inv_id}")
            if rc == 0:
                perms = inv.get("permissions", "unknown")
                log.info("accepted repo invite: %s (id=%s, permissions=%s)", repo_full_name, inv_id, perms)
                return f"Accepted collaborator invite to {repo_full_name} ({perms})"
            else:
                log.error("failed to accept repo invite: %s (id=%s)", repo_full_name, inv_id)
                return None

    log.warning("no pending invitation found for repo %s", repo_full_name)
    return None


async def accept_org_invite(org: str) -> str | None:
    """Accept a pending organization membership invitation.

    Returns a human-readable result string, or None on failure.
    """
    rc, _ = await _run_gh(
        "-X", "PATCH", f"/user/memberships/orgs/{org}",
        "-f", "state=active",
    )
    if rc == 0:
        log.info("accepted org invite: %s", org)
        return f"Accepted organization invite to {org}"
    else:
        log.error("failed to accept org invite: %s", org)
        return None


async def handle_invite(notification: MailNotification) -> str | None:
    """Detect and accept a GitHub invite from an email notification.

    Returns a human-readable result string if an invite was accepted,
    or None if the email wasn't an invite or acceptance failed.
    """
    invite = detect_invite(notification)
    if invite is None:
        return None

    if invite["type"] == "repo":
        log.info("detected repo invite: %s", invite["repo"])
        return await accept_repo_invite(invite["repo"])
    elif invite["type"] == "org":
        log.info("detected org invite: %s", invite["org"])
        return await accept_org_invite(invite["org"])

    return None
