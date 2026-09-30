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
applications. Nothing read there marks a session, nothing there is a document,
and a session marked by the company may not write a repository there. An `_outside` folder
inside an area is cut out of it too.

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
  area path named in a `Bash` command, a `Bash` working directory) is marked
  with the area's name. A command that only checks the paths it names marks
  nothing: `test`, `[ … ]`, `stat`, `realpath`, `readlink` or `ls -d` run on
  its own, every argument literal (no second command, pipe, redirect,
  substitution, glob or variable other than `$HOME`). Anything else is taken
  to read what it names. Marks are kept per session under
  `~/.cache/area-guard/`, so they outlive the agent compacting its context.
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
  pipe or a heredoc — cannot be scanned and is refused when it goes to a
  declared destination; write it to a file and send the file instead.
  Other network commands are read the same way: `scp` / `rsync` (the local
  files copied to a remote host; a folder counts as a file that cannot be
  scanned), `ssh` / `nc` (the remote command and standard input), `mail` /
  `mailx` / `sendmail` (subject, body and attachments, named `mail:<domain>`),
  HTTPie (`http` / `https` / `xh`: request items and uploaded files),
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
  Anything sent to the loopback host is not a send.
- **Against what**: the private-document scan compares the payload with the
  areas its destination sits outside of, exactly as for a push; a destination
  outside every area also gets the word-list scan, as a public repository does,
  and one inside an area gets that area's own word list when the machine keeps
  one beside the master (`company.txt` next to `master.txt`: the company takes
  real names but not the operator's handles).
- **Where a destination sits** is declared per machine in
  `$GUARD_CONFIG_DIR/destinations.txt`, first match winning:

  ```
  # pattern                 area | outside | block
  mcp__*drive*              company     # company text may go there, a client's may not
  host:*.corp.example.com   company
  browser:*.corp.example.com company    # a browser tool typing into a page there
  *slack*                   block       # sending refused outright; reading still works
  ```

  The pattern is a glob over the tool name, over `host:<name>` for a
  network command, or over `browser:<host>` for a browser tool (an MCP call
  naming a `tabId`) whose tab this session opened at a page there; a tab it did
  not open stays named by the tool, and one opened at a page keeps that host
  after a click takes it elsewhere. A line naming an unknown area stops every
  send until it is fixed.

  **A destination no line names is undeclared and passes, unscanned**: the
  guard stops what it knows leaves an area, and a build machine or an internal
  service is not stopped for being unlisted. What publishes to the internet or
  to a personal account is outside every area with no line — the Artifact
  tools, WebFetch, WebSearch and claude.ai's connectors (`mcp__claude_ai_*`);
  a line in the file overrides that. To hold every other destination to the
  scan, end the file with `* outside`.

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
scanners/           the judgement the entry points call: anon-scan,
                    anon-audit-deep (11-source audit), anon-fix (history
                    scrub), anon-sync-truth, corpus-scan (private documents),
                    send-scan (a payload bound for a declared destination),
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
