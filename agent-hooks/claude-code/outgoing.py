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
- A browser tool (an MCP call naming a `tabId`) types into the page its tab shows, so it is named
  `browser:<host>` once this session has opened that tab at a page (an MCP call carrying both the
  `tabId` and an http(s) `url`, a navigate); until then it is named by the tool. The tab keeps the
  host it was opened at: a page reached later by a click inside it is not seen.
- A `curl` / `wget` with a body or an upload (`-d`, `--data*`, `--json`, `-F`, `-T`, `--post-*`,
  or `-X POST|PUT|PATCH`) is named `host:<host>`; its payload is the body and the files it sends.
  One without a body is a reading call whose payload is its URLs (a query string reaches the host).
- Code written into the command (`python -c`, `node -e`, a heredoc fed to an interpreter) is named
  `host:<host>` for each URL it names, and its payload is the code. A shell's `-c` string is read
  as a command line of its own. A script in a file is not read.

Only a destination declared in destinations.txt (or outside by send-scan's defaults) is judged: an
undeclared one passes, with nothing scanned or refused (see send-scan.py).

A reading call (a tool whose name says it reads: get / list / search / read / fetch / query / view /
find / export / ..., or an Artifact tool's reading action) still hands the service its own
strings -- a search term, a query, a URL -- so those are scanned, but the files it names are not
read, and a destination blocked for sending still takes reads. A local path in a call's arguments
(a file to upload, a folder to save into) is not what the service receives: the files' text is. A network command without a body
and anything bound for the loopback host (this machine) are not sends.
"""

from __future__ import annotations

import functools
import importlib.util
import os
import re
import shlex
import subprocess
from pathlib import Path
from typing import NamedTuple
from urllib.parse import unquote_plus, urlsplit

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


def is_local_path(text: str) -> bool:
    """An absolute or ~ path on this machine (its folder exists): a name for a local file, not text sent."""
    if not text.startswith(("/", "~")) or "\n" in text:
        return False
    return Path(os.path.expanduser(text)).parent.is_dir()


def sent_strings(args: dict) -> list[str]:
    return [t for t in strings(args) if not is_local_path(t)]


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
    unknown: str | None = None          # why the body is only known when the command runs, if it is
    reading: bool = False                # a reading call: only its own strings reach the service


@functools.lru_cache(maxsize=None)
def corpus_module(send_scan: Path):
    """The private-document scan as a module: Office and PDF text is taken out in that one place."""
    spec = importlib.util.spec_from_file_location("corpus_scan", send_scan.parent / "corpus-scan.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@functools.lru_cache(maxsize=None)
def send_scan_module(send_scan: Path):
    """send-scan.py as a module: where a destination sits is decided there, in one place."""
    spec = importlib.util.spec_from_file_location("send_scan", send_scan)
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


def tab_ids(value) -> set[str]:
    """Every `tabId` a tool's input names, at any depth (a batch of browser actions names several)."""
    if isinstance(value, dict):
        found = {str(v) for k, v in value.items() if k == "tabId" and isinstance(v, (int, str))}
        return found.union(*(tab_ids(v) for k, v in value.items() if k != "tabId"))
    if isinstance(value, list):
        return set().union(*(tab_ids(v) for v in value))
    return set()


def opened_host(tool: str, args: dict) -> str | None:
    """The host a browser call opens its tab at (an MCP call with a `tabId` and an http(s) `url`)."""
    url = args.get("url")
    if not tool.startswith("mcp__") or not isinstance(url, str) or not tab_ids(args):
        return None
    parts = urlsplit(url)
    return parts.hostname if parts.scheme in ("http", "https") else None


def destination_of(tool: str, args: dict, tabs: dict | None) -> str:
    """A tool's destination name: `browser:<host>` for a browser call whose tabs this session has
    opened at one host (or that opens its tab now), else the tool's own name."""
    if not tool.startswith("mcp__") or not (ids := tab_ids(args)):
        return tool
    if host := opened_host(tool, args):
        return f"browser:{host}"
    hosts = {(tabs or {}).get(i) for i in ids}
    return f"browser:{hosts.pop()}" if len(hosts) == 1 and None not in hosts else tool


def tool_send(tool: str, args: dict, cwd: str, send_scan: Path, tabs: dict | None = None) -> Send | None:
    """The send of a tool call that sends, else None."""
    if not (tool.startswith("mcp__") or tool in HOST_SENDERS):
        return None
    name = destination_of(tool, args, tabs)
    if reads_only(tool, args):
        # A search term, a query or a URL still reaches the service; the files named are not uploaded.
        return Send(name, "\n".join(sent_strings(args)), [], reading=True)
    texts, unreadable = sent_strings(args), []
    for p in local_files(args, cwd):
        text, why = file_text(p, send_scan)
        if text is None:
            unreadable.append((p, why))
        else:
            texts.append(text)
    return Send(name, "\n".join(texts), unreadable)


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


class Command(NamedTuple):
    words: list[str]
    stdin: tuple[str, str] | None   # ("file", path) / ("text", here-string) / ("unknown", why)


def simple_commands(command: str) -> list[Command]:
    """The simple commands of a shell command line, each with where its standard input comes
    from: `< file`, a here-string `<<< text`, or something only known when it runs (a heredoc,
    or a pipe from the command before). Other redirections are left out, as in shell_words.
    Raises ValueError on an unclosed quote."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    out: list[Command] = []
    words: list[str] = []
    stdin: tuple[str, str] | None = None
    redirect: str | None = None
    piped = False
    for word in lexer:
        if redirect is not None:
            if redirect == "<":
                stdin = ("file", word)
            elif redirect == "<<<":
                stdin = ("text", word)
            redirect = None
            continue
        if word in SHELL_BREAK:
            out.append(Command(words, stdin or (("unknown", "a pipe") if piped else None)))
            piped, words, stdin = word in ("|", "|&"), [], None
            continue
        if word and set(word) <= set("<>&-") and set(word) & set("<>"):
            if words and words[-1].isdigit():   # the fd of `2>`: split off by the lexer
                words.pop()
            if word.startswith("<<") and word != "<<<":
                stdin = ("unknown", "a heredoc")
            redirect = word
            continue
        words.append(word)
    out.append(Command(words, stdin or (("unknown", "a pipe") if piped else None)))
    return [c for c in out if c.words]


# A body whose text the shell makes when the command runs: a substitution or a variable.
RUNTIME_TEXT = re.compile(r"[`$]")
# Body values that send the command's standard input.
STDIN_REFS = {"@-", "-", "<-"}


def curl_sends(command: str, cwd: str, send_scan: Path) -> list[Send]:
    """The send of each curl / wget in the command that sends a body or a file.

    A body known only when the command runs (a substitution or a variable, or standard input
    from a pipe or a heredoc) cannot be scanned; its send carries `unknown`, and when the shell
    split the substitution off and took the URL with it, the destination is `host:?`."""
    try:
        commands = simple_commands(command)
    except ValueError:
        return []
    out = []
    for words, stdin in commands:
        tool = os.path.basename(words[0])
        if tool not in ("curl", "wget"):
            continue
        body_flags = CURL_BODY if tool == "curl" else WGET_BODY
        takes_value = CURL_TAKES_VALUE if tool == "curl" else WGET_BODY
        j, body, unreadable, urls, method, unknown = 1, [], [], [], None, None
        while j < len(words):
            w = words[j]
            flag, eq, inline = w.partition("=") if w.startswith("--") else (w, "", "")
            takes = flag in takes_value and not eq
            value = inline if eq else (words[j + 1] if takes and j + 1 < len(words) else None)
            if flag in body_flags and value is not None:
                ref = value.split("=", 1)[1] if flag in ("-F", "--form") and "=" in value else value
                if RUNTIME_TEXT.search(value):
                    unknown = "a substitution or a variable"
                elif ref in STDIN_REFS or (tool == "wget" and value == "-"):
                    kind, source = stdin or ("text", "")
                    if kind == "unknown":
                        unknown = source
                    elif kind == "text":
                        body.append(source)
                    else:
                        text, files = body_text(tool, "-T", source, cwd, send_scan) if tool == "curl" \
                            else body_text(tool, "--post-file", source, cwd, send_scan)
                        body.append(text)
                        unreadable += files
                else:
                    text, files = body_text(tool, flag, value, cwd, send_scan)
                    body.append(text)
                    unreadable += files
            elif flag in ("-X", "--request") and value:
                method = value.upper()
            elif not w.startswith("-"):
                urls.append(w)
            j += 2 if takes else 1
        hosts = [urlsplit(u if "://" in u else f"http://{u}").hostname or "" for u in urls]
        hosts = [h for h in hosts if h]
        if not (body or unknown or method in SENDING_METHODS):
            # A fetch: its URL -- the path and the query -- still reaches the host.
            # Decoded as well: `+` and `%20` hide the words a query carries.
            text = "\n".join(urls + [unquote_plus(u) for u in urls])
            out += [Send(f"host:{h}", text, [], reading=True) for h in hosts if h not in LOOPBACK]
            continue
        if unknown and not hosts:
            out.append(Send("host:?", "", unreadable, unknown))
        for host in hosts:
            if host not in LOOPBACK:
                out.append(Send(f"host:{host}", "\n".join(body), unreadable, unknown))
    return out


# --- network commands other than curl / wget --------------------------------------------------
# Each reader takes one simple command and returns its sends. What it sends is scanned like a
# curl body: the text it carries, the files it uploads (a folder counts as a file that cannot be
# scanned), and its standard input.

# Options that take a value, per command (the value is not a path or a destination).
VALUED = {
    "scp": set("cFiJloPS"),
    "ssh": set("bcDEeFIiJLlmOopQRSWw"),
    "rsync": {"e", "f", "B", "M", "T"},
    "nc": set("epsiwxXqTOIVc"),
    "mail": {"s", "c", "b", "r", "a"},
    "http": {"a", "o"},
}
RSYNC_VALUED = {"--rsh", "--exclude", "--include", "--filter", "--exclude-from", "--include-from",
                "--files-from", "--password-file", "--port", "--log-file", "--temp-dir", "--chmod",
                "--chown", "--rsync-path", "--timeout", "--bwlimit"}
HTTP_VALUED = {"--auth", "--session", "--session-read-only", "--output", "--verify", "--cert",
               "--cert-key", "--auth-type", "--proxy", "--timeout", "--print", "--style", "--format-options"}
SOCKET_ADDRESS = re.compile(r"(?i)^(tcp|tcp4|tcp6|udp|udp4|udp6|ssl|openssl|sctp)[\w-]*:([^:,]+)")


def split_options(words: list[str], short_valued: set[str], long_valued: set[str] = frozenset()):
    """(options, positionals) of a command's arguments; an option's value is kept with it."""
    options, positional, j = [], [], 0
    while j < len(words):
        w = words[j]
        if w == "--":
            positional += words[j + 1:]
            break
        if w.startswith("--"):
            takes = w in long_valued
            options.append((w, words[j + 1] if takes and j + 1 < len(words) else None))
            j += 2 if takes else 1
        elif w.startswith("-") and len(w) > 1:
            last = w[-1]
            takes = last in short_valued and len(w) == 2
            value = words[j + 1] if takes and j + 1 < len(words) else (w[2:] if w[1] in short_valued and len(w) > 2 else None)
            options.append((w[:2], value))
            j += 2 if takes else 1
        else:
            positional.append(w)
            j += 1
    return options, positional


def remote_host(arg: str) -> str | None:
    """The host of a remote path (`user@host:path`, `host::module`, `scp://`/`rsync://` URLs), or
    None for a local path."""
    if "://" in arg:
        return urlsplit(arg).hostname
    head, colon, _ = arg.partition(":")
    if not colon or "/" in head or not head:
        return None
    return head.rsplit("@", 1)[-1] or None


def local_payload(ref: str, cwd: str, send_scan: Path) -> tuple[str, list[tuple[Path, str]]]:
    """What sending a local path carries: a file's text, or the path itself when it cannot be
    scanned (a folder, or a file whose text cannot be taken out). A path that does not exist
    carries nothing."""
    path = Path(os.path.expanduser(ref))
    path = path if path.is_absolute() else Path(cwd) / path
    if path.is_dir():
        return "", [(path, "a folder")]
    if not path.is_file():
        return "", []
    text, why = file_text(path, send_scan)
    return (text, []) if text is not None else ("", [(path, why)])


def stdin_payload(stdin, cwd: str, send_scan: Path) -> tuple[str, list[tuple[Path, str]], str | None]:
    """(text, unreadable, unknown) for a command's standard input."""
    if stdin is None:
        return "", [], None
    kind, source = stdin
    if kind == "unknown":
        return "", [], source
    if kind == "text":
        return source, [], None
    text, files = local_payload(source, cwd, send_scan)
    return text, files, None


def copy_sends(tool: str, words: list[str], cwd: str, send_scan: Path) -> list[Send]:
    """scp / rsync: local sources copied to a remote destination (the last path)."""
    options, paths = split_options(words, VALUED[tool], RSYNC_VALUED if tool == "rsync" else frozenset())
    if len(paths) < 2 or (host := remote_host(paths[-1])) is None:
        return []
    texts, unreadable = [], []
    for source in paths[:-1]:
        if remote_host(source) is None:
            text, files = local_payload(source, cwd, send_scan)
            texts.append(text)
            unreadable += files
    return [Send(f"host:{host}", "\n".join(texts), unreadable)]


def shell_sends(tool: str, words: list[str], stdin, cwd: str, send_scan: Path) -> list[Send]:
    """ssh host [command] / nc host port: the command's words and standard input."""
    options, positional = split_options(words, VALUED["ssh" if tool == "ssh" else "nc"])
    flags = {o for o, _ in options}
    if not positional or (tool != "ssh" and ("-l" in flags)):
        return []
    host = positional[0].rsplit("@", 1)[-1]
    text, unreadable, unknown = stdin_payload(stdin, cwd, send_scan)
    carried = positional[1:] if tool == "ssh" else []
    if tool != "ssh" and ({"-e", "-c"} & flags):
        unknown = unknown or "a program nc runs"
    if any(RUNTIME_TEXT.search(w) for w in carried):
        unknown = unknown or "a substitution or a variable"
    if not (carried or stdin):
        return []
    return [Send(f"host:{host}", "\n".join([*carried, text]), unreadable, unknown)]


def mail_sends(tool: str, words: list[str], stdin, cwd: str, send_scan: Path) -> list[Send]:
    """mail / mailx / sendmail: each recipient's domain; the subject, attachments and body."""
    options, positional = split_options(words, VALUED["mail"])
    recipients = [p for p in positional if "@" in p] + [v for o, v in options if o in ("-c", "-b") and v]
    text, unreadable, unknown = stdin_payload(stdin, cwd, send_scan)
    texts = [v for o, v in options if o == "-s" and v] + [text]
    for o, v in options:
        if o == "-a" and v:
            t, files = local_payload(v, cwd, send_scan)
            texts.append(t)
            unreadable += files
    if not recipients:
        return [Send("mail:?", "\n".join(texts), unreadable, unknown or "recipients read from the message")]
    domains = dict.fromkeys(r.rsplit("@", 1)[-1].strip(">,").lower() for r in recipients)
    return [Send(f"mail:{d}", "\n".join(texts), unreadable, unknown) for d in domains]


def http_sends(words: list[str], stdin, cwd: str, send_scan: Path) -> list[Send]:
    """HTTPie (`http` / `https` / `xh`): the request items after the URL, and standard input."""
    options, positional = split_options(words, VALUED["http"], HTTP_VALUED)
    if positional and positional[0].isupper():
        method, positional = positional[0], positional[1:]
    else:
        method = None
    if not positional:
        return []
    url, items = positional[0], positional[1:]
    host = "localhost" if url.startswith(":") else urlsplit(url if "://" in url else f"http://{url}").hostname or ""
    texts, unreadable = [], []
    for item in items:
        m = re.match(r"^([^=:@]*)(:=@|=@|@|:=|==|=|:)(.*)$", item)
        if m and m.group(2) in (":=@", "=@", "@"):
            t, files = local_payload(m.group(3), cwd, send_scan)
            texts.append(t)
            unreadable += files
        else:
            texts.append(item)
    text, files, unknown = stdin_payload(stdin, cwd, send_scan)
    unknown = unknown or ("a substitution or a variable" if any(RUNTIME_TEXT.search(i) for i in items) else None)
    if not (items or stdin or method in SENDING_METHODS) or not host or host in LOOPBACK:
        return []
    return [Send(f"host:{host}", "\n".join([*texts, text]), unreadable + files, unknown)]


def bucket_sends(tool: str, words: list[str], stdin, cwd: str, send_scan: Path) -> list[Send]:
    """aws s3 / gcloud storage / gsutil / rclone: local sources copied to a bucket or a remote."""
    verbs = {"cp", "mv", "sync", "rsync", "copy", "copyto", "move", "moveto", "rcat"}
    rest = words[1:]
    if tool == "aws":
        if rest[:1] != ["s3"]:
            return []
        rest = rest[1:]
    elif tool == "gcloud":
        if rest[:1] != ["storage"]:
            return []
        rest = rest[1:]
    if not rest or rest[0] not in verbs:
        return []
    verb, (_, paths) = rest[0], split_options(rest[1:], set())
    if not paths:
        return []
    target = paths[-1]
    scheme = re.match(r"^(s3|gs)://([^/]+)", target)
    if scheme:
        dest = f"{scheme.group(1)}:{scheme.group(2)}"
    elif tool == "rclone" and ":" in target and not target.startswith(("/", ".", "~")):
        dest = f"rclone:{target.split(':', 1)[0]}"
    else:
        return []   # a download to this machine
    if verb == "rcat":
        text, unreadable, unknown = stdin_payload(stdin, cwd, send_scan)
        return [Send(dest, text, unreadable, unknown)]
    texts, unreadable = [], []
    for source in paths[:-1]:
        if not re.match(r"^(s3|gs)://", source) and not (tool == "rclone" and remote_host(source)):
            t, files = local_payload(source, cwd, send_scan)
            texts.append(t)
            unreadable += files
    return [Send(dest, "\n".join(texts), unreadable)]


def socat_sends(words: list[str]) -> list[Send]:
    """socat relays whatever it reads to a network address: its payload cannot be named."""
    hosts = [m.group(2) for w in words[1:] if (m := SOCKET_ADDRESS.match(w))]
    return [Send(f"host:{h}", "", [], "socat relays whatever it reads") for h in hosts if h not in LOOPBACK]


INTERPRETERS = {"python", "python3", "node", "ruby", "perl", "deno", "bun", "php"}
SHELLS = {"bash", "sh", "zsh", "dash"}
CODE_FLAGS = {"-c", "-e", "--eval", "-E", "-r"}
URL = re.compile(r"(?i)\b(?:https?|wss?|ftp)://([A-Za-z0-9.-]+)")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n(.*?)\n\s*\2\s*(?:\n|$)", re.S)


def code_sends(command: str, cwd: str, send_scan: Path, depth: int = 0) -> list[Send]:
    """Code written into the command line: a shell's `-c` string is a command line of its own; an
    interpreter's `-c` / `-e` code, or a heredoc fed to one, sends to each host a URL in it names."""
    try:
        commands = simple_commands(command)
    except ValueError:
        return []
    bodies = [m.group(3) for m in HEREDOC.finditer(command)]
    out = []
    for words, stdin in commands:
        tool = os.path.basename(words[0])
        codes = [words[i + 1] for i, w in enumerate(words[:-1]) if w in CODE_FLAGS]
        if tool in SHELLS and depth < 3:
            for code in codes:
                out += sends("Bash", {"command": code}, cwd, send_scan, depth=depth + 1)
            continue
        if tool not in INTERPRETERS and not tool.startswith("python"):
            continue
        if stdin and stdin[0] == "text":
            codes.append(stdin[1])
        elif stdin and stdin[1] == "a heredoc":
            codes += bodies
        for code in codes:
            for host in dict.fromkeys(URL.findall(code)):
                if host not in LOOPBACK:
                    out.append(Send(f"host:{host}", code, []))
    return out


def other_sends(command: str, cwd: str, send_scan: Path) -> list[Send]:
    """The sends of network commands other than curl / wget. A command with no reader here is
    not seen (see the README: a script's own network calls are not seen)."""
    try:
        commands = simple_commands(command)
    except ValueError:
        return []
    out = []
    for words, stdin in commands:
        tool = os.path.basename(words[0])
        args = words[1:]
        if tool in ("scp", "rsync"):
            out += copy_sends(tool, args, cwd, send_scan)
        elif tool in ("ssh", "nc", "ncat", "netcat"):
            out += shell_sends("ssh" if tool == "ssh" else "nc", args, stdin, cwd, send_scan)
        elif tool in ("mail", "mailx", "sendmail"):
            out += mail_sends(tool, args, stdin, cwd, send_scan)
        elif tool in ("http", "https", "xh", "xhs"):
            out += http_sends(args, stdin, cwd, send_scan)
        elif tool in ("aws", "gcloud", "gsutil", "rclone"):
            out += bucket_sends(tool, words, stdin, cwd, send_scan)
        elif tool == "socat":
            out += socat_sends(words)
        elif tool == "sftp":
            hosts = [p.rsplit("@", 1)[-1].split(":", 1)[0] for p in split_options(args, VALUED["scp"])[1]]
            out += [Send(f"host:{h}", "", [], "sftp takes its commands as it runs") for h in hosts[:1]]
    return [s for s in out if s.dest.split(":", 1)[-1] not in LOOPBACK]


def sends(tool: str, args: dict, cwd: str, send_scan: Path, tabs: dict | None = None, depth: int = 0) -> list[Send]:
    """Every send the call makes."""
    if tool == "Bash":
        command = args.get("command", "")
        return (curl_sends(command, cwd, send_scan) + other_sends(command, cwd, send_scan)
                + code_sends(command, cwd, send_scan, depth))
    s = tool_send(tool, args, cwd, send_scan, tabs)
    return [s] if s is not None else []


def check(tool: str, args: dict, cwd: str, send_scan: Path,
          marks: frozenset[str] = frozenset(), area_of=lambda path: None, tabs: dict | None = None) -> str | None:
    """The one-line refusal for this call, or None when every send in it passes.

    A file whose text cannot be taken out (too large, or not text) cannot be scanned. It is
    refused when the session has read inside an area (`marks`) or the file itself sits inside
    one (`area_of`); a file a session that read nothing private sends from outside the areas —
    an image it made — passes. A send to an undeclared destination passes before any of this."""
    judged = send_scan_module(send_scan)
    for name, payload, unreadable, unknown, reading in sends(tool, args, cwd, send_scan, tabs):
        try:
            if judged.where(name) == judged.UNDECLARED:
                continue
        except judged.Broken as broken:
            return f"outgoing: not sent to {name}: {broken}; nothing is sent until it is fixed"
        if unknown:
            return (f"outgoing: not sent to {name}: its body is only known when the command runs ({unknown}), "
                    f"so it cannot be scanned. Write the body to a file and send that file instead")
        for path, why in unreadable:
            area = area_of(path)
            if marks or area:
                because = (f"this session has read inside {', '.join(sorted(marks))}" if marks
                           else f"the file sits inside {area}")
                return f"outgoing: not sent to {name}: {path} cannot be scanned ({why}), and {because}"
        import tempfile   # loaded only when a call sends: most hook calls never get here
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8",
                                         dir=os.environ.get("TMPDIR") or None) as fh:
            fh.write(payload)
            path = fh.name
        try:
            r = subprocess.run(["python3", str(send_scan), "--dest", name, "--text", path,
                                *(["--reading"] if reading else [])],
                               capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            return (f"outgoing: not sent to {name}: the send scan did not finish within 180s -- "
                    f"refused because it could not be judged in time, not because of what it found")
        except OSError:
            return f"outgoing: not sent to {name}: the send scan could not run"
        finally:
            os.unlink(path)
        if r.returncode != 0:
            why = (r.stderr.strip().splitlines() or ["the send scan refused it"])[-1]
            if name == tool and tab_ids(args):
                why += (". The guard does not know which page this tab shows: open it with a navigate call "
                        "in this session first, so the page's host names the destination")
            return "outgoing: " + why.removeprefix("send-scan: ")
    return None
