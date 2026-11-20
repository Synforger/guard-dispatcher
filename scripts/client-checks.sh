#!/usr/bin/env bash
# Print one line per judgement of the guard missing from the client's configuration, and exit 1 when
# there is one (a platform's start-up check runs it). Reads only.
#
# Usage: scripts/client-checks.sh --root <platform root>
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_internal/client_checks.py" "$@"
