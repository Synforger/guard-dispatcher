"""Checks tests/contracts.txt against the tests that are there: called by tests/contracts.bats.

    contracts.py <repository root>

Prints one line per problem (a test file with no row, a row naming a test file or a target that is
gone, a row not in the `<target> | <test file> | <promise>` form) and exits 1 when there is one."""

from __future__ import annotations

import sys
from pathlib import Path

TABLE = Path("tests/contracts.txt")
FIELDS = 3


def problems(root: Path) -> list[str]:
    """Every way the table and the test files disagree, in the table's order then the files'."""
    found: list[str] = []
    rows: set[str] = set()
    for number, line in enumerate((root / TABLE).read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = [field.strip() for field in line.split("|")]
        if len(fields) != FIELDS or not all(fields):
            found.append(f"{TABLE}:{number}: not `<target> | <test file> | <promise>`")
            continue
        target, test, _ = fields
        if not (root / target).exists():
            found.append(f"{TABLE}:{number}: the target {target} is gone")
        if not (root / test).is_file():
            found.append(f"{TABLE}:{number}: the test file {test} is gone")
        rows.add(test)
    for test in sorted(path.relative_to(root).as_posix() for path in (root / "tests").rglob("*.bats")):
        if test not in rows:
            found.append(f"{test}: no row in {TABLE}: say in one sentence what it keeps")
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write(__doc__ or "")
        return 2
    found = problems(Path(argv[0]))
    for problem in found:
        print(problem)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
