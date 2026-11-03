#!/usr/bin/env python3
"""Bridge Claude Code hook events to the CodexPet state file.

Hooks are registered globally, but this script is a no-op unless the
wrapper exported CODEX_PET_ID for the current Claude process.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

PET_DIR = Path.home() / ".claude" / "pet"
RUN_DIR = PET_DIR / "run"

EVENTS = {
    "SessionStart": "start",
    "UserPromptSubmit": "thinking",
    "Notification": "waiting",
    "Stop": "done",
}

BASH_TOOLS = {"Bash", "BashOutput"}
SEARCH_TOOLS = {
    "Read",
    "Glob",
    "Grep",
    "WebSearch",
    "WebFetch",
    "NotebookRead",
    "WebSearch",
}


def tool_state(name):
    if name in BASH_TOOLS:
        return "bash"
    if name in SEARCH_TOOLS:
        return "search"
    return "tool"


def tool_failed(payload):
    response = payload.get("tool_response")
    if not isinstance(response, dict):
        return False
    if response.get("is_error") is True:
        return True
    error = response.get("error")
    if isinstance(error, str) and error.strip():
        return True
    if isinstance(error, (dict, list)) and error:
        return True
    return False


def clip(value, limit):
    if not isinstance(value, str):
        return ""
    value = " ".join(value.split())
    return value if len(value) <= limit else value[: limit - 1] + "…"


def short_path(path):
    if not isinstance(path, str) or not path:
        return ""
    home = str(Path.home())
    if path.startswith(home):
        return "~" + path[len(home):]
    return path


def tool_detail(name, payload):
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return ""
    if name in ("Bash", "BashOutput"):
        return clip(data.get("command", ""), 90)
    if name in ("Read", "Write", "Edit", "MultiEdit"):
        return clip(short_path(data.get("file_path", "")), 90)
    if name == "NotebookEdit":
        return clip(short_path(data.get("notebook_path", "")), 90)
    if name == "WebFetch":
        return clip(data.get("url", ""), 90)
    if name == "WebSearch":
        return clip(data.get("query", ""), 90)
    if name in ("Task", "Agent"):
        return clip(data.get("description", ""), 90)
    if name in ("Glob", "Grep"):
        return clip(data.get("pattern", ""), 90)
    return ""


def write_status(path, status):
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN_DIR, 0o700)
    tmp = path.with_name("{}.{}.tmp".format(path.name, os.getpid()))
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(status, fh, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main():
    pet_id = os.environ.get("CODEX_PET_ID", "").strip()
    if not pet_id or not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", pet_id):
        return
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            return
        event = payload.get("hook_event_name") or ""
        path = RUN_DIR / "{}.json".format(pet_id)
        if event == "SessionEnd":
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            return
        name = payload.get("tool_name") or ""
        if event == "PreToolUse":
            state = tool_state(name)
        elif event == "PostToolUse":
            state = "failed" if tool_failed(payload) else "thinking"
        elif event == "Notification":
            # "Claude is waiting for your input" fires when the turn is
            # already over; only permission requests truly wait.
            message = payload.get("message") or ""
            state = "done" if "waiting for your input" in message else "waiting"
        else:
            state = EVENTS.get(event)
        if not state:
            return
        message = payload.get("message")
        if not message and state == "failed":
            response = payload.get("tool_response")
            if isinstance(response, dict):
                error = response.get("error")
                if isinstance(error, str):
                    message = error
                elif error:
                    message = json.dumps(error, ensure_ascii=False)
                if not message:
                    message = response.get("stderr")
        status = {
            "state": state,
            "event": event,
            "ts": time.time(),
            "sessionId": payload.get("session_id"),
            "transcript": payload.get("transcript_path"),
            "cwd": payload.get("cwd"),
            "tool": name,
            "detail": tool_detail(name, payload),
            "message": clip(message, 180),
            "prompt": clip(payload.get("prompt"), 300),
            "last": clip(payload.get("last_assistant_message"), 300),
        }
        write_status(path, status)
    except Exception:
        pass


if __name__ == "__main__":
    main()
