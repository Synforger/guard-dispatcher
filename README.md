# guard-dispatcher

Machine-wide git hooks dispatcher for anonymous, AI-driven development.
One install arms every git repository on the machine with identity-leak
scanning at the commit, push, and PR boundaries — no per-repo setup, no
way to forget a repo.

## Why

Per-repo hooks fail open: a fresh clone, a new repo, or a forgotten
`core.hooksPath` silently runs no checks at all. guard-dispatcher moves
the enforcement point up to git's global `core.hooksPath`, so a missing
setup surfaces as a failed commit instead of a silent gap. This matters
most when AI agents drive the development loop: agents commit and push
far more often than humans, and a single unscanned path leaks an
identity permanently into public history.

## What it does

| boundary | hook | check |
|---|---|---|
| commit (content) | `pre-commit` | staged files scanned against your word list |
| commit (identity) | `pre-commit` | `user.email` must be one of the allowed identities |
| commit (message) | `commit-msg` | commit subject/body scanned |
| push | `pre-push` | outgoing commit range deep-scanned (blobs, messages, authors); every author/committer must be an allowed identity, or a GitHub bot account |
| push (refs) | `pre-push` | branch/tag names scanned; direct pushes to main/develop refused (initial branch-creating push exempt; `GUARD_ALLOW_PROTECTED_PUSH=1` overrides once) |
| PR | `scripts/pr-create.sh` | PR title/body scanned before `gh pr create` |
| any `gh` send | `gh-shim/gh-guard.sh` (PATH shim) | argument vector, body/notes/template files and stdin payloads scanned before the CLI runs; read-only subcommands pass through |
| AI agent tool call | `agent-hooks/claude-code/area-guard.py` (Claude Code PreToolUse hook) | a session that read inside a private area cannot write a repository outside it, nor commit, push or send through `gh` there; no session can switch the guards off or around |
| AI agent send (tool, network) | `agent-hooks/claude-code/outgoing.py` (called by the same hook) finds the send, `scanners/send-scan.py` judges it | what a tool sends to a service (MCP tools, Artifact) or a `curl` / `wget` sends with a body is scanned like a push, against the areas its declared destination is outside of; a destination can be blocked for sending outright |
| AI agent message to another session | `agent-hooks/claude-code/peers.py` (called by the same hook, and by a client that relays messages) | a message is judged by where the receiving session has read: text of an area it has not read inside is refused, words of the sender's own pass, in every direction |
| repair | `scanners/anon-fix.sh` | rewrites unpushed history in place (`git filter-repo`) so neither the leak nor the repair scar is published |
| health | `scripts/doctor.sh` | reports unarmed repos, hooksPath overrides, word-list drift |

Content scanning is **default-on for every repository** — the only way
out is an explicit `exempt` opt-out. Identity and branch-flow
enforcement are additionally applied to repositories selected by
`origin` URL (see *Scope* below).

## Install

```sh
git clone https://github.com/Synforger/guard-dispatcher.git
cd guard-dispatcher
bash scripts/bootstrap-machine.sh
```

`bootstrap-machine.sh` symlinks the hooks (and the `scanners/`,
`scripts/` and `agent-hooks/` directories, for stable paths) into
`~/.git-hooks/`, points git's global `core.hooksPath` there, installs the
`gh` shim, verifies your word list and external tools, and finishes with a
doctor pass. It is idempotent.

The guards run from the clone in place, so keep it on the branch you want to
run and do work in progress elsewhere (a `git worktree`).

To hold Claude Code to the same areas, name each of its settings files
(one per config dir):

```sh
bash scripts/bootstrap-machine.sh --claude-settings ~/.claude/settings.json
```

The hook is registered through `$HOME/.git-hooks/agent-hooks/claude-code/area-guard.py`,
so it keeps working whatever was installed last. Re-running leaves one
entry. If that file is missing the entry passes silently rather than refusing
every tool call, and `doctor.sh` reports it missing.

### Word list

Scanners read one PCRE fragment per line from the first of:

1. `$ANON_WORDS_FILE` (explicit override)
2. `git config guard.wordlist` (scope-specific list — see *Local scope opt-in* below)
3. `$HOME/.config/anon-words/master.txt` (recommended location)
4. a repo-local `.tooling/local-ci/anon-words.txt` (legacy)

The word list is private operator data — it is never committed
anywhere. See `scanners/anon-words.example.txt` for the format.

Fragments are matched case-insensitively, so a name is caught however it is
capitalised. Prefix a line `cs:` when the capitalisation *is* the meaning and
folding it would fire on unrelated text: the macOS home-root prefix, for one,
is a path carrying a username when capitalised and a common URL segment when
lowercased, so it belongs on a `cs:` line.

Each line is matched as a group of its own: a flag written inside a line
(`(?-i)`, for one) ends with that line and never reaches the lines below it.

## Scope

Every hook follows the same AND-composition:

1. If the repository ships its own `.githooks/<hook>`, run it first. A
   failing repo hook fails the operation — but a passing one does not
   skip the baseline. Repo hooks add rules; they never replace the
   guard.
2. **Content scans run on every repository by default** — staged files,
   commit messages, outgoing push ranges, ref names. An arbitrary remote
   is not an excuse: a personal identifier leaking is a fail-safe concern
   regardless of where the repo points.
