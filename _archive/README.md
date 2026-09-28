# _archive

Retired parts, kept for reference. Nothing here is installed into a working path or run by the test suite.

- `sandbox/`, `tests/{cage-config,sandbox-start,seatbelt,seed-config,sort-sessions}.bats`: the per-area OS cage for agent sessions. Retired because confining where a session may read and write broke ordinary work (build tool caches, ssh, VMs, updating the guards themselves) while adding nothing to what leaves the machine: sends were always judged by content, and the network was never closed by the cage.
- `scripts/pre-launch.sh`, `tests/pre-launch.bats`: started a launcher only as committed, because the launcher ran outside the cage that a caged session could otherwise escape by editing it. With no cage, there is nothing to escape.
- `tests/temp-files.bats`: required every temp file under `$TMPDIR`, because a caged session could write only its own temp folder.
