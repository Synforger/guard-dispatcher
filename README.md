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
| AI agent session | `sandbox/run.mjs` + `sandbox/cage-config.py` (OS sandbox around Claude Code) | a session started in one area's cage cannot read the other areas nor write outside its own, whatever program tries — tool call, shell redirection or a script's own file I/O |
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

`bootstrap-machine.sh` installs the clone into `~/.local/share/guard-dispatcher`
(`$GUARD_HOME`), symlinks the installed hooks (and the `scanners/`, `scripts/`,
`agent-hooks/` and `sandbox/` directories, for stable paths) into
`~/.git-hooks/`, points git's global `core.hooksPath` there, installs the
`gh` shim and the session sandbox runtime, verifies your word list and
external tools, and finishes with a doctor pass. It is idempotent.

The guards run from the install, never from the clone: edit the clone freely,
then re-run the script to install what you changed. An agent session caged by
`sandbox/` may write the clone but not the install, so it cannot edit the
guards that judge it. Installing copies the clone's tracked files as they are
on disk and keeps the word lists the install already holds. To run the guards
from the clone in place instead, set `GUARD_HOME` to the clone.

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
back to the install's `scanners/` — so individual repositories need
no toolkit of their own, but can override it.

### Private documents

A word list only holds what someone thought to write down. Text copied out of a
real document — a sentence from a slide, a row of a table — is on no list.
`scanners/corpus-scan.py` compares what a push (or a `gh` call) sends with the
documents themselves. Everything it reads is configured on this machine only:

