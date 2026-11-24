# Suite-wide hooks of the guard-dispatcher test suite. bats reads this file when it is given
# the test folder (`bats -r tests/`, as CI runs it); a run of single files goes without it.
#
# After the last test it names the ten slowest, in the shape pytest's `--durations=10` prints,
# so a slow test is seen on every run. Each test writes its time (tests/_internal/helpers.bash).

SLOWEST_COUNT=10

setup_suite() { :; }

teardown_suite() {
    local durations="${BATS_RUN_TMPDIR}/durations"
    [ -d "${durations}" ] || return 0
    {
        printf '===== slowest %d durations =====\n' "${SLOWEST_COUNT}"
        cat "${durations}"/* | sort -rn | head -n "${SLOWEST_COUNT}" | sed 's/^\([0-9.]*\) /\1s call /'
    } >&3
}
