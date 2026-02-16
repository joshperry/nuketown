"""Headless agent sessions using the Anthropic API.

Runs Claude as an agent directly via API — no terminal needed.
Reports progress via callback (wired to XMPP by the daemon).
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from pathlib import Path
from typing import Any

import anthropic

log = logging.getLogger(__name__)

DEFAULT_MODEL = "claude-sonnet-4-5-20250929"
MAX_TOKENS = 16384
MAX_TURNS = 200

# ── Tool definitions ──────────────────────────────────────────────

TOOLS = [
    {
        "name": "bash",
        "description": "Execute a bash command. Working directory is the project root.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The bash command to execute.",
                },
            },
            "required": ["command"],
        },
    },
    {
        "name": "read_file",
        "description": "Read the contents of a file.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to the file (absolute or relative to workspace).",
                },
            },
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": "Write content to a file. Creates parent directories if needed.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to the file.",
                },
                "content": {
                    "type": "string",
                    "description": "Content to write.",
                },
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "list_files",
        "description": "List files matching a glob pattern in the workspace.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Glob pattern (e.g. '**/*.py', 'src/*.ts').",
                },
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "search_files",
        "description": "Search file contents for a regex pattern.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Regex pattern to search for.",
                },
                "path": {
                    "type": "string",
                    "description": "Directory or file to search in. Defaults to workspace root.",
                    "default": ".",
                },
                "glob": {
                    "type": "string",
                    "description": "File glob filter (e.g. '*.py').",
                    "default": "",
                },
            },
            "required": ["pattern"],
        },
    },
]


# ── Progress callback type ────────────────────────────────────────

ProgressCallback = Any  # Callable[[str, str], Awaitable[None]] | None


# ── Tool execution ────────────────────────────────────────────────


async def _exec_bash(workspace: Path, command: str) -> str:
    """Execute a bash command in the workspace directory."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "bash",
            "-c",
            command,
            cwd=str(workspace),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "HOME": str(workspace.parent)},
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=300)
        output = stdout.decode(errors="replace")
        if stderr:
            output += "\n" + stderr.decode(errors="replace")
        if proc.returncode != 0:
            output += f"\n[exit code: {proc.returncode}]"
        # Truncate very long output
        if len(output) > 100_000:
            output = output[:50_000] + "\n...[truncated]...\n" + output[-50_000:]
        return output.strip()
    except asyncio.TimeoutError:
        return "[command timed out after 300s]"
    except Exception as exc:
        return f"[error: {exc}]"


def _resolve_path(workspace: Path, path_str: str) -> Path:
    """Resolve a path relative to workspace, preventing traversal."""
    p = Path(path_str)
    if p.is_absolute():
        return p
    resolved = (workspace / p).resolve()
    return resolved


async def _exec_read_file(workspace: Path, path: str) -> str:
    """Read a file from the workspace."""
    try:
        target = _resolve_path(workspace, path)
        content = target.read_text(errors="replace")
        if len(content) > 200_000:
            content = content[:100_000] + "\n...[truncated]...\n" + content[-100_000:]
        return content
    except FileNotFoundError:
        return f"[file not found: {path}]"
    except Exception as exc:
        return f"[error reading {path}: {exc}]"


async def _exec_write_file(workspace: Path, path: str, content: str) -> str:
    """Write content to a file."""
    try:
        target = _resolve_path(workspace, path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return f"Wrote {len(content)} bytes to {target}"
    except Exception as exc:
        return f"[error writing {path}: {exc}]"


async def _exec_list_files(workspace: Path, pattern: str) -> str:
    """List files matching a glob pattern."""
    try:
        matches = sorted(str(p.relative_to(workspace)) for p in workspace.glob(pattern))
        if not matches:
            return f"[no files matching '{pattern}']"
        result = "\n".join(matches[:500])
        if len(matches) > 500:
            result += f"\n...[{len(matches) - 500} more files]"
        return result
    except Exception as exc:
        return f"[error listing files: {exc}]"


async def _exec_search_files(
    workspace: Path, pattern: str, path: str = ".", glob_filter: str = ""
) -> str:
    """Search file contents using grep."""
    cmd = ["grep", "-rn", "--color=never"]
    if glob_filter:
        cmd.extend(["--include", glob_filter])
    cmd.extend(["--", pattern, str(_resolve_path(workspace, path))])
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(workspace),
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=60)
        output = stdout.decode(errors="replace").strip()
        if not output:
            return f"[no matches for '{pattern}']"
        if len(output) > 100_000:
            output = output[:50_000] + "\n...[truncated]...\n" + output[-50_000:]
        return output
    except asyncio.TimeoutError:
        return "[search timed out]"
    except Exception as exc:
        return f"[search error: {exc}]"


