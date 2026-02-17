"""Tests for nuketown_daemon.socket_server."""

import asyncio
import json
from pathlib import Path

import pytest

from nuketown_daemon.socket_server import SocketServer


async def _echo_dispatch(request: dict) -> dict:
    """Echo dispatcher for testing."""
    return {"echo": request}


@pytest.fixture
def socket_path(tmp_path: Path) -> Path:
    return tmp_path / "test.sock"


@pytest.mark.asyncio
async def test_request_response(socket_path: Path) -> None:
    server = SocketServer(socket_path, _echo_dispatch)
    await server.start()
    try:
        reader, writer = await asyncio.open_unix_connection(str(socket_path))
        request = {"type": "status"}
        writer.write(json.dumps(request).encode() + b"\n")
        await writer.drain()

        line = await reader.readline()
        response = json.loads(line)
        assert response == {"echo": {"type": "status"}}

        writer.close()
        await writer.wait_closed()
    finally:
        await server.stop()


@pytest.mark.asyncio
async def test_invalid_json(socket_path: Path) -> None:
    server = SocketServer(socket_path, _echo_dispatch)
    await server.start()
    try:
        reader, writer = await asyncio.open_unix_connection(str(socket_path))
        writer.write(b"not json\n")
        await writer.drain()

        line = await reader.readline()
        response = json.loads(line)
        assert "error" in response
        assert "invalid JSON" in response["error"]

        writer.close()
        await writer.wait_closed()
    finally:
        await server.stop()


@pytest.mark.asyncio
async def test_multiple_requests(socket_path: Path) -> None:
    server = SocketServer(socket_path, _echo_dispatch)
    await server.start()
    try:
        reader, writer = await asyncio.open_unix_connection(str(socket_path))

        for i in range(3):
            request = {"n": i}
            writer.write(json.dumps(request).encode() + b"\n")
            await writer.drain()
            line = await reader.readline()
            response = json.loads(line)
            assert response == {"echo": {"n": i}}

        writer.close()
        await writer.wait_closed()
    finally:
        await server.stop()


@pytest.mark.asyncio
async def test_stale_socket_removed(socket_path: Path) -> None:
    # Create a stale socket file
    socket_path.touch()
    server = SocketServer(socket_path, _echo_dispatch)
    await server.start()
    assert socket_path.exists()
    await server.stop()


@pytest.mark.asyncio
async def test_dispatch_error(socket_path: Path) -> None:
    async def _bad_dispatch(request: dict) -> dict:
        raise RuntimeError("boom")

    server = SocketServer(socket_path, _bad_dispatch)
    await server.start()
    try:
        reader, writer = await asyncio.open_unix_connection(str(socket_path))
        writer.write(json.dumps({"type": "status"}).encode() + b"\n")
        await writer.drain()
        line = await reader.readline()
        response = json.loads(line)
        assert response == {"error": "internal error"}

        writer.close()
        await writer.wait_closed()
    finally:
        await server.stop()
