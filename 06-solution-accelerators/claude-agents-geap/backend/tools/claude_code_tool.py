"""ADK tool: drives Claude Code via claude-agent-sdk against /workspace.

The tool spawns the Claude Code CLI subprocess (via the SDK), passes the
user's coding task as a prompt, and waits for the result event. Inner
tool calls (Read/Write/Edit/Bash/Grep/Glob) happen inside the subprocess
and are summarized into the returned string.

Phase 3 uses single-turn: each `claude_code(...)` call gets a fresh
ClaudeSDKClient. Phase 4 will reuse one client per ADK Session
(== A2A context_id) for conversational continuity within a GE thread.

Event handling: claude-agent-sdk 0.1.x yields typed objects from
`claude_agent_sdk.types`, NOT dicts (the dict shapes in older docs are
the raw CLI wire format that the SDK parses before yielding). See
`.claude/skills/claude-agent-sdk/SKILL.md` for the full type table and
PROJECT_PLAN.md Lessons learned for the discovery context.
"""

from __future__ import annotations

import logging

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
from claude_agent_sdk.types import (
    AssistantMessage,
    ResultMessage,
    TextBlock,  # noqa: F401 — re-exported for downstream consumers
    ToolUseBlock,
)

log = logging.getLogger(__name__)


async def claude_code(prompt: str) -> str:
    """Invoke the Claude Code coding harness against /workspace.

    Use this whenever the user asks for code, files, scripts, dashboards,
    prototypes, refactoring, or any multi-file change. The harness has
    Read, Write, Edit, Bash, Grep, and Glob tools available within
    /workspace.

    Args:
        prompt: The natural-language coding task. Include any context the
            harness needs (file references, constraints, success criteria).

    Returns:
        The harness's final assistant text, plus a short summary of inner
        tool usage and any files written. Suitable to incorporate directly
        into the orchestrator's reply.

    Raises:
        RuntimeError: if the harness produces no terminal result event,
            or terminates with a non-success subtype.
    """
    options = ClaudeAgentOptions(
        cwd="/workspace",
        permission_mode="bypassPermissions",
        allowed_tools=["Read", "Write", "Edit", "Bash", "Grep", "Glob"],
        model="claude-opus-4-7",
    )

    inner_tools: list[str] = []
    files_written: list[str] = []
    result_text: str | None = None
    error_text: str | None = None

    async with ClaudeSDKClient(options=options) as client:
        await client.query(prompt)
        async for event in client.receive_response():
            # Typed events per claude-agent-sdk 0.1.x; iterate with
            # isinstance, not dict-key lookups.
            if isinstance(event, AssistantMessage):
                for block in event.content or []:
                    if isinstance(block, ToolUseBlock):
                        inner_tools.append(block.name)
                        if block.name == "Write":
                            path = (block.input or {}).get("file_path", "")
                            if path:
                                files_written.append(path)
                    # TextBlock content is assistant chatter; we surface
                    # the final text via ResultMessage below to give the
                    # orchestrator a clean handoff.
            elif isinstance(event, ResultMessage):
                if event.subtype == "success":
                    result_text = event.result or ""
                else:
                    error_text = (
                        f"Claude Code terminated with subtype={event.subtype!r}: "
                        f"{event.result or ''}"
                    )
                break
            # SystemMessage (init) and UserMessage (tool_result echoes)
            # are silently consumed for Phase 3.

    if error_text:
        raise RuntimeError(error_text)
    if result_text is None:
        raise RuntimeError("Claude Code produced no terminal result event")

    parts: list[str] = [result_text]
    if inner_tools:
        head = ", ".join(inner_tools[:8])
        more = f" (+{len(inner_tools) - 8} more)" if len(inner_tools) > 8 else ""
        parts.append(
            f"\n[claude_code ran {len(inner_tools)} tool call(s): {head}{more}]"
        )
    if files_written:
        parts.append(f"[files written: {', '.join(files_written)}]")
    return "\n".join(parts)
