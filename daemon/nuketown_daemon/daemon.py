"""Main daemon loop for nuketown-daemon.

Wires config, socket server, bootstrap, and session together.
Processes one task at a time, queuing additional requests.
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

    async def run(self, shutdown_event: asyncio.Event) -> None:
        """Run the daemon until shutdown_event is set."""
        await self._server.start()
        log.info(
            "daemon ready: agent=%s socket=%s",
            self.cfg.agent_name,
            self.cfg.socket_path,
        )
        try:
            await shutdown_event.wait()
        finally:
            await self._shutdown()

    async def _shutdown(self) -> None:
        if self._worker_task and not self._worker_task.done():
            self._worker_task.cancel()
            try:
                await self._worker_task
            except asyncio.CancelledError:
                pass
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
        self._state.state = State.WORKING
        self._state.current = task
        self._worker_task = asyncio.create_task(self._process_task(task))
        return {"status": "accepted", "project": task.project}

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
            self._state.state = State.IDLE
            # Process next queued task
            if self._state.queue:
                next_task = self._state.queue.pop(0)
                self._state.state = State.WORKING
                self._state.current = next_task
                self._worker_task = asyncio.create_task(self._process_task(next_task))
