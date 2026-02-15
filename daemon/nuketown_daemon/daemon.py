"""Main daemon loop for nuketown-daemon.

Wires config, socket server, bootstrap, and session together.
Processes one task at a time, queuing additional requests.
Optionally connects to XMPP for presence, messaging, and approval.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from enum import Enum
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

    async def run(self, shutdown_event: asyncio.Event) -> None:
        """Run the daemon until shutdown_event is set."""
        await self._server.start()

        # Start XMPP if configured
        if self.cfg.xmpp:
            await self._start_xmpp()

        log.info(
            "daemon ready: agent=%s socket=%s xmpp=%s",
            self.cfg.agent_name,
            self.cfg.socket_path,
            self.cfg.xmpp.jid if self.cfg.xmpp else "disabled",
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
            result = await self._handle_task(data)
            # Send response back via XMPP if we have a from JID
            from_jid = data.get("from")
            if from_jid and self._xmpp_client:
                import json

                self._xmpp_client.send_message(from_jid, json.dumps(result))

    async def _shutdown(self) -> None:
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

    async def _process_task(self, task: TaskRequest) -> None:
        """Process a single task: bootstrap workspace, launch session."""
        try:
            path = await resolve_workspace(self.cfg, task.project, task.branch)
            await launch_session(
                self.cfg.agent_name,
                path,
                command=self.cfg.agent_command,
                prompt=task.prompt,
            )
            log.info("task completed: %s", task.project)
        except BootstrapError as exc:
            log.error("bootstrap failed for %s: %s", task.project, exc)
        except Exception:
            log.exception("unexpected error processing task %s", task.project)
        finally:
            self._state.current = None
            # Process next queued task
            if self._state.queue:
                next_task = self._state.queue.pop(0)
                self._set_state(State.WORKING, next_task.project)
                self._state.current = next_task
                self._worker_task = asyncio.create_task(self._process_task(next_task))
            else:
                self._set_state(State.IDLE)
