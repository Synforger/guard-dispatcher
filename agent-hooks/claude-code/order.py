"""The operator's order for a send: judged from the session's transcript (Claude Code side).

A destination declared with `order` in destinations.txt (see scanners/send-scan.py) takes a send
only when all of these hold, read from the transcript Claude Code keeps for the session:

1. The operator's last message orders a send: it holds one of the order phrases of
   `$GUARD_CONFIG_DIR/orders.txt`, outside quotes, in a sentence that does not ask (no `?`) and
   does not go on with one of the file's cancelling tails. Only a message the operator typed
   counts -- one that opens a turn, or one typed while the agent works (Claude Code keeps that
   one as a queued command): a tool result, a hook's text, a task's notice or a skill's text
   never does.
2. In its replies just before that message (after the operator's previous one), the agent showed
   this very call in a fenced block:

       ```send
       tool: slack_send_message
       channel_id: C0123ABCD   a label for the reader
       message:
       The text, as many lines as it takes.
       ```

   A key whose line holds a value takes the first word as the value (the rest is a label for the
   reader); a key with nothing after the colon takes every line after it, so it comes last. The
   call's input must carry exactly the shown keys with the shown values (a false or empty value
   counts as absent), and `tool` names the tool (its last part, or the whole name). A text that
   holds a ``` line of its own goes in a longer fence (````send ... ````).
3. Each shown block is spent by one call. The guard keeps what it let through beside the
   session's marks (`<session>.orders/`), since the transcript does not hold a call until it has
   run; a call the transcript shows as refused or failed gives its block back.

Claude Code writes the transcript behind the conversation, so the guard checks that it has caught
up: the call's `prompt_id` must be the one the transcript holds for the operator's last message
(or, when that message was typed while the agent worked, one the transcript holds at all). When
it has not, the send is refused and passes on a later try.

So an order typed by mistake lets through only the text the operator saw, and the agent can
neither change the text after the order nor send twice on one order. The agent cannot write the
transcript or the guard's settings (area-guard refuses it), so it cannot make an order itself.

orders.txt holds one phrase per line; a line starting with `!` is a cancelling tail (the words
right after a phrase that turn it into something else: asking leave, a negation, the past).
With no file, nothing is ever ordered.

A line starting with `>` is how a relayed message opens. A client that carries messages between
agent sessions types them into the receiver's terminal, where they are recorded as typed text;
it opens each with a fixed line, and a message opening with that line is never the operator's:
it orders nothing, and a turn it opened takes no order. This holds only while agents cannot
reach the client's own way of typing as the operator: declare that endpoint `block` in
destinations.txt (a `local:` or `tmux:` name, see outgoing.py).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import uuid
from pathlib import Path
from typing import NamedTuple

CONFIG = Path(os.environ.get("GUARD_CONFIG_DIR", Path.home() / ".config/guard"))
ORDERS = CONFIG / "orders.txt"
# A fence of three or more backticks, closed by one of the same length.
BLOCK = re.compile(r"^(`{3,})send[ \t]*\n(.*?)^\1[ \t]*$", re.S | re.M)
KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(.*)$")
# Quoted text and pasted text are what someone else wrote or what is to be sent, not an order.
QUOTED = re.compile(r"「[^」]*」|『[^』]*』|<pasted_content[^>]*>.*?</pasted_content[^>]*>", re.S)
# How pasted text opens: Claude Code records a multi-line paste wrapped in this tag.
PASTED_OPENING = re.compile(r"^\s*<pasted_content[^>\n]*>\s*")
SENTENCE_END = re.compile(r"[。．！!\n]")
# A tool whose last part says it drafts keeps the text in the operator's own account.
DRAFT = re.compile(r"(^|_)drafts?(_|$)", re.I)
SHOW = "Show the call in a ```send block and wait for the operator's order"


def is_draft(tool: str) -> bool:
    return bool(DRAFT.search(tool.rsplit("__", 1)[-1]))


def settings() -> tuple[list[str], list[str], list[str]]:
    """(order phrases, cancelling tails, openings of a relayed message) from orders.txt; none
    when it is missing."""
    if not ORDERS.is_file():
        return [], [], []
    orders, tails, relays = [], [], []
    for line in ORDERS.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line[:1] in ("!", ">"):
            if line[1:].strip():
                (tails if line[0] == "!" else relays).append(line[1:].strip())
        elif line:
            orders.append(line)
    return orders, tails, relays


def phrases() -> tuple[list[str], list[str]]:
    return settings()[:2]


def relayed(text: str) -> bool:
    """Whether a message is one a client relayed from another session: it opens with one of the
    `>` lines of orders.txt. It reaches the terminal as typing does, but the operator did not
    write it. A client delivers by pasting, so the opening may stand inside the tag pasted text
    is recorded in."""
    text = PASTED_OPENING.sub("", text, count=1).lstrip()
    return any(text.startswith(opening) for opening in settings()[2])


def orders_a_send(text: str) -> bool:
    orders, tails = phrases()
    text = QUOTED.sub("", text)
    for phrase in orders:
        start = 0
        while (at := text.find(phrase, start)) >= 0:
            start = at + len(phrase)
            rest = text[start:]
            end = SENTENCE_END.search(rest)
            sentence = rest[: end.start()] if end else rest
            # a tail follows the phrase with or without a space (`send it later`, `送信してない`)
            if "?" in sentence or "？" in sentence or any(sentence.lstrip().startswith(t) for t in tails):
                continue
            return True
    return False


def rows(transcript: str | None) -> list[dict]:
    """The main conversation's rows; none when the transcript cannot be read. A subagent's rows
    are not the operator's conversation."""
    out = []
    try:
        with open(transcript or "", encoding="utf-8") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and not row.get("isSidechain"):
                    out.append(row)
    except OSError:
        return []
    return out


