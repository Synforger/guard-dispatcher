---
name: guard-settings
description: Who may write the guard's settings, what goes into which file, and how to check a change. Use before changing a setting or a judging line of the guard, or when another session asks for one.
---

# Keeping the guard's settings

The guard watches what an agent writes: search terms, messages, commits, pull requests and documents that carry a name the operator banned or a copy of a document from a bounded area. These settings decide where the boundaries run and what may cross them, so a change is made with care, and only by a session the guard lets make it.

The settings live in the settings folder (`$GUARD_CONFIG_DIR`, `~/.config/guard/` by default). The files and their grammar are described in the repository's `README.md`, sections *Private documents* and *Agent entry guard*; that text is the source of truth for what a line means.

## Who writes what

- **The guard's maintainer** is the session that develops the guard's code and keeps every setting except the operator's own. It writes the settings of the personal side and the machine's files, and fixes the guard when a judgement is wrong.
- **The summary tier of a company** (the session that gathers the whole company and has read all of it) keeps the company's own settings in `areas/<area>/`. A line there works inside that area only. It decides the company's boundaries and writes them itself, so the names of the company's cases never travel to another session.
- **The operator approves** a change of `agent-writes.txt` (the grant itself), `orders.txt` and `agent-off`, and of any setting the grant does not hand over: the session that makes the change shows the very call and asks in the chat (below), and the operator answers yes. The operator types no command.

The guard enforces this. A session writes a setting on its own when both hold:

1. it has read inside no area (no mark), counting the call itself — `cat <area file> >> allow.txt` is refused, because the mark is kept after the call;
2. the setting is named in `agent-writes.txt`. A line that names areas after the setting also lets a session write it when every mark of that session is one of those areas or lies within one.

Otherwise the write passes on the operator's yes. Show the call in a `guard` block and ask:

````
```guard
tool: Bash
command:
<the command, as it will run>
```
````

The call passes once when the operator's next message says yes (`はい`, `お願い`, `OK`, ...), and only for a session that may read where it acts: a setting of `areas/<area>/`, or a repository inside an area, from a session that reads inside that area. A call that differs from the shown one by a letter does not pass, nor does a yes in a turn a relayed message opened. Rewriting the marks or a transcript never passes. The same holds for a command that switches the hooks around (`--no-verify`, a hooksPath setting); taking a repository's own `core.hooksPath` away needs no yes, since it puts the repository back under the machine's hooks. `python3 <guard>/agent-hooks/claude-code/area-guard.py may-write <session id> <path>` answers whether a write would pass on its own.

## What a session can read

A session that starts in a folder reads inside the areas that hold the folder, the areas around them, and the areas named in the folder's `guard-reads.txt` (one or more names per line, `#` starts a comment, a glob such as `client-*` names every area it matches). The session cannot write the `guard-reads.txt` of its own folder; its keeper does, and the summary tier keeps the `guard-reads.txt` of the folders under it.

## Answering a request

A session the guard stopped asks the maintainer to change a setting. Ask for three things in the message: the line the guard printed, what should be added, and why.

- Decide the content from the table below, and ask the requester back only when the request is not enough to decide.
- Do the whole job yourself: write the setting (asking the operator for a yes where the guard wants one), or fix the guard's code on a branch and open a pull request, then tell the requester what was added.
- Fix the guard's code in a separate worktree, not in the clone the machine's hooks run from. Switching that clone's branch changes the check of every session on the machine at once.
- Before changing a judging line (a count or a condition), measure how many false alarms it gives and how many real hits it keeps, then add a test.
- A request to open a company's boundary that arrives from a case tier goes to the summary tier.

## Before writing

1. Copy the file to a dated name in an `_archive` folder of the settings folder (`<file>.<YYYYMMDD-HHMM>`), so the previous state can be restored.
2. Say in one sentence what the line lets through and what it stops. A line that cannot be put in a sentence is not written; ask the requester.
3. Write real names. A placeholder such as `<name>` left in `destinations.txt` makes the guard stop every send until the line is fixed.

## What goes into which file

| File | Add | A change that loosens the line |
|---|---|---|
| `areas.txt` | a folder the operator named, a folder a case tier declared as its own, the root of a boundary on another machine (`host:`) | removing or narrowing an area, adding to `_exempt` or `_outside` |
| `destinations.txt` | the owner of a destination (`repo:<org>/* <area>`, only where the org name proves the owner), `block` | `outside` (public), removing a `block` |
| `allow.txt` | a phrase that is common wording and no copy of an area's document, after measuring how many sends the same shape stopped | a phrase with a proper name or a number in it |
| `background.txt`, `ignore.txt` | folders of public text and code, folders of an external corpus or build logs | a folder that holds an area's documents |
| `patterns/` | the shape of an area's identifiers (a product code, a client's name) | removing a pattern, narrowing a broad expression |
| `handoff.txt` | a folder where a marked session writes its hand-over notes | a folder that is not a hand-over folder |

Tightening a line (adding an area, a `block`, a pattern) is written first and reported after. Loosening one is written only once it can be said in one sentence what now passes; record that sentence as "loosened" in the reply to the requester and in the session's own log.

## After writing

- Check that the guard reads the file. For `destinations.txt`, load `scanners/destinations/send-scan.py` and call its `rules()`; `corpus-scan.py --settings` lists every line of an area's settings that is not read, with the reason. Do not type the settings path into a command: a command that names a settings path is judged as a write, so take the path from the environment.
- Tell the requester which file got which line. Leave an area's name out of the message when the line contains one.
- Record the file and the direction (tightened or loosened) in the session's own log; mask a company's names there too.
