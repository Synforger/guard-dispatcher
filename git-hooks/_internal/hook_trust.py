"""Whether a repository is one whose own `.githooks/<hook>` the dispatcher runs: the dispatcher's
`run_local_hook` (dispatcher-common.sh) calls it once per hook that a repository ships.

A repository hook runs with the operator's rights, so it runs only for a repository the machine
trusts. What the machine trusts comes from the machine's git settings and the repository's remote,
never from a file the repository's own tree carries:

- `guard.localHooks` is true (the repository's `.git/config`, or the machine's config, for example
  a `[includeIf "gitdir:..."]` file);
- the fetch address of `origin` names a GitHub repository of an owner in the built-in list or in
  `guard.hookOwners` (comma-separated).

A repository with no `origin`, or an address this file cannot read as `<GitHub host>/<owner>/<repo>`,
is not trusted. The host of an address is the part after its last `@` up to its port; it is
`github.com` or, for an ssh address (`ssh://` or `user@host:path`), `github-<alias>`, the name of an
ssh host entry on this machine. An https address is trusted only on `github.com`.

    hook_trust.py --local-hooks <true|false|unset> --owners <list> --url <fetch address>

Exit 0: trusted. Exit 1: not trusted.
"""

from __future__ import annotations

import argparse
import re
import sys

BUILTIN_OWNERS = ("synforger",)
GITHUB_HOST = "github.com"

_ALIAS_HOST = re.compile(r"github-[a-z0-9_-]+")
_OWNER_NAME = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?")
_REPO_NAME = re.compile(r"[A-Za-z0-9._-]+")
_UNREADABLE_CHARACTERS = re.compile(r"[\s\\\x00-\x1f\x7f]")


def github_owner(url: str) -> str | None:
    """The lower-cased owner of the GitHub repository `url` names, or None when it names none."""
    if not url or _UNREADABLE_CHARACTERS.search(url):
        return None
    if "://" in url:
        scheme, _, rest = url.partition("://")
        authority, _, path = rest.partition("/")
        host, has_port, port = authority.rpartition("@")[2].partition(":")
        if has_port and not port.isdigit():
            return None
        scheme = scheme.lower()
    else:
        authority, has_colon, path = url.partition(":")
        if not has_colon or "/" in authority:
            return None
        host = authority.rpartition("@")[2]
        scheme = "scp"
    if not _is_github_host(host.lower(), scheme):
        return None
    return _owner_of_path(path)


def hook_owners(setting: str) -> set[str]:
    """The owners `guard.hookOwners` names: lower-cased, with the built-in ones, empty entries dropped."""
    named = (entry.strip().lower() for entry in re.split(r"[,\n]", setting))
    return {owner for owner in named if owner} | set(BUILTIN_OWNERS)


def is_trusted(local_hooks: str, owners_setting: str, url: str) -> bool:
    """Whether the repository with this `guard.localHooks` value, owner list and fetch address is trusted."""
    if local_hooks == "true":
        return True
    owner = github_owner(url)
    return owner is not None and owner in hook_owners(owners_setting)


def _is_github_host(host: str, scheme: str) -> bool:
    if host == GITHUB_HOST:
        return scheme in ("https", "ssh", "scp")
    return scheme in ("ssh", "scp") and _ALIAS_HOST.fullmatch(host) is not None


def _owner_of_path(path: str) -> str | None:
    segments = path.removeprefix("/").removesuffix("/").split("/")
    if len(segments) != 2:
        return None
    owner, repo = segments[0], segments[1].removesuffix(".git")
    if _OWNER_NAME.fullmatch(owner) is None or _REPO_NAME.fullmatch(repo) is None or repo in (".", ".."):
        return None
    return owner.lower()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--local-hooks", choices=("true", "false", "unset"), default="unset")
    parser.add_argument("--owners", default="")
    parser.add_argument("--url", default="")
    arguments = parser.parse_args()
    return 0 if is_trusted(arguments.local_hooks, arguments.owners, arguments.url) else 1


if __name__ == "__main__":
    sys.exit(main())
