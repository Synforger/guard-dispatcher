#!/usr/bin/env bash
# =============================================================================
# seatbelt-exec.sh — sandbox-exec, with the cage's extra Seatbelt rules appended to the profile
# =============================================================================
#   seatbelt-exec.sh <rule>... -- -p <profile> <command...>
#
# run.mjs puts this in place of /usr/bin/sandbox-exec in the command sandbox-runtime builds, for
# the rules sandbox-runtime has no setting for (cage-config.py's `seatbelt`). The shell hands the
# profile over as one argument, so nothing is parsed out of the quoted command. The rules go at
# the end of the profile: the last rule that matches an operation decides it.
# =============================================================================
set -uo pipefail

rules=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    rules+=("$1")
    shift
done
if [ "$#" -lt 3 ] || [ "$2" != "-p" ]; then
    echo "seatbelt-exec: expected <rule>... -- -p <profile> <command...>" >&2
    exit 2
fi
profile="$3"
shift 3
for rule in ${rules[@]+"${rules[@]}"}; do
    profile="${profile}
${rule}"
done
exec /usr/bin/sandbox-exec -p "${profile}" "$@"
