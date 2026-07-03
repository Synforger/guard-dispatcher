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
| commit (message) | `commit-msg` | commit subject/body scanned |
| push | `pre-push` | outgoing commit range deep-scanned (blobs, messages, authors) |
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

`bootstrap-machine.sh` symlinks the hooks into `~/.git-hooks/`, points
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

Every hook follows the same three-step logic:

1. If the repository ships its own `.githooks/<hook>`, delegate to it.
   Repo-local hooks always win.
2. Otherwise, classify by `origin` URL: repositories in the enforced
   organisation (edit `dispatcher::detect_repo_kind` in
   `git-hooks/lib/dispatcher-common.sh` to set yours) and repositories
   with no remote (fail-safe) get the baseline scans.
3. Everything else is a no-op.

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
scripts/            bootstrap-machine.sh, pr-create.sh
```

## License

Apache-2.0