async def execute_tool(
    workspace: Path, name: str, input_data: dict[str, Any]
) -> str:
    """Execute a tool and return the result as a string."""
    if name == "bash":
        return await _exec_bash(workspace, input_data["command"])
    if name == "read_file":
        return await _exec_read_file(workspace, input_data["path"])
    if name == "write_file":
        return await _exec_write_file(
            workspace, input_data["path"], input_data["content"]
        )
    if name == "list_files":
        return await _exec_list_files(workspace, input_data["pattern"])
    if name == "search_files":
        return await _exec_search_files(
            workspace,
            input_data["pattern"],
            input_data.get("path", "."),
            input_data.get("glob", ""),
        )
    return f"[unknown tool: {name}]"


# ── Headless session ──────────────────────────────────────────────


def _system_prompt(agent_name: str, workspace: Path) -> str:
    """Build the system prompt for the headless agent."""
    return (
        f"You are {agent_name}, a software agent running in headless mode.\n"
        f"Your workspace is: {workspace}\n\n"
        "You have access to bash, file reading/writing, file listing, and "
        "file searching tools. Use them to complete the task.\n\n"
        "Work carefully and verify your changes. When you are done, provide "
        "a concise summary of what you did."
    )


def _load_api_key() -> str | None:
    """Load API key from the file specified in ANTHROPIC_API_KEY_FILE."""
    key_file = os.environ.get("ANTHROPIC_API_KEY_FILE")
    if not key_file:
        return os.environ.get("ANTHROPIC_API_KEY")
    try:
        return Path(key_file).read_text().strip()
    except FileNotFoundError:
        log.error("API key file not found: %s", key_file)
        return None


class HeadlessSession:
    """Runs a headless Claude agent session via the Anthropic API."""

    def __init__(
        self,
        workspace: Path,
        agent_name: str,
        api_key: str | None = None,
        model: str = DEFAULT_MODEL,
        timeout: int = 14400,
        progress_callback: ProgressCallback = None,
    ) -> None:
        key = api_key or _load_api_key()
        if not key:
            raise ValueError("No API key available for headless session")
        self.workspace = workspace
        self.agent_name = agent_name
        self.client = anthropic.AsyncAnthropic(api_key=key)
        self.model = model
        self.timeout = timeout
        self._progress = progress_callback
        self._turn_count = 0
        self._start_time = 0.0

    async def run(self, prompt: str) -> str:
        """Run the agent session. Returns a completion summary."""
        self._start_time = time.monotonic()
        try:
            return await asyncio.wait_for(
                self._agent_loop(prompt),
                timeout=self.timeout,
            )
        except asyncio.TimeoutError:
            summary = f"Session timed out after {self.timeout}s ({self._turn_count} turns)"
            log.warning(summary)
            return summary

    async def _report(self, event: str, detail: str = "") -> None:
        """Report progress via callback."""
        if self._progress:
            try:
                await self._progress(event, detail)
            except Exception:
                log.debug("progress callback error", exc_info=True)

    async def _agent_loop(self, prompt: str) -> str:
        """Core agent loop: send → tool_use → execute → repeat."""
        messages: list[dict[str, Any]] = [
            {"role": "user", "content": prompt},
        ]

        await self._report("start", prompt[:200])

        while self._turn_count < MAX_TURNS:
            self._turn_count += 1

            response = await self.client.messages.create(
                model=self.model,
                max_tokens=MAX_TOKENS,
                system=_system_prompt(self.agent_name, self.workspace),
                tools=TOOLS,
                messages=messages,
            )

            # Append assistant response
            messages.append({"role": "assistant", "content": response.content})

            if response.stop_reason == "end_turn":
                summary = _extract_text(response)
                await self._report("complete", summary[:500])
                return summary

            if response.stop_reason != "tool_use":
                msg = f"Unexpected stop reason: {response.stop_reason}"
                await self._report("error", msg)
                return msg

            # Execute tool calls
            tool_results = []
            for block in response.content:
                if block.type != "tool_use":
                    continue

                await self._report("tool", f"{block.name}: {_tool_summary(block)}")
                log.info(
                    "turn %d tool: %s %s",
                    self._turn_count,
                    block.name,
                    _tool_summary(block),
                )

                result = await execute_tool(self.workspace, block.name, block.input)
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result,
                    }
                )

            messages.append({"role": "user", "content": tool_results})

        summary = f"Reached maximum turns ({MAX_TURNS})"
        await self._report("error", summary)
        return summary


def _extract_text(response: Any) -> str:
    """Extract text content from a response."""
    parts = []
    for block in response.content:
        if hasattr(block, "text"):
            parts.append(block.text)
    return "\n".join(parts) if parts else "Task completed."


def _tool_summary(block: Any) -> str:
    """One-line summary of a tool call for progress reporting."""
    inp = block.input
    if block.name == "bash":
        cmd = inp.get("command", "")
        return cmd[:80] if len(cmd) <= 80 else cmd[:77] + "..."
    if block.name == "read_file":
        return inp.get("path", "")
    if block.name == "write_file":
        return inp.get("path", "")
    if block.name == "list_files":
        return inp.get("pattern", "")
    if block.name == "search_files":
        return inp.get("pattern", "")
    return str(inp)[:80]
