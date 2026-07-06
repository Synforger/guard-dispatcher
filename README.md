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

Enforcement targets are selected by `origin` URL (see *Scope* below);
all other repositories pass through untouched.

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
2. Classify the repository. Baseline scans run for:
   - repositories in the enforced organisation (edit
     `dispatcher::detect_repo_kind` in
     `git-hooks/lib/dispatcher-common.sh` to set yours),
   - repositories with no remote (fail-safe),
   - repositories opted in locally via `git config guard.scope enforced`.
3. Everything else runs only its own repo-local hooks. Explicit opt-out
   is available via `git config guard.scope exempt`, and a blanket
   opt-out for every repo under a private state directory can be set
   with `git config --global guard.exemptPrefix ~/some/private/tree` —
   useful when that directory's contents include the very words the
   master list flags, which makes the baseline structurally impossible.

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
