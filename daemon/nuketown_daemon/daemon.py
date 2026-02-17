"""Main daemon loop for nuketown-daemon.

Wires config, socket server, bootstrap, and session together.
Processes one task at a time, queuing additional requests.
Optionally connects to XMPP for presence, messaging, and approval.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any

from .bootstrap import BootstrapError, resolve_workspace
from .config import DaemonConfig, load_config
from .session import launch_session
from .socket_server import SocketServer

log = logging.getLogger(__name__)


class State(Enum):
    IDLE = "idle"
    WORKING = "working"
    BLOCKED = "blocked"


@dataclass
class TaskRequest:
    project: str
    prompt: str = ""
    branch: str = ""
    mode: str = ""  # "interactive", "headless", or "" (auto)
    source: str = ""  # "socket" or "xmpp"
    reply_to: str = ""  # JID to send completion summary to


@dataclass
class DaemonState:
    state: State = State.IDLE
    current: TaskRequest | None = None
    queue: list[TaskRequest] = field(default_factory=list)


class Daemon:
    """Main daemon coordinating all subsystems."""

    def __init__(self, cfg: DaemonConfig | None = None) -> None:
        self.cfg = cfg or load_config()
        self._state = DaemonState()
        self._server = SocketServer(self.cfg.socket_path, self._dispatch)
        self._worker_task: asyncio.Task | None = None  # type: ignore[type-arg]

        # XMPP subsystems (initialised in run() if configured)
        self._xmpp_client = None
        self._presence = None
        self._approval = None

        # Mail watcher (initialised in run() if configured)
        self._mail_task: asyncio.Task | None = None  # type: ignore[type-arg]

        # Clauding evaluator (initialised in run() if clauding.md exists)
        self._clauding = None
        self._eval_task: asyncio.Task | None = None  # type: ignore[type-arg]

    async def run(self, shutdown_event: asyncio.Event) -> None:
        """Run the daemon until shutdown_event is set."""
        await self._server.start()

        # Start XMPP if configured
        if self.cfg.xmpp:
            await self._start_xmpp()

        # Start mail watcher if configured
        if self.cfg.mail:
            self._start_mail()

        # Init clauding evaluator if clauding.md exists
        clauding_path = Path.home() / ".claude" / "clauding.md"
        if clauding_path.exists():
            from .clauding import ClaudingEvaluator

            self._clauding = ClaudingEvaluator(clauding_path)
            log.info("clauding evaluator loaded: %s", clauding_path)

        log.info(
            "daemon ready: agent=%s socket=%s xmpp=%s mail=%s clauding=%s",
            self.cfg.agent_name,
            self.cfg.socket_path,
            self.cfg.xmpp.jid if self.cfg.xmpp else "disabled",
            self.cfg.mail.username if self.cfg.mail else "disabled",
            "enabled" if self._clauding else "disabled",
        )
        try:
            await shutdown_event.wait()
        finally:
            await self._shutdown()

    async def _start_xmpp(self) -> None:
        """Initialise and connect XMPP client, presence, approval."""
        from .xmpp.approval import ApprovalManager
        from .xmpp.client import AgentXMPPClient
        from .xmpp.presence import PresencePublisher

        xmpp_cfg = self.cfg.xmpp
        assert xmpp_cfg is not None

        self._approval = ApprovalManager()

        self._xmpp_client = AgentXMPPClient(
            jid=xmpp_cfg.jid,
            password=xmpp_cfg.password,
            rooms=xmpp_cfg.rooms,
            message_callback=self._xmpp_message,
            approval_callback=self._approval.handle_response,
        )

        self._presence = PresencePublisher(self._xmpp_client)

        await self._xmpp_client.connect_and_run()
        connected = await self._xmpp_client.wait_connected(timeout=30)
        if connected:
            self._presence.update(self._state.state.value)
            log.info("XMPP connected: %s", xmpp_cfg.jid)
        else:
            log.error("XMPP connection failed — continuing without XMPP")
            self._xmpp_client = None
            self._presence = None
            self._approval = None

    async def _xmpp_message(self, data: dict[str, Any]) -> None:
        """Handle an incoming XMPP message as a task request."""
        req_type = data.get("type")
        if req_type == "task":
            # Tag with source so mode selection works
            data.setdefault("source", "xmpp")
            data.setdefault("reply_to", data.get("from", ""))
            result = await self._handle_task(data)
            # Send acceptance/queued response back via XMPP
            from_jid = data.get("from")
            if from_jid and self._xmpp_client:
                import json

                self._xmpp_client.send_message(from_jid, json.dumps(result))

    def _start_mail(self) -> None:
        """Start the IMAP IDLE mail watcher."""
        from .mail import MailWatcher

        mail_cfg = self.cfg.mail
        assert mail_cfg is not None

        self._mail_watcher = MailWatcher(
            host=mail_cfg.host,
            port=mail_cfg.port,
            username=mail_cfg.username,
            password=mail_cfg.password,
            mailbox=mail_cfg.mailbox,
            callback=self._on_mail,
        )
        self._mail_task = asyncio.create_task(self._mail_watcher.run())
        log.info("mail watcher started: %s@%s", mail_cfg.username, mail_cfg.host)

    async def _on_mail(self, notification) -> None:
        """Handle a new mail notification."""
        from .mail import MailNotification

        assert isinstance(notification, MailNotification)
        trust = "verified" if notification.auth.trusted else "UNVERIFIED"
        log.info(
            "mail: from=%s subject=%s [%s] (%s)",
            notification.from_addr,
            notification.subject,
            trust,
            notification.auth.summary,
        )

        # Evaluate against clauding.md watchers
        if self._clauding:
            from .clauding import Event

            event = Event(
                source="mail",
                sender=notification.from_addr,
                subject=notification.subject,
                body=notification.snippet,
                trusted=notification.auth.trusted,
                timestamp=time.monotonic(),
            )
            await self._try_evaluate(event)

    async def _try_evaluate(self, event) -> None:
        """Evaluate an event against clauding.md watchers (if not already running)."""
        if self._eval_task and not self._eval_task.done():
            log.debug("clauding: evaluation already in progress, skipping")
            return
        entries = self._clauding.get_entries()
        if not self._clauding.check_pre_filter(event, entries):
            return
        self._eval_task = asyncio.create_task(self._run_evaluation(event, entries))

    async def _run_evaluation(self, event, entries) -> None:
        """Run clauding triage and dispatch action on match."""
        try:
            match = await self._clauding.run_triage(event, entries)
            if not match:
                return

            log.info("clauding match: %s", match.name)

            # Notify josh via XMPP
            if self._xmpp_client and self.cfg.xmpp:
                self._xmpp_client.send_message(
                    "josh@6bit.com",
                    f"[clauding] triggered: {match.name}\nEvent: {event.subject}",
                )

            # Queue action as headless task
            from .clauding import build_action_prompt

            prompt = build_action_prompt(match, event)
            await self._handle_task(
                {
                    "type": "task",
                    "project": "_clauding",
                    "prompt": prompt,
                    "mode": "headless",
                    "source": "clauding",
                    "reply_to": "josh@6bit.com",
                }
            )
        except Exception:
            log.exception("clauding evaluation failed")

    async def _shutdown(self) -> None:
        if self._eval_task and not self._eval_task.done():
            self._eval_task.cancel()
            try:
                await self._eval_task
            except asyncio.CancelledError:
                pass
        if self._mail_task and not self._mail_task.done():
            if hasattr(self, "_mail_watcher"):
                await self._mail_watcher.stop()
            self._mail_task.cancel()
            try:
                await self._mail_task
            except asyncio.CancelledError:
                pass
        if self._worker_task and not self._worker_task.done():
            self._worker_task.cancel()
            try:
                await self._worker_task
            except asyncio.CancelledError:
                pass
        if self._xmpp_client:
            await self._xmpp_client.disconnect()
            log.info("XMPP disconnected")
        await self._server.stop()
        log.info("daemon shut down")

    async def _dispatch(self, request: dict[str, Any]) -> dict[str, Any]:
        """Handle an incoming socket request."""
        req_type = request.get("type")

        if req_type == "status":
            return self._status_response()

        if req_type == "task":
            return await self._handle_task(request)

        return {"error": f"unknown request type: {req_type}"}

    def _status_response(self) -> dict[str, Any]:
        resp: dict[str, Any] = {"status": self._state.state.value}
        if self._state.current:
            resp["current"] = self._state.current.project
        if self._state.queue:
            resp["queue_length"] = len(self._state.queue)
        if self._xmpp_client:
            resp["xmpp"] = self._xmpp_client.connected
        return resp

    async def _handle_task(self, request: dict[str, Any]) -> dict[str, Any]:
        project = request.get("project", "")
        if not project:
            return {"error": "missing 'project' field"}

        task = TaskRequest(
            project=project,
            prompt=request.get("prompt", ""),
            branch=request.get("branch", ""),
            mode=request.get("mode", ""),
            source=request.get("source", "socket"),
            reply_to=request.get("reply_to", ""),
        )

        if self._state.state == State.WORKING:
            self._state.queue.append(task)
            return {
                "status": "queued",
                "position": len(self._state.queue),
                "current": self._state.current.project if self._state.current else "",
            }

        # Start working on this task
        self._set_state(State.WORKING, task.project)
        self._state.current = task
        self._worker_task = asyncio.create_task(self._process_task(task))
        return {"status": "accepted", "project": task.project}

    def _set_state(self, state: State, detail: str = "") -> None:
        """Update daemon state and publish XMPP presence."""
        self._state.state = state
        if self._presence:
            self._presence.update(state.value, detail)

    def _select_mode(self, task: TaskRequest) -> str:
        """Choose interactive vs headless based on request.

        - Explicit mode in request takes precedence
        - XMPP source defaults to headless
        - Socket source defaults to interactive
        """
        if task.mode in ("interactive", "headless"):
            return task.mode
        if task.source == "xmpp":
            return "headless"
        return "interactive"

    async def _process_task(self, task: TaskRequest) -> None:
        """Process a single task: bootstrap workspace, choose mode, run."""
        summary = ""
        try:
            path = await resolve_workspace(self.cfg, task.project, task.branch)
            mode = self._select_mode(task)
            log.info("processing task %s in %s mode", task.project, mode)

            if mode == "headless":
                summary = await self._run_headless(task, path)
            else:
                await launch_session(
                    self.cfg.agent_name,
                    path,
                    command=self.cfg.agent_command,
                    prompt=task.prompt,
                )
                summary = f"Interactive session launched for {task.project}"

            log.info("task completed: %s (%s)", task.project, mode)
        except BootstrapError as exc:
            summary = f"Bootstrap failed: {exc}"
            log.error("bootstrap failed for %s: %s", task.project, exc)
        except Exception:
            summary = "Unexpected error processing task"
            log.exception("unexpected error processing task %s", task.project)
        finally:
            # Send completion summary via XMPP if requested
            if task.reply_to and self._xmpp_client and summary:
                self._xmpp_client.send_message(task.reply_to, summary)
            self._state.current = None
            # Process next queued task
            if self._state.queue:
                next_task = self._state.queue.pop(0)
                self._set_state(State.WORKING, next_task.project)
                self._state.current = next_task
                self._worker_task = asyncio.create_task(self._process_task(next_task))
            else:
                self._set_state(State.IDLE)

    async def _run_headless(self, task: TaskRequest, workspace: Path) -> str:
        """Run a headless API session for the task."""
        from .headless import HeadlessSession

        progress_cb = None
        if task.reply_to and self._xmpp_client:
            reply_jid = task.reply_to
            xmpp = self._xmpp_client

            async def progress_cb(event: str, detail: str = "") -> None:
                xmpp.send_message(reply_jid, f"[{event}] {detail}")

        model = self.cfg.headless_model or None  # None = use default
        session = HeadlessSession(
            workspace=workspace,
            agent_name=self.cfg.agent_name,
            model=model,
            timeout=self.cfg.headless_timeout,
            progress_callback=progress_cb,
        )
        return await session.run(task.prompt or f"Work on {task.project}")