3. **Identity and branch-flow enforcement** (committer allow-list,
   protected-branch refusal) applies only where a specific identity is
   required:
   - repositories in the enforced organisation (edit
     `dispatcher::detect_repo_kind` in
     `git-hooks/lib/dispatcher-common.sh` to set yours),
   - repositories with no remote (fail-safe),
   - repositories opted in locally via `git config guard.scope enforced`.

   Third-party repositories keep their own committer identity and flow —
   they are content-scanned, never identity-rewritten.
4. The only hard opt-out is explicit: `git config guard.scope exempt`
   per clone, or a blanket
   `git config --global guard.exemptPrefix ~/some/private/tree` for
   every repo under a private state directory — useful when that
   directory's contents include the very words the master list flags,
   which makes the baseline structurally impossible.
5. Such a directory can still keep what it must not carry out of an area:
   `git config guard.scope corpus` skips the word and identity scans but
   runs the private-document scan — on the lines a commit adds, against the
   areas the repository sits outside of (a client's text staged into the
   company's notes), and on what a push sends, against its destination.

### Local scope opt-in (no repo changes)

Blanket-enforce every repository under a directory — with its own word
list and identities — using git's conditional include. Nothing is
written into any repository:

```ini
# ~/.gitconfig
[includeIf "gitdir:~/path/to/corp-org/"]
    path = ~/.gitconfig-corp

# ~/.gitconfig-corp
[guard]
    scope = enforced
    wordlist = $HOME/.config/anon-words/corp.txt
    allowedEmails = you@users.noreply.github.com,noreply@github.com
```

`guard.wordlist` feeds the scanners a scope-specific list (resolution
order is single-sourced in *Word list* above).
`guard.allowedEmails` (comma-separated) replaces the built-in identity
list for that scope. Existing repo-local `.githooks/` keep running
first (AND-composition), so per-repo rules still apply on top.

The push-time identity check additionally accepts GitHub bot accounts
(`<id>+<name>[bot]@users.noreply.github.com`) wherever they appear in the
outgoing range. A merged dependabot pull request puts one into the history,
and promoting that history to another branch would otherwise fail a check
with nothing left to protect — the commits are already public, and the
address belongs to GitHub rather than to a person or an organisation. This
exemption is push-only: `pre-commit` still requires `user.email` to be on the
allowed list, because the operator is never a bot.

Scanners resolve repo-local first (`.tooling/local-ci/`), then fall
back to this checkout's `scanners/` — so individual repositories need
no toolkit of their own, but can override it.

### Private documents

A word list only holds what someone thought to write down. Text copied out of a
real document — a sentence from a slide, a row of a table — is on no list.
`scanners/corpus-scan.py` compares what a push (or a `gh` call) sends with the
documents themselves. Everything it reads is configured on this machine only:

```
~/.config/guard/areas.txt               <name> <path> [<path> ...]   one area per line
                                        <prefix>* <path>/* ...       one area per sub-folder
                                        <name> <path>/* ...          every sub-folder joins <name>
                                        _outside <path> ...          in no area
                                        _exempt <path> ...           never scanned
~/.config/guard/patterns/<name>.txt     regular expressions for identifiers of a shape
                                        (product codes, client names), case-insensitive
~/.config/guard/allow.txt               phrases that are fine to send
~/.config/guard/ignore.txt              folders inside an area that hold none of its
                                        documents (an external corpus, build logs)
~/.config/guard/background.txt          folders of public text and code, and `published <dir>`
                                        for your own repositories as their remote has them
```

`client-* /srv/company/clients/*` makes every sub-folder of `clients/` its own area
(`client-acme`, `client-beta`, ...), so a client folder created tomorrow is
guarded from the moment it exists. A folder already named on an explicit line
keeps that name.

On a machine that is the company's, `company ~/*` puts every folder of the home
directory in the company, one made tomorrow included (hidden folders, which hold
tools and their settings, stay out). `_outside ~/personal ~/Library` names the
folders that belong to no area: a personal folder, or one that holds only
applications. Nothing read there marks a session and nothing there is a document.
An `_outside` folder inside an area is cut out of it too.

A place's own areas are the innermost ones holding it. An area around them — the
company around one of its clients — is still one a send there is checked against:
what goes to a client does not take the company's own text. Text the company's
templates also hold (the kit a client repository starts from, the deck template)
is no area's: list the template folders in `background.txt`.

An area's documents are everything under it that holds its words:

| kind | files | a sent line is a hit when it |
|---|---|---|
| prose | Office (`.pptx` `.docx` `.xlsx`, read from their XML, never their compressed bytes), PDF (`pdftotext`, wrapped lines rejoined), Markdown | holds a run of 12 characters of Japanese, or 40 without (twelve characters of English are two common words) |
| rows | CSV, TSV, plain text | is, once whitespace is folded, a whole row of the same length bar |
| lines | every other file a git repository inside the area tracks — its code and its Markdown | is one of `GUARD_CORPUS_CODE_LINES` (default 2) consecutive sent lines that are each a whole line of the same length bar |

Code is matched line by line because that is how it is copied, and because
printing every run of every line of a code base would hold hundreds of
millions of values. It takes two consecutive lines because a lone common line
(an import, an idiom) is written by the same people in every code base: on
1,298 clean public commits one line blocked 14, two lines blocked 3. A row of
data is specific on its own, so one copied row is a hit. Inside a repository only what it tracks counts: untracked
output and vendored folders (`third_party/`, `vendor/`, ...) are someone
else's. Runs and lines that also appear in the background text and code are
not specific to any area and are dropped.

The table of that public text keeps for a week. Past its week a scan uses the
old table as it is, and a process of its own rebuilds it: a commit does not
wait for text that almost never changes, and until the rebuild is done the
only cost is that text made public since may still be flagged. A rebuild reads
only what changed — a file whose size or modification time moved, a published
file whose content did — and one process rebuilds at a time. An edit of
`background.txt` is read within the next scan. A line of code or a run of
prose already in an area's table leaves it when that table is next merged in
full, so after listing a new folder `corpus-scan.py --refresh` applies it at
once. Every scan ends by saying how long it took.

Prints are kept per document and reused while a document is unchanged.
Documents changed since the last scan are found through Spotlight and added at
once. When Spotlight cannot answer (indexing off, an area it does not index, or
a process that can list the area's folder but not search it) the size and modification
time each document's print was built from are compared with what `stat` gives
now instead, and only the folders whose modification time moved are listed
again (creating, removing or renaming a file changes its folder's time) — an
edited, deleted or created document is caught at once without walking
everything, and a full walk still comes at least every six hours. Only one process at a
time walks or writes the fingerprints; the rest use what is already on disk
rather than wait or walk beside it, and every file is written whole (a
temporary file, then renamed into place) so a reader never opens a half-written
one. A document that could not be read is listed by `--status`, with why —
timed out, its extractor is not installed, or its exit code — and `--summary`
/ `doctor.sh` show the same grouped by why, without naming any of them.

**Where the text is going decides what it may carry**: every area but the
destination's own is checked, and its own areas are the innermost ones holding
it. Areas nest — a client inside a company — so a client's repository carries
the client's text and not the company's, a company repository carries the
company's and not the client's, and a repository outside both carries neither.

The destination is the GitHub repository being sent to — the push URL, or for
`gh` the `-R` / `GH_REPO` / `api repos/<owner>/<repo>` target, falling back to
the current folder's remote — never the folder the command was typed in:

| destination | treated as |
|---|---|
| public on GitHub | outside every area, wherever its clone lives |
| private, cloned on this machine | where that clone lives |
| private with no local clone, visibility unknown, or not determinable (a gist, `gh repo create`) | outside every area (fail-closed) |
| not on GitHub (a local path, another host) | where the sending repository lives |

Visibility is asked without credentials first (only a public repository
answers), then as each account `gh` holds, and remembered for ten minutes.

`corpus-scan.py --refresh` walks everything now and says only how many
documents could not be read; `--status` shows what is loaded and names what
could not be read; `--summary` (what `doctor.sh` runs) shows the same in
counts. A machine with no `areas.txt` prints `NOT CHECKED` and passes.

Every line printed without being asked — a clean scan, a rebuild, `--summary`,
`doctor.sh` and so bootstrap — counts areas and documents and names none: it
lands in whatever reads the output — an agent's conversation, a CI log — and
an area's name or a document's path says what the area holds. A refusal names
the area, for the operator to act on; `--status`, typed by the operator, names
everything.

### Agent entry guard

The push-time scan catches copies. An AI agent can carry what it read without
copying a single line, so `agent-hooks/claude-code/area-guard.py` stops it one
step earlier, before each tool call, from the same `areas.txt`:

- A session that reads inside an area (a `Read` / `Grep` / `Glob` target, an
  area path a `Bash` command names, a `Bash` working directory) is marked
  with the name of the area the path is in. A command names a path where the
  path **stands by itself**:
  - a word of the command line or the file of a redirection (`cat <path>`,
    `--file=<path>`, `A=<path>`, `host:<path>`, `-d @<path>`, a glob that
    matches it), and the same inside a command substitution, a shell's `-c`
    string, `eval`, or a heredoc fed to a shell;
  - a string of code written into the command (`python3 -c`, `node -e`, a
    heredoc or a here-string fed to an interpreter): `open("<path>")`,
    `["cat", "<path>"]`, a line of a string that runs over lines;
  - a line of a heredoc or here-string fed to anything else, which may list
    files (`xargs cat`, `while read f`).

  A path inside a sentence is text, and names nothing: a commit message, a
  line of a note being written, a replacement string (`"the format is kept in
  <path> now"`). Nothing opens it, so writing about an area is not reading it.
  A command line written as one string inside other code
  (`os.system("cat <path>")`) is a sentence too and is not read; neither is a
  script run from a file.

  A command that only checks the paths it names marks nothing either: `test`,
  `[ … ]`, `stat`, `realpath`, `readlink` or `ls -d` run on its own, every
  argument literal (no second command, pipe, redirect, substitution, glob or
  variable other than `$HOME`). Anything else is taken to read what it names.
  Marks are kept per session under `~/.cache/area-guard/`, so they outlive the
  agent compacting its context.
- A marked session may write a file inside a git repository, commit there,
  push or send through `gh`, when the place is one it may carry its marks to:
  - **a place in no area passes** — the guard stops what it knows leaves an
    area, not what is unlisted — unless the repository publishes outside every
    area: a public repository, or one `destinations.txt` declares outside
    (`repo:my-account/* outside`: a personal account, private or not, since
    its owner may publish it tomorrow);
  - a place in areas passes when it is inside every mark and in no other area
    but one around a mark. A session that read the client writes the client's
    repository (the company around it does not count against it) but not the
    company's; one that read only the company writes neither a client's
    repository nor a personal one.
  The shell's writes are the paths a command names as written (a `>` / `>>`
  redirection, `tee`, `touch`, `truncate`, the destination of `cp` / `mv` /
  `install` / `ln`, `sed -i`, `dd of=`), whatever stands before the command
  (`sudo`, `env`, a variable). A shell's `-c` string, and a heredoc fed to a
  shell, is read as a command line of its own. Every path that other code
  written into the command names counts (`python3 -c`, `node -e`, a heredoc or
  a here-string fed to an interpreter), since code that reads a file cannot be
  told apart from code that writes it: an absolute or home path that stands by
  itself, as above, and a whole string that reads as a relative path (one word
  that holds a `/`, ends in an extension, or names something in the command's
  folder). A word quoted inside a longer string (`` "see `notes.md`" ``) is
  that string's text. A heredoc fed to anything else is text, not commands. A script run from a file
  is not read, so what it writes is not judged. Destinations are judged
  exactly as the push-time scan judges them (`corpus-scan.py --where`). Files
  outside any repository and `_exempt` areas stay writable, and an `_exempt`
  repository commits and pushes wherever it sends: its git hooks judge what
  it carries (give it `guard.scope corpus` so they do).
- On every machine, areas or not, a `Bash` command that switches the guards off
  or around is refused: `--no-verify`, `git commit -n`, the skip variables,
  `git -c core.hooksPath=…`, setting `core.hooksPath` / `guard.scope` /
  `guard.exemptPrefix`, clearing the marks, creating the off switch, removing
  the installed hooks, or sending from a repository the git hooks do not reach. The operator types
  those; the agent does not.
- On every machine too, the agent writes neither `destinations.txt` nor
  `orders.txt` in `$GUARD_CONFIG_DIR`, nor removes them (or the folder holding
  them), nor writes a session's transcript (`~/.claude*/projects/**/*.jsonl`,
  and the one the call itself names), through `Edit` / `Write` or the shell:
  an order for a send is judged from these (see *A send the operator orders*
  below), so an agent that could write them would make an order itself.
  Reading them, and copying them elsewhere, passes.
- **The operator's switch** is one file: while `$GUARD_CONFIG_DIR/agent-off`
  exists, the entry guard passes every call. Installing or updating the guard
  leaves it alone, so a guard switched off stays off until the file is
  removed; `doctor.sh` reports it.
  A commit in a repository with no remote is the one send let through there:
  it stays in the repository and has nowhere to go. Its push is still refused.
- **A script asks before it writes where its arguments say.** The guard reads
  the command that starts a script, never the script, and a relative path
  handed to a script resolves where the script runs, not where the session
  stands — so a script that writes into a folder it is given can write where
  the session itself would be refused. Such a script asks first:

  ```bash
  python3 "$HOME/.git-hooks/agent-hooks/claude-code/area-guard.py" \
      may-write "$CLAUDE_CODE_SESSION_ID" "$destination" || exit 1
  ```

  It exits 0 when the session may write every path named (the judgement an
  `Edit` of the path gets; also with the switch off, with no areas, and for a
  session with no marks), and 1 with one line per refused path on stderr. A
  relative path resolves from the caller's working directory. It only
  answers: it adds no mark and changes nothing.

The hook is registered for every tool (`matcher: "*"`): a send can go through any tool, and a call the
guard is not asked about is one it cannot judge. A call that passes prints nothing, so nothing is added to the agent's context.
A refusal is one line naming the area and the destination. `doctor.sh` reports
whether the hook is installed and, per Claude Code config dir, registered; an
unregistered config dir is a finding on a machine that defines areas.

#### What an agent sends out

git and `gh` are not the only ways out: a tool can upload to a service (an MCP
tool, the Artifact tools) and a command can post over the network. The same
hook finds those sends (`agent-hooks/claude-code/outgoing.py`, which reads
Claude Code's calls) and has each judged the way a push is judged, whatever the
session read (`scanners/send-scan.py`, which any other entry point can call:
`send-scan.py --dest NAME --text FILE`, or `--where NAME`):

- **What is scanned**: every string of the tool call and the contents of the
  local files it uploads (Claude Code's WebFetch and WebSearch included: the
  URL, the prompt and the query reach the service); for `curl` / `wget`, the body and the files it sends
  (`-d`, `--data*`, `--json`, `-F`, `-T`, `--post-*`, or `-X POST|PUT|PATCH`),
  including what they read from standard input (`@-`, `-T -`) when it comes
  from `< file` or a here-string. A body only known when the command runs —
  a `$(…)` or backtick substitution, a variable, or standard input from a
  pipe or a heredoc — cannot be scanned and is refused when it goes to a
  declared destination; write it to a file and send the file instead.
  Other network commands are read the same way: `scp` / `rsync` (the local
  files copied to a remote host; a folder counts as a file that cannot be
  scanned), `ssh` / `nc` (the remote command and standard input), `mail` /
  `mailx` / `sendmail` (subject, body and attachments, named `mail:<domain>`),
  HTTPie (`http` / `https` / `xh`: request items and uploaded files),
  `websocat` / `wscat` (standard input and the message given to send),
  `aws s3` / `gcloud storage` / `gsutil` / `rclone` (local sources copied to
  `s3:<bucket>`, `gs:<bucket>` or `rclone:<remote>`). `socat` and `sftp` to
  another host are refused, since what they send is only known as they run.
  Code written into the command — `python -c`, `node -e`, a heredoc fed to an
  interpreter — sends to each host a URL in it names, carrying the code; a
  shell's `-c` string is read as a command line of its own. A script in a file
  and a command not listed here are not read.
  The text of an Office document or a PDF is taken out of it first. A file
  whose text cannot be taken out (over 8 MB, or not text, like an image)
  cannot be scanned: it is refused once the session has read inside an area,
  or when the file itself sits inside one, and passes otherwise.
  A reading call (a tool whose name says it reads: get, list, search, read,
  fetch, query, view, find, export, ...) still hands the service its own
  strings, such as a search term, so those are scanned; the files it names are
  not uploaded and not read, and a service blocked for sending still takes
  reads, judged as outside every area. A fetch without a body is a reading
  call whose payload is its URL, decoded (a query string reaches the host).
  A local path among a call's arguments — a file to upload, a folder to save
  into — is not scanned as text: the service receives the file, not its name.
  An argument whose name says id (`id`, `file_id`, `fileId`, `ids`) names an
  object the service already holds, such as the file to read or the page to
  write to. When its value is one word of ASCII it is not compared with the
  private documents: a file id that one of them links to can be used to open
  that file. It is still read against the word list, and the same id as a
  search term, or the whole link under another argument, is text like any
  other.
  Anything sent to the loopback host is not a send, unless a line names it
  (see *What stays on this machine* below).
- **Against what**: the private-document scan compares the payload with the
  areas its destination sits outside of, exactly as for a push; a destination
  outside every area also gets the word-list scan, as a public repository does,
  and one inside an area gets that area's own word list when the machine keeps
  one beside the master (`company.txt` next to `master.txt`: the company takes
  real names but not the operator's handles).
- **Where a destination sits** is declared per machine in
  `$GUARD_CONFIG_DIR/destinations.txt`, first match winning:

  ```
  # pattern                 area | outside | block   [order]
  mcp__*drive*              company     # company text may go there, a client's may not
  host:*.corp.example.com   company
  browser:*.corp.example.com company    # a browser tool typing into a page there
  *slack*                   block       # sending refused outright; reading still works
  *chat*                    company order   # each send needs the operator's order
  repo:my-account/*         outside     # a push or gh call to these GitHub repositories, private or not
  ```

  The pattern is a glob over the tool name, over `host:<name>` for a
  network command, over `repo:<owner>/<name>` for a GitHub repository a push
  or a `gh` call sends to, or over `browser:<host>` for a browser tool (an MCP call
  naming a `tabId`) whose tab this session opened at a page there; a tab it did
  not open stays named by the tool, and one opened at a page keeps that host
  after a click takes it elsewhere. A line naming an unknown area stops every
  send until it is fixed, and so does a third word other than `order`,
  `block order`, or `order` on a `repo:` line (a push is not held to one).

  **A destination no line names is undeclared and passes, unscanned**: the
  guard stops what it knows leaves an area, and a build machine or an internal
  service is not stopped for being unlisted. What publishes to the internet or
  to a personal account is outside every area with no line — the Artifact
  tools, WebFetch, WebSearch and claude.ai's connectors (`mcp__claude_ai_*`);
  a line in the file overrides that. To hold every other destination to the
  scan, end the file with `* outside`.

#### A message to another session

One agent session can write to another: Claude Code's `SendMessage`, or a
client that carries messages between the sessions it runs. The receiver may be
able to write where the sender is not, so a message is a send, and the
receiving session is its destination. No line declares where that destination
sits: **it sits where it has read**, the marks the entry guard already keeps
for it (`agent-hooks/claude-code/peers.py`).

| the receiving session has read inside | what a message to it may carry |
|---|---|
| no area | no area's text |
| the company | the company's text, not a client's |
| a client (with or without the company around it) | that client's text, not the company's |
| several areas | the text of each |

Words of the sender's own pass in every direction, whatever the sender has
read: the scan is the private-document scan a push gets, and nothing else.
No word list applies, since only the operator's agents read the message; what
one of them sends on is judged where it leaves. So one rule covers every pair
of sessions, and a session that found a fault in a shared tool while working
inside a client can tell the session that owns the tool, in its own words.

- `SendMessage` names its receiver by the session's name: every running
  session of that name on this machine, under any of the operator's accounts
  (`~/.claude*/sessions/`), must take the message. A name no running session
  carries is taken to be a session elsewhere — another machine, the cloud —
  and judged as one that has read nothing. `main` and one of the session's own
  subagents (named by its agent id) are inside the session: nothing leaves it.
- A client that relays messages runs the same judgement before it delivers,
  naming the receiver by its session id, so every way into the client is
  judged at one place:

  ```sh
  python3 ~/.git-hooks/agent-hooks/claude-code/peers.py --to <session id | name> --text <file>
  # exit 0 passes, 1 refuses (one line why on stderr), 2 cannot judge
  ```

What the operator typed in a session is judged apart from what an agent wrote
there. An agent's message is scanned, and a paraphrase carries nothing of the
documents; the operator's own words are not written with that care, and no
scan knows what they say. They are taken to carry every area the session they
were typed in has read inside, so a client that passes them on to another
session asks with `--typed-in`:

```sh
python3 ~/.git-hooks/agent-hooks/claude-code/peers.py --to <receiver> --text <file> --typed-in <the session they were typed in>
# passes only to a session that has read inside each of those areas; scanned like any message besides
```

#### What stays on this machine

A service on the loopback host and a tmux session are not ways out of the
machine, so they pass, and a catch-all line (`* outside`) does not reach
them. Some of them the operator still wants closed to agents: a client's
endpoint that types into a session's terminal **as the operator would**, or
tmux typing into that terminal directly, would let an agent write the
operator's words. Those are named, and a line that names the kind reaches
them:

```
# pattern                       area | outside | block
local:8766/pty/*                block      # the client's own way of typing into a session
local:8766/ws/pty/*             block      # the socket its terminal view types through
tmux:agents-*                   block      # typing into the sessions the client runs
```

A client often has more than one endpoint that types (a send call, a terminal
socket), and a pattern is matched from the start of the name: the line for one
does not reach another under a different path. Give each its own line; the
client's documentation should list them.

- `local:<port><path>` is a `curl` / `wget` / HTTPie call, a WebSocket
  client's (`websocat` / `wscat`), or code written into the command (an
  `http://` or `ws://` address in it), bound for the loopback host. A script
  file's own calls are not seen.
- `tmux:<session>` is `tmux send-keys` / `send-prefix` / `paste-buffer` /
  `pipe-pane`. The session is the one tmux itself resolves the target to (a
  pane id, a prefix, the pane the command runs in); a target tmux cannot
  resolve is named as spelled, and a typing command wrapped in another
  (`run-shell`, `if-shell`) is `tmux:?`, which `tmux:*` reaches, or
  `tmux:[?]` alone (a bare `?` in a pattern is any one character).

#### A send the operator orders

Some destinations reach other people the moment a call runs: a chat message,
a mail. A scan says what the text may carry, not whether the operator meant
it to go. A destination declared with `order` takes a send only in this
exchange (`agent-hooks/claude-code/order.py`):

1. The agent shows the call in a fenced block, as it would make it:

   ````
   ```send
   tool: chat_send_message
   channel_id: C0123ABCD   the team channel
   message:
   The build is green.
   ```
   ````

   A key with a value on its line takes the first word (the rest is a label
   for the reader); a key with nothing after the colon takes every line after
   it, so it comes last. `tool` is the tool's name, in full or its last part.
   A text holding a ``` line of its own goes in a longer fence.
2. The operator's next message orders the send.
3. The guard reads both from the transcript Claude Code keeps for the session
   and lets the call through only when its input is the shown one, key for
   key and letter for letter (a false or empty value counts as absent). One
   shown block is one send: a second call on the same block is refused, and a
   call that was refused or failed gives the block back.

What orders is the operator's own list, `$GUARD_CONFIG_DIR/orders.txt`: one
phrase per line, and a line starting with `!` is a cancelling tail, the words
right after a phrase that turn it into something else (asking leave, a
negation, the past):

```
send it
! later     # "send it later" puts it off
! if        # "send it if they agree" is not yet an order
```

A phrase counts when it stands outside quotes (`「…」`, `『…』`, pasted text),
in a sentence that holds no question mark and does not go on with a tail.
With no `orders.txt`, nothing is ever ordered. Only a message the operator
typed counts, whether it opens a turn or is typed while the agent works; a
tool's result, a task's notice, a hook's text and a subagent's conversation
never do, and a block the operator pasted is not one the agent showed.

A client that carries messages between sessions types them into the
receiver's terminal, where they are recorded as typed text. Such a client
opens each message with a fixed line; give that line to `orders.txt` after a
`>`, and a message that opens with it is never the operator's: it orders
nothing, it takes no order back, and a turn it opened takes no order. A
client delivers by pasting, and Claude Code records a multi-line paste inside
its pasted-text tag; the opening is looked for inside that tag too.

```
> Message from another session, relayed by the client:
```

This holds as long as agents cannot reach the client's own way of typing as
the operator: block it (see *What stays on this machine*).

#### A message from another machine

A client may also carry messages between machines. Whoever sits at the other
machine can have such a message written, so it is held to more than a message
from a session here: it **holds the session it came into** until the operator
has seen it. Have the client open those messages with a line of their own, and
give that line to `orders.txt` after `>>`:

```
>> Message from a session on another machine, relayed by the client:
```

- From the moment such a message comes in until the operator types a message
  of their own, the session's tool calls are refused, all but the ones that
  only read (`Read` / `Grep` / `Glob`) and a question to the operator. The
  refusal tells the agent to say what the message asks and wait.
- The operator's next message lifts the hold, whatever it says: typed to open
  a turn, or while the agent works. The agent then goes by that message.
- A message relayed from a session on this machine does not lift it, and
  neither does a tool's result, a hook's text or a task's notice: only typing
  does. Going back from the end of the conversation, the guard looks for a
  message from another machine before any message the operator typed.
- A `>>` line is a `>` line too: the message orders nothing and takes no
  order.
- This is on every machine, with or without areas, and is read from the
  session's transcript (`transcript_path`). With no `>>` line nothing is held
  and the transcript is not read for it.

As with `>`, this holds while agents cannot type as the operator or reach the
other machine's client themselves: block the client's typing endpoint, and
declare the other machine's host (`host:<name>   block`).

A reading call and a tool that drafts (its name says `draft`) need no order.
A command (`curl` and the like) never sends to such a destination: it cannot
be matched against a shown call. What an ordered send carries is scanned like
any other, so an order does not carry a client's text to the company's chat.

Claude Code writes the transcript behind the conversation. The guard checks
that the transcript holds the message the call belongs to (the call's
`prompt_id`) and refuses until it does; the same call passes on a later try.
What an order has let through is kept beside the session's marks
(`~/.cache/area-guard/<session>.orders/`), since the transcript does not hold
a call until it has run.

## Scan guarantee

The contract a machine-wide install provides, stated precisely — both
directions.

### Guaranteed

On a machine where `doctor.sh` reports no gaps, for every repository
except an explicit `exempt`. Each behavioural guarantee names the test
file that pins it — the bats suite is the executable form of this
contract:

- **No commit is created** whose staged file contents or commit message
  match the word list (`pre-commit`, `commit-msg`). The scan reads the
  staged blobs, not the working tree — cleaning a file after staging it
  does not unblock the leak. Pinned in `tests/hooks.bats`.
- **No push publishes** matching content: every outgoing commit is
  deep-scanned — all blobs (full diffs), the message, and the
  author/committer name+email — and the pushed branch or tag name is
  scanned as well (`pre-push`). A new-branch push scans exactly the
  commits the remote does not already have; force-pushed rewritten
  history falls back to a full scan of the new history. Pinned in
  `tests/hooks.bats`.
  The scan runs while git holds the connection to the remote open, so a
  push that sends a whole history (a new or recreated repository) can
  outlast an idle SSH connection: set `ServerAliveInterval 30` for the host
  in `~/.ssh/config`.
- **A word list that does not compile refuses to scan** (exit 2,
  configuration error) — a broken fragment can never silently disarm a
  boundary. Pinned in `tests/scanners.bats`.
- On identity-enforced repositories (enforced org / no-remote /
  `guard.scope enforced`), additionally: the committer and every author
  in the outgoing range must be on the identity allow-list, and direct
  pushes to protected branches of a pull-request host (GitHub, including
  ssh host aliases) are refused. A remote without pull requests — a plain
  ssh host holding a rail's history — has no review flow to bypass, so a
  direct push there is allowed. Pinned in `tests/hooks.bats`.
- PRs opened through `scripts/pr-create.sh` have their title and body
  scanned before `gh pr create` runs.
- **Nothing the `gh` CLI sends leaves unscanned** while the PATH shim is
  installed: the argument vector, any file passed as a body, notes,
  template or request payload, and a payload piped in on stdin are all
  scanned first. Read-only subcommands (`view`, `list`, `status`, a plain
  `GET` through `api`, …) pass through untouched, because those
  legitimately name accounts and repositories. An unrecognised subcommand
  is scanned rather than assumed harmless, and an unresolvable scanner
  refuses the command. Pinned in `tests/gh-guard.bats`.
- **A Claude Code session with the agent entry guard registered** does not
  write a repository outside the areas it read, and does not commit, push or
  send through `gh` outside them; with or without areas, it does not run a
  command that switches the guards off or around. Pinned in
  `tests/area-guard.bats`; installing and registering it in
  `tests/install.bats`.
- After the fact, `anon-audit-deep` sweeps 11 sources — tracked files,
  every history blob, commit messages, branch names, tag names +
  annotations, author/committer fields, GitHub PR + Issue title/body +
  comment threads, repo description/topics/homepage, releases, and
  Actions run titles.
  The weekly audit runs it scoped to the week's activity.
  Findings that will not be rewritten (history, PR text) can be accepted as
  known: `scripts/weekly-audit.sh --accept <repo>...` records each
  repository as it stands in `~/.config/guard-dispatcher/known/<repo>.known`
  (the ref tips, the time, and the matching lines of branch names, tags,
  metadata and releases). From then on only what appears later is red — a new
  commit carrying a known word included — and the files in the tree are
  always scanned whole (`anon-audit-deep.sh --known FILE` / `--record-known FILE`).
- **A GitHub source that cannot be fetched is reported as a finding, never
  as clean.** The audit settles reachability once before scanning and falls
  back to the keyring credential when an environment token cannot see the
  organisation; if no credential resolves the repository, every GitHub-side
  source counts against the run. Silence is not proof — an erroring API call
  used to collapse into empty output, which a scan reports as clean, leaving
  a whole organisation green forever. Pinned in `tests/scanners.bats`.

### Not covered — know your gaps

- The hold a message from another machine puts on a session is read from the
  session's transcript, and only a tool call is refused: the agent still
  reads the message and still answers in words. A script the agent started
  before the message came in keeps running. A message is known to be from
  another machine by the line it opens with, so the hold is as good as the
  client's promise to open every such message with that line.
- `git commit --no-verify` skips the commit-time scan by design; the
  content is still caught at `pre-push` — but `git push --no-verify`
  skips that too. Bypass is a deliberate operator action, never a
  default.
- Text typed straight into the GitHub web UI — a wiki page, a gist, an
  edit made in the browser — never passes through this machine, so nothing
  scans it live. The deep audit covers PR/Issue title+body and comment
  threads (conversation + inline review comments) after the fact; a PR
  review *summary* body, wikis, and gists stay out of scope there too.
- The `gh` shim only guards calls that resolve through PATH, and PATH order
  is per-shell: a login `bash` rebuilds it from the system defaults and
  never reads a `zsh` profile, so the shim can sit first in one shell and
  behind the real binary in another. `bootstrap-machine.sh` resolves `gh`
  in every installed login shell and names the ones that miss it. Invoking
  the binary by absolute path goes around it regardless.
- A repository whose local `core.hooksPath` overrides the global one
  runs no baseline; `doctor.sh` exists to surface exactly that.
- The scan folds case and Unicode width (NFKC) before matching, but is
  otherwise literal PCRE against your word list — it cannot flag an
  identifier whose base form the list does not contain.
- The send guard sees the call, not what runs after it: a script or a
  program that posts over the network on its own is not read, a file that is
  not text (an image, an archive) is not compared, and a tool whose name says
  it reads is trusted to only read.
- An order is read from what the machine keeps, not from the operator's
  hand: the phrases are matched as written (a wording no tail covers is taken
  as an order), a message typed while the agent works may not be in the
  transcript yet when a call is judged, and a script the agent runs from a
  file is not read, so one that wrote the transcript would not be seen. What
  goes out is still only a call the agent showed, with the text it showed.
- A message between sessions is judged where the guard can see it: a
  `SendMessage` call, and a client that asks before it delivers. A client that
  does not ask delivers unjudged. A blocked local endpoint or tmux session is
  closed to the commands the guard reads (above), not to a script run from a
  file; and a machine's own name other than the loopback host is a `host:`
  name, so an endpoint reachable under it needs its own line.
- The agent entry guard sees tool calls only: text the operator pastes into
  the conversation marks nothing, other tools and hands are not held to it,
  and a program that runs git for the agent (a script in another language)
  is left to the git hooks.
- The private-document scan catches copies, not paraphrase: a value retyped
  on its own, or a sentence reworded, carries no run of the original. Numbers
  are not compared at all — short numbers are not specific to anything.

## Escape hatches

- One-off bypass: `git commit --no-verify` / `git push --no-verify`
  (hooks are a guardrail, not a prison — but see your own policies).
- Per-repo bypass: set a local `core.hooksPath`.
- One-off `gh` bypass: `GH_GUARD_SKIP=1 gh …`.
- One-off private-document bypass: `GUARD_CORPUS_SKIP=1 git push …` (or `gh …`).
- Tuning the private-document scan: `GUARD_CORPUS_RUN` / `GUARD_CORPUS_LATIN_RUN`
  (run length for prose), `GUARD_CORPUS_CODE_LINES` (how many consecutive whole
  lines of an area's code a sent file must hold to be a hit),
  `GUARD_VISIBILITY_TTL` (seconds a repository's visibility is remembered).
- An AI agent is held to none of these: the agent entry guard refuses any
  command that carries them (the operator types them, the agent does not).
- Full uninstall:
  `git config --global --unset core.hooksPath && rm -rf ~/.git-hooks`,
  `rm ~/.local/bin/gh`, and the `area-guard.py` entry in each Claude Code
  settings file.

## Repository layout

```
git-hooks/          entry points git calls: pre-commit / commit-msg / pre-push
                    dispatchers, lib/dispatcher-common.sh
gh-shim/            entry point PATH resolves as `gh`: gh-guard.sh
agent-hooks/        entry points an AI agent calls before each tool:
                    claude-code/area-guard.py (with outgoing.py, the send guard,
                    order.py, the operator's order for a send, and peers.py,
                    another session as a destination)
scanners/           the judgement the entry points call: anon-scan,
                    anon-audit-deep (11-source audit), anon-fix (history
                    scrub), anon-sync-truth, corpus-scan (private documents),
                    send-scan (a payload bound for a declared destination, or
                    for another session),
                    setup-lib, anon-words.example.txt
scripts/            setting up and checking a machine: bootstrap-machine.sh,
                    install.sh, doctor.sh, pr-create.sh,
                    weekly-audit.sh, install-weekly-audit.sh
tests/              bats suite (dispatcher helpers, all three hooks,
                    scanners, gh shim, agent hook, install and doctor)
_archive/           retired parts kept for reference, never installed into a
                    working path (see _archive/README.md)
```

## Tests

```sh
brew install bats-core parallel   # once
bats --jobs "$(getconf _NPROCESSORS_ONLN)" tests/
```

The tests run in parallel, one per core (`--jobs` needs GNU parallel);
`bats tests/` runs them one after another.

Every test builds a throwaway git repo and a sentinel-only word list
under the test tmpdir — no operator data is read and nothing outside
the tmpdir is touched.

## License

Apache-2.0
