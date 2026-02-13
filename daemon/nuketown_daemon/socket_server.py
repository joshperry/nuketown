"""Unix socket server for nuketown-daemon.

Listens on a Unix domain socket, speaks JSON-line protocol.
Each line is a JSON object. The server dispatches requests to
a callback and writes back JSON responses.
"""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any, Callable, Coroutine

log = logging.getLogger(__name__)

# Type for the request dispatch callback
Dispatcher = Callable[[dict[str, Any]], Coroutine[Any, Any, dict[str, Any]]]


class SocketServer:
    """asyncio Unix socket server with JSON-line protocol."""

    def __init__(self, socket_path: Path, dispatch: Dispatcher) -> None:
        self.socket_path = socket_path
        self.dispatch = dispatch
        self._server: asyncio.AbstractServer | None = None

    async def start(self) -> None:
        # Remove stale socket
        self.socket_path.unlink(missing_ok=True)

        self._server = await asyncio.start_unix_server(
            self._handle_client,
            path=str(self.socket_path),
        )
        log.info("listening on %s", self.socket_path)

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        self.socket_path.unlink(missing_ok=True)
        log.info("socket server stopped")

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer = "unix-client"
        log.debug("client connected: %s", peer)
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    request = json.loads(line)
                except json.JSONDecodeError as exc:
                    response = {"error": f"invalid JSON: {exc}"}
                else:
                    try:
                        response = await self.dispatch(request)
                    except Exception:
                        log.exception("dispatch error")
                        response = {"error": "internal error"}

                writer.write(json.dumps(response).encode() + b"\n")
                await writer.drain()
        except ConnectionResetError:
            pass
        finally:
            writer.close()
            await writer.wait_closed()
            log.debug("client disconnected: %s", peer)