```
~/.config/guard/areas.txt               <name> <path> [<path> ...]   one area per line
                                        <prefix>* <path>/* ...       one area per sub-folder
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

Prints are kept per document and reused while a document is unchanged.
Documents changed since the last scan are found through Spotlight and added at
once. When Spotlight cannot answer (indexing off, an area it does not index, or
a sandbox that can still list the area's folder) the size and modification
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

**Where the text is going decides what it may carry**: every area that does
not contain the destination is checked. Areas nest — a client inside a
company — so a client's repository may carry the company's text, a company
repository may not carry the client's, and a repository outside both carries
neither.

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

`corpus-scan.py --refresh` walks everything now; `--update` brings the prints
up to date (the changed documents, everything when a full walk is due) and
says only how many documents could not be read; `--status` shows what is
loaded and names what could not be read; `--summary` (what `doctor.sh` runs)
shows the same in counts. A machine with no `areas.txt` prints
`NOT CHECKED` and passes.

Every line printed without being asked — a clean scan, a rebuild, the notice
inside a sandbox, `--update`, `--summary`, `doctor.sh` and so bootstrap —
counts areas and documents and names none: it lands in whatever reads the
output — an agent's conversation, a CI log — and an area's name or a
document's path says what the area holds. A refusal names the area, for the
operator to act on; `--status`, typed by the operator, names everything.

Inside a sandbox that cannot open some area — a session caged by `sandbox/` —
the scan compares with the prints last built outside and says when they were
built. It walks nothing there and rewrites nothing cached: a walk from inside
would build the areas it cannot open empty. An area whose folder cannot be
listed is taken from the areas those prints were built for, and an area with
no prints at all is a refusal. `sandbox/start.sh` runs `--update` before it
enters a cage, so the prints are those of the moment the session started.

### Agent entry guard

The push-time scan catches copies. An AI agent can carry what it read without
copying a single line, so `agent-hooks/claude-code/area-guard.py` stops it one
step earlier, before each tool call, from the same `areas.txt`:

- A session that reads inside an area (a `Read` / `Grep` / `Glob` target, an
  area path named in a `Bash` command, a `Bash` working directory) is marked
  with the area's name. A command that only checks the paths it names marks
  nothing: `test`, `[ … ]`, `stat`, `realpath`, `readlink` or `ls -d` run on
  its own, every argument literal (no second command, pipe, redirect,
  substitution, glob or variable other than `$HOME`). Anything else is taken
  to read what it names. Only an area the session can read marks it: the hook
  runs inside the session's cage, and where the cage hides an area (see
  [Session cage](#session-cage)) the OS refuses the read, so naming a path in
  it marks nothing. Marks are kept per session under
  `~/.cache/area-guard/`, so they outlive the agent compacting its context.
  The same file keeps when the session ran in a cage: from the moment the cage
  was entered (`start.sh` hands the session `GUARD_CAGED_SINCE`) to the last
  call the hook saw there, one run per cage the conversation was opened in.
- A marked session cannot `Edit` / `Write` a file inside a git repository
  outside its marks, nor write one from the shell where the command names it
  (a `>` / `>>` redirection, `tee`, `touch`, the destination of `cp` / `mv`
  / `install` / `ln`, `sed -i`, `dd of=`, or a path inside inline code such as
  `python3 -c` or `bash -c`, which cannot be told apart from a read). A script
  run from a file is not read, so what it writes is not judged. It also cannot `git commit`, `git push` or send through `gh`
  to a destination outside them. Destinations are judged exactly as the
  push-time scan judges them (`corpus-scan.py --where`). Files outside any
  repository and `_exempt` areas stay writable.
- Areas nest as they do for the scan: a session that read only the company may
  still write the client's repository inside it; one that read the client may
  not write the company's.
- On every machine, areas or not, a `Bash` command that switches the guards off
  or around is refused: `--no-verify`, `git commit -n`, the skip variables,
  `git -c core.hooksPath=…`, setting `core.hooksPath` / `guard.scope` /
  `guard.exemptPrefix`, clearing the marks, or sending from a repository the
  git hooks do not reach. The operator types those; the agent does not.
  A commit in a repository with no remote is the one send let through there:
  it stays in the repository and has nowhere to go. Its push is still refused.

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
  pipe or a heredoc — cannot be scanned and is refused unless it goes to this
  machine; write it to a file and send the file instead.
  Other network commands are read the same way: `scp` / `rsync` (the local
  files copied to a remote host; a folder counts as a file that cannot be
  scanned), `ssh` / `nc` (the remote command and standard input), `mail` /
  `mailx` / `sendmail` (subject, body and attachments, named `mail:<domain>`),
  HTTPie (`http` / `https` / `xh`: request items and uploaded files),
  `aws s3` / `gcloud storage` / `gsutil` / `rclone` (local sources copied to
  `s3:<bucket>`, `gs:<bucket>` or `rclone:<remote>`). `socat` and `sftp` to
  another host are refused, since what they send is only known as they run.
  A command not listed here is not read; its sends are the cage's to limit.
  The text of an Office document or a PDF is taken out of it first. A file
  whose text cannot be taken out (over 8 MB, or not text, like an image)
  cannot be scanned: it is refused once the session has read inside an area,
  or when the file itself sits inside one, and passes otherwise.
  A reading call (a tool whose name says it reads: get, list, search, read,
  fetch, query, view, find, export, ...) still hands the service its own
  strings, such as a search term, so those are scanned; the files it names are
  not uploaded and not read, and a service blocked for sending still takes
  reads, judged as outside every area. A fetch without a body and anything sent
  to the loopback host are not sends.
- **Against what**: the private-document scan compares the payload with the
  areas its destination sits outside of, exactly as for a push; a destination
  outside every area also gets the word-list scan, as a public repository does.
- **Where a destination sits** is declared per machine in
  `$GUARD_CONFIG_DIR/destinations.txt`, first match winning:

  ```
  # pattern                 area | outside | block
  mcp__*drive*              company     # company text may go there, a client's may not
  host:*.corp.example.com   company
  *slack*                   block       # sending refused outright; reading still works
  ```

  The pattern is a glob over the tool name, or over `host:<name>` for a
  network command. A destination no line names is outside every area, so a new
  service carries nothing private until it is declared. A line naming an
  unknown area stops every send until it is fixed.

### Session cage

The entry guard reads commands; a program that opens a file itself (a Python
one-liner, a build script) says nothing in the command about where it writes.
`sandbox/` closes that at the OS instead: a Claude Code session is started
inside one cage and the kernel refuses what the cage does not allow
([sandbox-runtime](https://github.com/anthropics/sandbox-runtime):
Seatbelt on macOS), for the session and every process it starts.

```sh
python3 sandbox/cage-config.py --list               # personal, then one cage per area
python3 sandbox/cage-config.py --of ~/org/clients/acme   # the cage a path belongs to
python3 sandbox/cage-config.py --record <session-id>     # the cage and account a past conversation lives under
python3 sandbox/cage-config.py --config-dirs             # the cages' config directories that exist
bash sandbox/start.sh company                       # Claude Code inside the company's cage
bash sandbox/start.sh personal -- git push          # any command inside a cage
```

`start.sh` builds the cage (`cage-config.py <cage>` prints it as
sandbox-runtime config and environment), starts the cage's config directory
from the account's (`seed-config.py`), brings the private-document prints up
to date outside it, and runs the command inside it (`run.mjs`). Through
`~/.git-hooks/sandbox/start.sh` it always runs the installed guards.
`--of PATH` answers which cage a folder is worked on in — the innermost area
holding it, else `personal` — so a launcher can pick the cage from where the
work is.

A new cage config directory would open on Claude Code's first-run screens,
where a session started by a script or a web client waits for an answer.
`seed-config.py` carries over what the account has been through — the
first-run markers, `settings.json` when the cage has none, and the
folder-trust answers for the folders the cage can read (a folder's path names
what it holds, so the company's cage is not told its clients'). What the cage
has chosen since is never overwritten, and `personal`, which keeps the
account's own directory, is left as it is.

A cage is `personal` or the name of an area in `areas.txt`:

- `personal` reads everything but the areas and writes anywhere in `$HOME`
  but the areas.
- An area reads everything but the other areas — the areas around it stay
  readable, so a client session still reads the company notes it sits in —
  and writes only inside itself, `_exempt`, a few machine caches, the login
  keychain's folder (`~/Library/Keychains`: a token refresh rewrites the
  keychain file, and a revoked token is left without it) and its own
  directories. An area around it is left out of the writable set (a write-deny
  would also cover the area inside it); where it sits inside `_exempt`, that
  folder is opened entry by entry around it, so a new file directly beside
  such an area cannot be created from the inner cage.
- Every cage has its own Claude Code config directory (`<account dir>@<cage>`,
  e.g. `~/.claude@company`, logged in as the account; `personal` keeps the
  account's own) and temp
  directory (`/tmp/claude-cage/<cage>`; `GUARD_TMP_ROOT` moves the root,
  which the test suite uses), and cannot read another
  cage's — nor the temp folders sessions would otherwise share, where one
  cage's conversation would be readable from the next.
- No cage writes the guards themselves: the install the hooks run from,
  `~/.git-hooks`, the global git config (`~/.config/git` and `~/.gitconfig`,
  where `core.hooksPath` is), the shells' startup files (`~/.zshrc`,
  `~/.zshenv`, `~/.zprofile`, `~/.zlogin`, `~/.bashrc`, `~/.bash_profile`,
  `~/.profile`: where a launcher is defined), the guard's config directory, the
  scanners' master word list (`~/.config/anon-words/`, or wherever
  `ANON_TRUTH_PATH` points — the same default every scanner and sync script
  reads), or Claude Code's settings files (`~/**/.claude*/settings*.json`:
  every config dir's and every project's), where the entry guard is
  registered and where a `disableAllHooks` would switch it off. `start.sh`
  writes them before the cage starts. The settings glob is a macOS-only rule.
- The network is left open. What leaves the machine is judged by the git and
  `gh` guards, by content, not by destination. Every cage may look up the
  file-change notices, TLS verification and the audio-device list; only the
  personal cage reaches the clipboard (what an area cage put there, the
  personal cage could read).
- On macOS every cage may read the `security.mac.sandbox.sentinel` sysctl:
  Security.framework reads it before it writes a keychain item, and refused,
  every keychain write fails — Claude Code keeps its login in the keychain, so
  `/login` and each token refresh would fail and the session would go on with
  a revoked token. sandbox-runtime has no setting for a sysctl, so `run.mjs`
  runs `sandbox-exec` through `seatbelt-exec.sh`, which appends the cage's
  `seatbelt` rules (from `cage-config.py`) to the end of the profile.

Conversations from before the cages all live in the account's own config
directory, which the personal cage reads. `sandbox/sort-sessions.py` moves each
one that worked inside an area — the entry guard marked it there, or its record
(or a subagent's) names a working directory or a tool call's path inside the
area — into that area's cage directory, with its edit backups, environment,
prompt-history lines and the pastes only those lines cite; folders inside an
area leave the account's state file too. A path only printed in a tool's
output does not count, nor does a row written while the conversation ran in a
cage (the entry guard keeps those runs): the cage refused what it hid, and the
guard marked only what the session could read. Conversations across areas that
do not nest are listed and left, and running ones are skipped. It prints the plan; `--apply` moves.
A conversation judged to stay is remembered (`~/.cache/guard-sort/`) and not
read again until its record, its subagents' records or its mark change, so a
launcher can run `--apply --quiet` before every session: it prints only when
something moves or is left for a person to decide.

```sh
python3 sandbox/sort-sessions.py --account-dir ~/.claude --account-dir ~/.claude-work
```

`run.mjs` never falls back: a cage it cannot build is a refusal and the
command does not run. `bootstrap-machine.sh` installs the runtime from
`sandbox/package-lock.json`.

Every cage also leaves alone what runs outside the cages by itself: login items
(`~/Library/LaunchAgents`), each PATH folder under HOME (`~/.local/bin` comes
before git and gh), the install a link there leads into (a venv, a Python build,
a folder of versions: Claude Code's updater is off inside a cage, so whatever
starts the cage updates it outside), the base of a conda prefix whose shell hook runs at every
shell start (its `envs/` and `pkgs/` stay writable), and each path listed in
`$GUARD_CONFIG_DIR/outside-run.txt` (one a line: a server a relay starts outside
the cage, an editable install).

The launcher that builds a cage runs outside it, from a repository the agent
edits inside one. `scripts/pre-launch.sh` stands in front of it, called from the
shell's launch function (a startup file no cage writes): it pulls the repository
(`--pull`), refuses a watched path (default `.tooling`) that differs from HEAD
unless the terminal answers `y`, names in one line what changed there since the
last start, then runs the launcher with `GUARD_PRE_LAUNCH=1` so the launcher
does not pull after the check.

```sh
agent() { cd ~/agent && ~/.git-hooks/scripts/pre-launch.sh --pull ~/agent -- ~/agent/.tooling/claude-launch.sh "$@"; }
```

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
- The agent entry guard sees tool calls only: text the operator pastes into
  the conversation marks nothing, other tools and hands are not held to it,
  and a program that runs git for the agent (a script in another language)
  is left to the git hooks.
- The session cage holds only sessions started through `sandbox/run.mjs`: a
  plain `claude` runs uncaged. It is exercised on macOS; the Linux path
  (bubblewrap) is untested here.
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
                    claude-code/area-guard.py (with outgoing.py, the send guard)
sandbox/            the OS cage an agent session runs in: start.sh (the entry
                    point), cage-config.py (the cage from areas.txt),
                    seed-config.py (the cage's config directory from the
                    account's), run.mjs (runs a command in it, with
                    seatbelt.mjs / seatbelt-exec.sh adding the macOS rules
                    sandbox-runtime has no setting for),
                    sort-sessions.py (moves past conversations into cages)
scanners/           the judgement the entry points call: anon-scan,
                    anon-audit-deep (11-source audit), anon-fix (history
                    scrub), anon-sync-truth, corpus-scan (private documents),
                    send-scan (a payload bound for a declared destination),
                    setup-lib, anon-words.example.txt
scripts/            setting up and checking a machine: bootstrap-machine.sh,
                    install.sh, doctor.sh, pr-create.sh, pre-launch.sh,
                    weekly-audit.sh, install-weekly-audit.sh
tests/              bats suite (dispatcher helpers, all three hooks,
                    scanners, gh shim, agent hook, session cage, install and
                    doctor)
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
