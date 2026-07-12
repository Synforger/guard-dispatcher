#!/bin/bash
set -eu

# staledocs-check.sh — code<->docs coherence gate (`task docs:coherence`).
#
# Runs `staledocs check` against the repo's .staledocs.yaml. The config's
# `gate` key decides severity: warn = report only, strict = non-zero exit
# on red findings. Self-installs the CLI when missing so a bare `task ci`
# works on fresh CI runners without a dedicated setup step.
#
# Exit code:
#   0 = clean (or warn-gate report)
#   1 = red findings under a strict gate, or missing config

if ! command -v staledocs >/dev/null 2>&1; then
    # Dedicated cached venv: immune to PEP 668 (externally-managed pythons
    # refuse --user installs) and shared across repos on the same machine.
    venv="${XDG_CACHE_HOME:-${HOME}/.cache}/staledocs/venv"
    if [ ! -x "${venv}/bin/staledocs" ]; then
        echo "staledocs-check: staledocs CLI not found; bootstrapping ${venv}"
        python3 -m venv "${venv}"
    fi
    # keep the cached copy current — a stale venv must not pin old behaviour
    "${venv}/bin/pip" install --quiet --upgrade staledocs
    PATH="${venv}/bin:${PATH}"
    export PATH
fi

if [ ! -f .staledocs.yaml ]; then
    echo "staledocs-check: .staledocs.yaml missing at the repo root" >&2
    echo "                 run 'staledocs init' or copy the template config" >&2
    exit 1
fi

exec staledocs check
