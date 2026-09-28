"""What an agent sends out through a tool: the Claude Code side of the send guard.

Called by `area-guard.py` before each tool call. This file only reads Claude Code's calls: it
finds the sends in them and what each carries, and hands each (destination, payload) to the
judgement in `scanners/send-scan.py`, which decides as for a push (see there for
`destinations.txt`).

- A tool that sends to a service (an MCP tool, the Artifact tools) is named by the tool; its
  payload is every string of the call and the contents of the local files it uploads (the text
  of an Office document or a PDF is taken out of it). A file whose text cannot be taken out
  (too large, or not text) is refused once the session has read inside an area or when the file
  sits inside one; otherwise it passes unscanned.
- WebFetch and WebSearch are named by the tool; their payload is the URL, the prompt and the query.
- A `curl` / `wget` with a body or an upload (`-d`, `--data*`, `--json`, `-F`, `-T`, `--post-*`,
  or `-X POST|PUT|PATCH`) is named `host:<host>`; its payload is the body and the files it sends.

Reading calls are not sends: a tool whose name says it reads (get / list / search / read / fetch /
query / view / find / export / ...), the Artifact tools' reading actions, a network command
without a body, and anything bound for the loopback host (this machine).
"""

from __future__ import annotations

import functools
import importlib.util
import os
import re
import shlex
import subprocess
import tempfile
from pathlib import Path
from typing import NamedTuple
from urllib.parse import urlsplit

# The last word of a tool name (`mcp__server__slack_read_channel` -> `slack_read_channel`) that
# says the call only reads.
READING = re.compile(r"(^|_)(get|list|search|read|fetch|query|view|find|describe|lookup|guide|export|"
                     r"download|authenticate|complete_authentication|open|status|whoami|help)(_|$)", re.I)
# Tools of the host (not MCP) that send to a service. WebFetch and WebSearch fetch, but the URL,
# the prompt and the query they carry reach the search or fetch service, so they are sends.
HOST_SENDERS = {"Artifact", "ArtifactData", "ArtifactComments", "WebFetch", "WebSearch"}
ARTIFACT_READING = {"read", "list", "open", "quickstart"}
ARTIFACT_DATA_READING = {"get", "list", "query"}
# Keys of a tool's input that name local files whose contents are uploaded.
FILE_KEYS = {"file_path", "file_paths", "files", "path", "paths", "attachment", "attachments"}
MAX_FILE = 8 * 1024 * 1024
LOOPBACK = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
CURL_BODY = {"-d", "--data", "--data-ascii", "--data-binary", "--data-raw", "--data-urlencode",
             "-F", "--form", "--form-string", "--json", "-T", "--upload-file"}
CURL_TAKES_VALUE = CURL_BODY | {"-X", "--request", "-H", "--header", "-o", "--output", "-u", "--user",
                                "-A", "--user-agent", "-e", "--referer", "-b", "--cookie", "-c", "--cookie-jar",
                                "--url", "-x", "--proxy", "-m", "--max-time", "-w", "--write-out"}
WGET_BODY = {"--post-data", "--post-file", "--body-data", "--body-file"}
SENDING_METHODS = {"POST", "PUT", "PATCH"}
# Words of a shell command that end one command and start the next.
SHELL_BREAK = {"&&", "||", ";", "|", "&", "|&", ";;", "(", ")"}


