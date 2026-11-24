"""The ways a command line spells the folder of an agent of this machine, taken out of the line where
it only names a path the command reads or runs.

area-guard.py holds what a command writes into an area's folders to that area's own word list
(area_words_refusal). An agent's folder bears the agent's name, which such a list holds, and it is
where the agent keeps its tools and scratch files: a command that runs a script from there and writes
its output into the area names the folder without writing the name. `pattern` gives the spellings of
every agent's folder (and of the folder Claude Code keeps the agent's scratch files in), and `masked`
takes them out of a command line when each one stands where the caller found a path read or run.
"""

from __future__ import annotations

import re
from pathlib import Path

#: What a spelling of an agent's folder is read as once it is taken out.
PLACEHOLDER = "AGENT_FOLDER"
#: What may follow a spelling of a folder: the rest of a path, or the end of the word.
_ENDED = r"(?=[/'\"\s;|&()<>`]|$)"
#: Claude Code names the folder of a session's scratch files after the folder it started in, every
#: character but a letter or a digit made a dash; one started below the agent's folder adds `-<more>`.
_DASHED_ENDED = r"(?=[-/'\"\s;|&()<>`]|$)"


def pattern(agents: Path | None) -> re.Pattern[str] | None:
    """The spellings of the folder of each agent under `agents` as a command line writes them: the
    full path, from `~`, `$HOME` or `${HOME}`, and the folder Claude Code keeps an agent's scratch
    files in (`/tmp/claude-<uid>/<the folder's path, dashed>`, under `/private` too). None when there
    is no agent."""
    if agents is None or not agents.is_dir():
        return None
    home = str(Path.home())
    forms: list[str] = []
    for agent in sorted(p for p in agents.iterdir() if p.is_dir() and not p.name.startswith((".", "_"))):
        for full in dict.fromkeys([str(agent), str(agent.resolve())]):
            spellings = [re.escape(full)]
            if full.startswith(home + "/"):
                rest = re.escape(full[len(home) + 1:])
                spellings += [rf"~/{rest}", rf"\$HOME/{rest}", rf"\$\{{HOME\}}/{rest}"]
            forms += [f"{spelling}{_ENDED}" for spelling in spellings]
            dashed = re.escape(re.sub(r"[^A-Za-z0-9]", "-", full))
            forms.append(rf"(?:/private)?/tmp/claude-\d+/{dashed}{_DASHED_ENDED}")
    return re.compile("|".join(forms)) if forms else None


def masked(command: str, spellings: re.Pattern[str] | None, read_or_run: int) -> str:
    """`command` with each spelling of an agent's folder made PLACEHOLDER, when the line holds as many
    of them as the caller found in the paths it reads or runs (`read_or_run`); else unchanged, since
    one that stands anywhere else (an `echo`, a heredoc's text) may be what is written."""
    if spellings is None:
        return command
    found = len(spellings.findall(command))
    if not found or found != read_or_run:
        return command
    return spellings.sub(PLACEHOLDER, command)
