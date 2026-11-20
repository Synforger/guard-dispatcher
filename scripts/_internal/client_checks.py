"""Whether a client that relays messages and tickets between sessions has every judgement of the guard
in its configuration: scripts/client-checks.sh calls it, and a platform's start-up check runs that.

A client that carries text from one agent session to another asks the guard before it does, through
commands in its configuration (`agent_message_check`, `ticket_write_check`, ...). A command left out
is a step the client takes unjudged, and nobody sees it: the client cannot tell a machine without a
guard from one whose configuration lost a line. This reads the configuration and prints one line per
problem: a judgement that is missing, one that does not run this guard's `peers.py`, and one whose
options `peers.py` would not judge as asked (a required option left out, an option it does not have).

    client_checks.py --root <platform root>    exit 0 and print nothing when every judgement is
                                               there, exit 1 with one line per problem

A machine without the client's configuration file has nothing to check and exits 0. Nothing is
written and nothing is run.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

#: Where the client's configuration sits under the platform root.
CONFIG = Path("config/claude-pwa-client/config.json")
#: The guard's program the judgements run, as installed and in this checkout.
PEERS = Path("agent-hooks/claude-code/peers.py")
INSTALLED_PEERS = Path("~/.git-hooks") / PEERS
CHECKOUT_PEERS = Path(__file__).resolve().parents[2] / PEERS
#: Every long option of peers.py.
PEERS_OPTIONS = frozenset({"--to", "--text", "--covers", "--typed-in", "--roles", "--folder", "--session",
                           "--place-for", "--to-place", "--covers-place", "--places"})
#: Each judgement the client asks, with the options its command must give peers.py, and what the client
#: does without it.
JUDGEMENTS = {
    "agent_message_check": (("--to", "--text"), "messages between sessions"),
    "agent_message_operator_check": (("--to", "--typed-in", "--text"), "the operator's words in messages"),
    "agent_message_sender_check": (("--to", "--covers"), "the sender's name in messages"),
    "ticket_place_check": (("--place-for",), "where a ticket sits"),
    "ticket_places_check": (("--places",), "the folders tickets sit in"),
    "ticket_write_check": (("--to-place", "--text"), "what is written into a ticket"),
    "ticket_covers_check": (("--to", "--covers-place"), "who a ticket is passed to"),
    "ticket_read_check": (("--to", "--text"), "what a session reads of a ticket"),
}


def problems(config: dict) -> list[str]:
    """One line per judgement of `config` that is missing or does not ask peers.py as it must."""
    found = []
    for key, (required, judged) in JUDGEMENTS.items():
        command = config.get(key)
        if not command:
            found.append(f"client config: {key} is missing, so the client does not ask the guard about {judged}")
            continue
        if not isinstance(command, list) or not all(isinstance(word, str) for word in command):
            found.append(f"client config: {key} is not a list of words")
            continue
        if not any(_is_peers(word) for word in command):
            found.append(f"client config: {key} does not run the guard's peers.py ({INSTALLED_PEERS})")
            continue
        options = {word.split("=", 1)[0] for word in command if word.startswith("--")}
        if missing := [option for option in required if option not in options]:
            found.append(f"client config: {key} gives peers.py no {', '.join(missing)}")
        if unknown := sorted(options - PEERS_OPTIONS):
            found.append(f"client config: {key} gives peers.py {', '.join(unknown)}, which it does not take")
    return found


def _is_peers(word: str) -> bool:
    path = Path(os.path.expanduser(word))
    if path.name != PEERS.name or not path.is_file():
        return False
    targets = {CHECKOUT_PEERS, Path(os.path.expanduser(INSTALLED_PEERS)).resolve()}
    return path.resolve() in targets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, required=True, help="the agent platform's root folder")
    args = parser.parse_args()
    path = args.root.expanduser() / CONFIG
    if not path.is_file():
        return 0
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"client config: {path} cannot be read ({error})")
        return 1
    found = problems(config if isinstance(config, dict) else {})
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
