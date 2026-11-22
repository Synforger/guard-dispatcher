"""What a Monitor call runs, spelled as the shell command the entry guard judges: area-guard.py calls it.

The Monitor tool starts a shell command in the background, or listens to a WebSocket. Either is
judged as a Bash call of that command would be, so every rule on a command holds for a watch. A
socket is spelled as the client that would listen to it; subprotocols reach the server as the call
connects, so they are spelled as the message that client is given to send.
"""

from __future__ import annotations

import shlex

TOOL = "Monitor"


def as_shell(tool: str, arguments: dict) -> tuple[str, dict]:
    """The tool and the input to judge: a Monitor call as the Bash call it amounts to, any other as it is."""
    if tool != TOOL:
        return tool, arguments
    lines = []
    if command := arguments.get("command"):
        lines.append(str(command))
    socket = arguments.get("ws")
    if isinstance(socket, dict) and socket.get("url"):
        address = shlex.quote(str(socket["url"]))
        handed = " ".join(str(protocol) for protocol in socket.get("protocols") or [])
        lines.append(f"wscat -c {address} -x {shlex.quote(handed)}" if handed else f"websocat {address}")
    return "Bash", {"command": "\n".join(lines)}