def blocks(content) -> list[dict]:
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def content(row: dict) -> list[dict]:
    return blocks((row.get("message") or {}).get("content"))


def text_of(parts: list[dict]) -> str:
    return "\n".join(b.get("text", "") for b in parts if b.get("type") == "text")


def human(origin) -> bool:
    return isinstance(origin, dict) and origin.get("kind") == "human"


def entered(row: dict) -> str | None:
    """The text of a message that came in at the terminal, or None for any other row: one that
    opens a turn (a user row), or one that came while the agent works (a queued command)."""
    if row.get("type") == "user" and human(row.get("origin")) and not row.get("isMeta"):
        return text_of(content(row))
    queued = row.get("attachment") if row.get("type") == "attachment" else None
    if isinstance(queued, dict) and queued.get("type") == "queued_command" \
            and queued.get("commandMode") == "prompt" and human(queued.get("origin")):
        return text_of(blocks(queued.get("prompt")))
    return None


def typed(row: dict) -> str | None:
    """The text of a message the operator typed, or None for any other row. A message a client
    relayed from another session came in at the terminal too, and is not the operator's."""
    text = entered(row)
    return None if text is None or relayed(text) else text


def shown_calls(text: str) -> list[dict[str, str]]:
    calls = []
    for _, body in BLOCK.findall(text):
        fields: dict[str, str] = {}
        lines = body.splitlines()
        for i, line in enumerate(lines):
            m = KEY.match(line)
            if not m:
                continue
            key, rest = m.group(1), m.group(2).strip()
            if rest:
                fields[key] = rest.split()[0]
            else:
                fields[key] = "\n".join(lines[i + 1:]).rstrip("\n")
                break
        if fields:
            calls.append(fields)
    return calls


def value(v) -> str | None:
    """The input value as the shown text spells it; None when it counts as absent."""
    if v is None or v is False or v == "" or v == [] or v == {}:
        return None
    if v is True:
        return "true"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return v.rstrip("\n")
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def same(shown: dict[str, str], tool: str, args: dict) -> bool:
    shown = dict(shown)
    name = shown.pop("tool", None)
    if name not in (tool, tool.rsplit("__", 1)[-1]):
        return False
    given = {k: s for k, v in args.items() if (s := value(v)) is not None}
    return given == shown