def shell_words(command: str) -> list[str]:
    """The words of a shell command, with each control operator (SHELL_BREAK) a word of its own
    and each redirection (`> f`, `2>&1`, `< f`) left out. `shlex.split` keeps `a;` as one word, so
    a break glued to a word was read as an argument of the command before it. Raises ValueError
    on an unclosed quote, as `shlex.split` does."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    words: list[str] = []
    target = False
    for word in lexer:
        if target:
            target = False
            continue
        if word and set(word) <= set("<>&") and set(word) & set("<>"):
            if words and words[-1].isdigit():   # the fd of `2>`: split off by the lexer
                words.pop()
            target = True
            continue
        words.append(word)
    return words


def reads_only(tool: str, args: dict) -> bool:
    if tool == "Artifact":
        return (args.get("action") or "publish") in ARTIFACT_READING or args.get("action") in {"delete", "pin", "unpin"}
    if tool == "ArtifactData":
        return args.get("action") in ARTIFACT_DATA_READING
    if tool == "ArtifactComments":
        return args.get("action") in {"read", "list", "watch", "unwatch"}
    return bool(READING.search(tool.rsplit("__", 1)[-1]))


def strings(value) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [s for v in value.values() for s in strings(v)]
    if isinstance(value, list):
        return [s for v in value for s in strings(v)]
    return []


def local_files(args: dict, cwd: str) -> list[Path]:
    """Existing local files the call names under a file key (the Artifact `files` map included)."""
    found = []
    for key, value in args.items():
        if key not in FILE_KEYS:
            continue
        candidates = strings(value)
        if isinstance(value, dict):
            candidates += [k for k in value if isinstance(k, str)]
        for c in candidates:
            p = Path(os.path.expanduser(c))
            p = p if p.is_absolute() else Path(cwd) / p
            if p.is_file():
                found.append(p)
    return found


class Send(NamedTuple):
    dest: str                            # the destination's name (a tool name, or host:<name>)
    payload: str                         # every text the send carries, files' text included
    unreadable: list[tuple[Path, str]]   # files it uploads whose text cannot be taken out, and why


@functools.lru_cache(maxsize=None)
def corpus_module(send_scan: Path):
    """The private-document scan as a module: Office and PDF text is taken out in that one place."""
    spec = importlib.util.spec_from_file_location("corpus_scan", send_scan.parent / "corpus-scan.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def file_text(path: Path, send_scan: Path) -> tuple[str | None, str]:
    """(text, why) for a file a call uploads. The text of an Office document or a PDF is taken out
    of it. text is None when the file cannot be read as text, and why then says why."""
    suffix = path.suffix.lower()
    try:
        corpus = corpus_module(send_scan)
        if suffix in corpus.OFFICE:
            return "\n".join(corpus.office_units(path)), ""
        if suffix == ".pdf":
            return "\n".join(corpus.pdf_units(path)), ""
        if path.stat().st_size > MAX_FILE:
            return None, f"larger than {MAX_FILE // (1024 * 1024)} MB"
        data = path.read_bytes()
    except Exception:  # noqa: BLE001 — whatever stops the reading, the file counts as unscanned
        return None, "its text could not be taken out"
    if b"\0" in data[:8192]:
        return None, "not a text file"
    return data.decode("utf-8", "replace"), ""


def tool_send(tool: str, args: dict, cwd: str, send_scan: Path) -> Send | None:
    """The send of a tool call that sends, else None."""
    if not (tool.startswith("mcp__") or tool in HOST_SENDERS) or reads_only(tool, args):
        return None
    texts, unreadable = strings(args), []
    for p in local_files(args, cwd):
        text, why = file_text(p, send_scan)
        if text is None:
            unreadable.append((p, why))
        else:
            texts.append(text)
    return Send(tool, "\n".join(texts), unreadable)


def body_text(tool: str, flag: str, value: str, cwd: str, send_scan: Path) -> tuple[str, list[tuple[Path, str]]]:
    """What one body option sends: its text, or the contents of the file it points at (with the
    file itself when its text cannot be taken out)."""
    def contents(ref: str) -> tuple[str, list[tuple[Path, str]]]:
        path = Path(os.path.expanduser(ref))
        path = path if path.is_absolute() else Path(cwd) / path
        text, why = file_text(path, send_scan)
        return (text, []) if text is not None else ("", [(path, why)])
    if (tool, flag) in {("curl", "-T"), ("curl", "--upload-file"), ("wget", "--post-file"), ("wget", "--body-file")}:
        return contents(value)
    if flag == "--data-raw" or tool == "wget":
        return value, []
    # -d @file, --json @file, --data-urlencode [name]@file, -F name=@file / name=<file
    ref = value.split("=", 1)[1] if flag in ("-F", "--form") and "=" in value else value
    if flag == "--data-urlencode" and "@" in value and "=" not in value.split("@", 1)[0]:
        ref = "@" + value.split("@", 1)[1]
    if ref[:1] in ("@", "<") and ref[1:] != "-":
        return contents(ref[1:])
    return value, []


def curl_sends(command: str, cwd: str, send_scan: Path) -> list[Send]:
    """The send of each curl / wget in the command that sends a body or a file."""
    try:
        words = shell_words(command)
    except ValueError:
        return []
    out = []
    i = 0
    while i < len(words):
        tool = os.path.basename(words[i])
        if tool not in ("curl", "wget"):
            i += 1
            continue
        body_flags = CURL_BODY if tool == "curl" else WGET_BODY
        takes_value = CURL_TAKES_VALUE if tool == "curl" else WGET_BODY
        j, body, unreadable, urls, method = i + 1, [], [], [], None
        while j < len(words) and words[j] not in SHELL_BREAK:
            w = words[j]
            flag, eq, inline = w.partition("=") if w.startswith("--") else (w, "", "")
            takes = flag in takes_value and not eq
            value = inline if eq else (words[j + 1] if takes and j + 1 < len(words) else None)
            if flag in body_flags and value is not None:
                text, files = body_text(tool, flag, value, cwd, send_scan)
                body.append(text)
                unreadable += files
            elif flag in ("-X", "--request") and value:
                method = value.upper()
            elif not w.startswith("-"):
                urls.append(w)
            j += 2 if takes else 1
        if body or method in SENDING_METHODS:
            for u in urls:
                host = urlsplit(u if "://" in u else f"http://{u}").hostname or ""
                if host and host not in LOOPBACK:
                    out.append(Send(f"host:{host}", "\n".join(body), unreadable))
        i = j
    return out


def sends(tool: str, args: dict, cwd: str, send_scan: Path) -> list[Send]:
    """Every send the call makes."""
    if tool == "Bash":
        return curl_sends(args.get("command", ""), cwd, send_scan)
    s = tool_send(tool, args, cwd, send_scan)
    return [s] if s is not None else []


def check(tool: str, args: dict, cwd: str, send_scan: Path,
          marks: frozenset[str] = frozenset(), area_of=lambda path: None) -> str | None:
    """The one-line refusal for this call, or None when every send in it passes.

    A file whose text cannot be taken out (too large, or not text) cannot be scanned. It is
    refused when the session has read inside an area (`marks`) or the file itself sits inside
    one (`area_of`); a file a session that read nothing private sends from outside the areas —
    an image it made — passes."""
    for name, payload, unreadable in sends(tool, args, cwd, send_scan):
        for path, why in unreadable:
            area = area_of(path)
            if marks or area:
                because = (f"this session has read inside {', '.join(sorted(marks))}" if marks
                           else f"the file sits inside {area}")
                return f"outgoing: not sent to {name}: {path} cannot be scanned ({why}), and {because}"
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8",
                                         dir=os.environ.get("TMPDIR") or None) as fh:
            fh.write(payload)
            path = fh.name
        try:
            r = subprocess.run(["python3", str(send_scan), "--dest", name, "--text", path],
                               capture_output=True, text=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            return f"outgoing: not sent to {name}: the send scan could not run"
        finally:
            os.unlink(path)
        if r.returncode != 0:
            why = (r.stderr.strip().splitlines() or ["the send scan refused it"])[-1]
            return "outgoing: " + why.removeprefix("send-scan: ")
    return None
