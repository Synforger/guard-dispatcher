#!/usr/bin/env bats
# Every temp file the guards create lands under $TMPDIR.
#
# macOS mktemp ignores TMPDIR when it is given no template, or only -t: it
# writes to the per-user folder under /var/folders. A session caged by
# sandbox/ may write its own TMPDIR only, so a guard that asks mktemp for a
# default location fails there -- and a guard that swallows that failure
# skips its scan without a word.

load helpers

@test "temp files: every mktemp names its template under TMPDIR" {
    run bash -c "cd '${GUARD_ROOT}' && git ls-files -z | xargs -0 grep -n 'mktemp' -- 2>/dev/null \
        | grep -v '^tests/' | grep -v '^README' | grep -v '^[^:]*:[0-9]*:\s*#' \
        | grep -v 'mktemp -d \"\${GUARD_HOME}' | grep -v 'mktemp \(-d \)\?\"\${TMPDIR:-/tmp}/'"
    [ -z "${output}" ]
}
