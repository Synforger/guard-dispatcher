"""The operator's approval of a forced push, kept as a one-time grant, and the check of a push that rewrites history.

Two sides use it:

- agent-hooks' area-guard.py gives the grant (`give`) when the operator approved a call whose forced
  push goes to a repository that destinations.txt marks `order`;
- git-hooks/pre-push runs `force_push.py check <url>` for a push the agent's shell made to such a
  repository. It sees what the agent's command line did not show (a force set in a config, an alias
  or a script's code): a push that rewrites a ref passes only while a grant of that repository,
  for that URL, stands, and the push uses the grant up.

A grant is the file `<state folder of the guard>/force-grants/<first 16 hex of the sha256 of the
repository's top folder>.json`, holding the URLs it covers and the time it ends. The agent cannot
write that folder (area-guard.py keeps it like the marks).

    force_push.py check <url>     ref lines of the pre-push hook on stdin; exit 0 lets the push on,
                                  1 stops it with the reason on stderr
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_common"))
import guard_places  # noqa: E402
from path_forms import resolved  # noqa: E402

#: How long the operator's approval of a forced push stands, in seconds.
GRANT_SECONDS = 10 * 60
GRANTS_FOLDER = "force-grants"
KEY_LENGTH = 16
# A ref that does not exist on one side is named by a sha of zeros, 40 of them or 64 in a SHA-256 repository.
ZERO_SHA = re.compile(r"0+")
REFUSAL = (
    "[pre-push] this push rewrites {refs} on {url}, which destinations.txt holds to the operator's "
    "approval (`order`), and no approval stands for it. A force set in a config, an alias or code is "
    "not seen before it runs: write `--force-with-lease` on the command line and show the call to "
    "the operator in a ```guard block"
)


def grants_folder() -> Path:
    """Where the grants are kept: next to the folder of the session marks."""
    return guard_places.marks_folder().parent / GRANTS_FOLDER


def grant_path(root: Path) -> Path:
    """The file that holds the grant of the repository whose top folder is `root`."""
    import hashlib   # loaded where it is used: the entry guard imports this file for every call
    key = hashlib.sha256(str(resolved(root)).encode()).hexdigest()[:KEY_LENGTH]
    return grants_folder() / f"{key}.json"


def give(root: Path, url: str, now: float | None = None) -> None:
    """Record that the operator approved a forced push of the repository at `root` to `url`: one
    push that rewrites a ref may use it, until GRANT_SECONDS have passed. The URLs of a grant
    still standing stay in it."""
    now = time.time() if now is None else now
    path = grant_path(root)
    urls = [url]
    try:
        held = json.loads(path.read_text())
        if held.get("expires", 0) > now:
            urls = sorted({*held.get("urls", []), url})
    except (OSError, ValueError, AttributeError):
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(".new")
    pending.write_text(json.dumps({"urls": urls, "expires": now + GRANT_SECONDS}))
    pending.replace(path)


def take(root: Path, url: str, now: float | None = None) -> bool:
    """True when a grant of the repository at `root` covers `url` and has not ended: it is used up."""
    now = time.time() if now is None else now
    path = grant_path(root)
    try:
        held = json.loads(path.read_text())
        covered = url in held.get("urls", []) and held.get("expires", 0) > now
    except (OSError, ValueError, AttributeError):
        return False
    if covered:
        path.unlink(missing_ok=True)
    return covered


def rewrites(ref_lines: str) -> list[str]:
    """The remote refs a push's ref lines (`<local ref> <local sha> <remote ref> <remote sha>`)
    overwrite with a commit that is not their descendant. A new ref and a deletion rewrite nothing;
    a remote commit this repository does not hold counts as rewritten, since it cannot be shown to
    be an ancestor."""
    import subprocess   # loaded where it is used, as in grant_path
    found = []
    for line in ref_lines.splitlines():
        fields = line.split()
        if len(fields) != 4:
            continue
        _, local_sha, remote_ref, remote_sha = fields
        if ZERO_SHA.fullmatch(local_sha) or ZERO_SHA.fullmatch(remote_sha):
            continue
        ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", remote_sha, local_sha],
                                  capture_output=True)
        if ancestor.returncode != 0:
            found.append(remote_ref)
    return found


def top_folder() -> Path | None:
    """The top folder of the repository the hook runs in, or None for one with no working tree."""
    import subprocess
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(top.stdout.strip()) if top.returncode == 0 and top.stdout.strip() else None


def check(url: str, ref_lines: str) -> str | None:
    """None when the push may go on, else why it stops: it rewrites a ref and no grant covers it."""
    refs = rewrites(ref_lines)
    if not refs:
        return None
    root = top_folder()
    if root is not None and take(root, url):
        return None
    return REFUSAL.format(refs=", ".join(refs), url=url)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != "check":
        print("usage: force_push.py check <url>  (ref lines on stdin)", file=sys.stderr)
        return 2
    why = check(argv[1], sys.stdin.read())
    if why:
        print(why, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
