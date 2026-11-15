"""How long reading the changed documents will take, from how long such documents took before:
corpus-scan.py's catch_up() says the estimate before it reads, and records what the read took.

A scan reads the documents changed since the last look before it answers. Most such reads take a
second; one after a day of work can take minutes, and the session that sent something only saw it
hang. The time a kind of document (its extension) took per document is kept, and a read expected
to be long is announced with its size and its time before it starts.

The kept rates are `{extension: [seconds, documents]}`. Each kind keeps at most RATE_WINDOW
documents' worth, halving both numbers past it, so a change in how documents are read (a faster
extractor) shows within a few hundred reads.
"""

from __future__ import annotations

from collections import Counter

#: Past this many documents of one kind, its seconds and its count are halved: recent reads weigh most.
RATE_WINDOW = 500
#: A read expected to take longer than this is announced before it starts: a quarter of the two
#: minutes send-scan.py gives the whole scan.
LOUD_SECONDS = 30


def estimate(kinds: Counter, rates: dict) -> float | None:
    """The seconds reading these documents (counted by kind) should take, or None with no rate kept
    yet. A kind never read before is taken at the average of all kinds."""
    seconds = sum(rate[0] for rate in rates.values())
    documents = sum(rate[1] for rate in rates.values())
    if documents <= 0:
        return None
    average = seconds / documents
    return sum(count * (rates[kind][0] / rates[kind][1] if rates.get(kind, [0, 0])[1] > 0 else average)
               for kind, count in kinds.items())


def updated(rates: dict, spent: Counter, counted: Counter) -> dict:
    """The kept rates with this read's seconds (`spent`) and documents (`counted`) by kind added."""
    out = {kind: list(rate) for kind, rate in rates.items()}
    for kind, count in counted.items():
        seconds, documents = out.get(kind, [0.0, 0])
        seconds, documents = seconds + spent[kind], documents + count
        while documents > RATE_WINDOW:
            seconds, documents = seconds / 2, documents // 2
        out[kind] = [round(seconds, 3), documents]
    return out