class Ordered(NamedTuple):
    """A call the operator ordered: what one shown block lets through."""
    order: str         # the row of the operator's message that ordered it
    call: str          # the call, as a digest of its tool and input
    shown: int         # how many blocks showed this very call
    failed: set[str]   # calls since the order that the transcript shows refused or failed


def ordered(tool: str, args: dict, event: dict | None) -> tuple[str | None, Ordered | None]:
    """(why this send has no order from the operator, None), or (None, the order it has)."""
    event = event or {}
    history = rows(event.get("transcript_path"))
    if not history:
        return "the session's transcript cannot be read, so the operator's order cannot be seen", None
    said = [(i, text) for i, r in enumerate(history) if (text := typed(r)) is not None]
    if not said:
        return "the operator has not written anything in this session yet", None
    last, message = said[-1]
    before = said[-2][0] if len(said) > 1 else -1
    # The transcript is written behind the conversation: a message it does not hold yet would
    # leave an older one standing as the last.
    prompt = event.get("prompt_id")
    opened = next((t for r in history if r.get("type") == "user" and r.get("promptId") == prompt
                   and (t := entered(r)) is not None), None)
    if opened is not None and relayed(opened):
        return ("this turn was opened by a message relayed from another session, not by the operator, "
                f"and only the operator orders a send. {SHOW}"), None
    holds = history[last].get("promptId") == prompt if history[last].get("type") == "user" \
        else any(r.get("type") == "user" and r.get("promptId") == prompt for r in history)
    if not prompt or not holds:
        return ("the session's transcript does not hold the operator's latest message yet, so the "
                "order cannot be seen. Try the call again"), None
    if not orders_a_send(message):
        return f"the operator's last message orders no send ({ORDERS}). {SHOW}", None
    shown = [c for r in history[before + 1:last] if r.get("type") == "assistant"
             for c in shown_calls(text_of(content(r)))]
    matching = sum(1 for c in shown if same(c, tool, args))
    if not matching:
        return ("this call is not one the agent showed just before the operator's order (a ```send "
                f"block with the same tool and the same input). {SHOW}"), None
    failed = {b.get("tool_use_id") for r in history[last + 1:] if r.get("type") == "user"
              for b in content(r) if b.get("type") == "tool_result" and b.get("is_error")}
    given = {k: s for k, v in args.items() if (s := value(v)) is not None}
    call = hashlib.sha256(json.dumps([tool.rsplit("__", 1)[-1], given], ensure_ascii=False,
                                     sort_keys=True).encode()).hexdigest()[:16]
    return None, Ordered(str(history[last].get("uuid") or last), call, matching, failed - {None})


def spend(found: Ordered, event: dict | None, state: Path) -> str | None:
    """Take one of the order's blocks for this call: None when it got one, else why not. Each
    call leaves a file named after it; the calls still standing (not shown as failed) may not
    outnumber the blocks. A call made after another always sees the other's file, so two calls
    racing for one block never both pass."""
    event = event or {}
    folder = state / f"{event.get('session_id') or 'unknown'}.orders"
    mine = str(event.get("tool_use_id") or f"unnamed-{uuid.uuid4().hex}")
    prefix = f"{found.order}.{found.call}."
    try:
        folder.mkdir(parents=True, exist_ok=True)
        (folder / (prefix + mine)).touch()
        standing = [p.name[len(prefix):] for p in folder.iterdir() if p.name.startswith(prefix)]
    except OSError as error:
        return f"the guard could not keep what this order let through ({error})"
    if sum(1 for call in standing if call not in found.failed) > found.shown:
        (folder / (prefix + mine)).unlink(missing_ok=True)
        return "this order has already been spent on the same call: one shown block, one send"
    return None
