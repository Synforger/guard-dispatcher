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
| push | `pre-push` | outgoing commit range deep-scanned (blobs, messages, authors); every author/committer must be an allowed identity |
| push (refs) | `pre-push` | branch/tag names scanned; direct pushes to main/develop refused (initial branch-creating push exempt; `GUARD_ALLOW_PROTECTED_PUSH=1` overrides once) |
| PR | `scripts/pr-create.sh` | PR title/body scanned before `gh pr create` |
| repair | `scanners/anon-fix.sh` | rewrites unpushed history in place (`git filter-repo`) so neither the leak nor the repair scar is published |
| health | `git-hooks/doctor.sh` | reports unarmed repos, hooksPath overrides, word-list drift |

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

`bootstrap-machine.sh` symlinks the hooks (and the `scanners/` and
`scripts/` directories, for stable Taskfile paths) into `~/.git-hooks/`,
points
git's global `core.hooksPath` there, verifies your word list and
external tools, and finishes with a doctor pass. It is idempotent.

### Word list

Scanners read one PCRE fragment per line from the first of:

1. `$ANON_WORDS_FILE` (explicit override)
2. `$HOME/.config/anon-words/master.txt` (recommended location)
3. a repo-local `.tooling/local-ci/anon-words.txt` (legacy)

The word list is private operator data — it is never committed
anywhere. See `scanners/anon-words.example.txt` for the format.

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

`guard.wordlist` feeds the scanners a scope-specific list (resolution:
`$ANON_WORDS_FILE` → `guard.wordlist` → operator master → repo-local).
`guard.allowedEmails` (comma-separated) replaces the built-in identity
list for that scope. Existing repo-local `.githooks/` keep running
first (AND-composition), so per-repo rules still apply on top.

Scanners resolve repo-local first (`.tooling/local-ci/`), then fall
back to this checkout's `scanners/` — so individual repositories need
no toolkit of their own, but can override it.

## Scan guarantee

The contract a machine-wide install provides, stated precisely — both
directions.

### Guaranteed

On a machine where `doctor.sh` reports no gaps, for every repository
except an explicit `exempt`:

- **No commit is created** whose staged file contents or commit message
  match the word list (`pre-commit`, `commit-msg`).
- **No push publishes** matching content: every outgoing commit is
  deep-scanned — all blobs (full diffs), the message, and the
  author/committer name+email — and the pushed branch or tag name is
  scanned as well (`pre-push`). A new-branch push scans exactly the
  commits the remote does not already have; force-pushed rewritten
  history falls back to a full scan of the new history.
- On identity-enforced repositories (enforced org / no-remote /
  `guard.scope enforced`), additionally: the committer and every author
  in the outgoing range must be on the identity allow-list, and direct
  pushes to protected branches are refused.
- PRs opened through `scripts/pr-create.sh` have their title and body
  scanned before `gh pr create` runs.
- After the fact, `anon-audit-deep` sweeps 11 sources — tracked files,
  every history blob, commit messages, branch names, tag names +
  annotations, author/committer fields, GitHub PR + Issue title/body +
  comment threads, repo description/topics/homepage, releases, and
  Actions run titles.
  The weekly audit runs it scoped to the week's activity.

### Not covered — know your gaps

- `git commit --no-verify` skips the commit-time scan by design; the
  content is still caught at `pre-push` — but `git push --no-verify`
  skips that too. Bypass is a deliberate operator action, never a
  default.
- Text that never passes through git or `pr-create.sh` — wikis, gists,
  and anything typed into the GitHub web UI — is not scanned live. The
  deep audit covers PR/Issue title+body and comment threads (conversation
  + inline review comments) after the fact; a PR review *summary* body,
  wikis, and gists remain out of scope.
- A repository whose local `core.hooksPath` overrides the global one
  runs no baseline; `doctor.sh` exists to surface exactly that.
- The scan folds case and Unicode width (NFKC) before matching, but is
  otherwise literal PCRE against your word list — it cannot flag an
  identifier whose base form the list does not contain.

## Escape hatches

- One-off bypass: `git commit --no-verify` / `git push --no-verify`
  (hooks are a guardrail, not a prison — but see your own policies).
- Per-repo bypass: set a local `core.hooksPath`.
- Full uninstall:
  `git config --global --unset core.hooksPath && rm -rf ~/.git-hooks`.

## Repository layout

```
git-hooks/          pre-commit / commit-msg / pre-push dispatchers,
                    install.sh, doctor.sh, lib/dispatcher-common.sh
scanners/           anon-scan, anon-audit-deep (11-source audit),
                    anon-fix (history scrub), anon-sync-truth,
                    setup-lib, anon-words.example.txt
scripts/            bootstrap-machine.sh, pr-create.sh,
                    weekly-audit.sh, install-weekly-audit.sh
tests/              bats suite (dispatcher helpers + all three hooks)
```

## Tests

```sh
brew install bats-core   # once
bats tests/
```

Every test builds a throwaway git repo and a sentinel-only word list
under the test tmpdir — no operator data is read and nothing outside
the tmpdir is touched.

## License

Apache-2.0
