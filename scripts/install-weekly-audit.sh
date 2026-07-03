#!/usr/bin/env bash
# =============================================================================
# install-weekly-audit — register the weekly audit as a launchd agent (macOS)
# =============================================================================
# Generates ~/Library/LaunchAgents/com.guard-dispatcher.weekly-audit.plist
# pointing at this checkout's weekly-audit.sh, scheduled for Sunday 00:00
# local time, then loads it. Idempotent: re-running replaces the agent and
# re-points it at the checkout you ran it from.
#
# Prerequisite: $HOME/.config/guard-dispatcher/weekly-audit.conf must exist
# (see weekly-audit.sh header) — the installer refuses to register a job
# that would only ever exit with a config error.
#
# Uninstall:
#   launchctl bootout "gui/$(id -u)/com.guard-dispatcher.weekly-audit"
#   rm ~/Library/LaunchAgents/com.guard-dispatcher.weekly-audit.plist
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.guard-dispatcher.weekly-audit"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
STATE_DIR="${HOME}/.local/state/guard-dispatcher"
CONF="${HOME}/.config/guard-dispatcher/weekly-audit.conf"

if [ ! -f "${CONF}" ]; then
    echo "error: create ${CONF} first (see weekly-audit.sh header for the format)" >&2
    exit 2
fi

mkdir -p "${STATE_DIR}" "${HOME}/Library/LaunchAgents"

cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/weekly-audit.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${HOME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>0</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${STATE_DIR}/launchd-weekly-audit.out.log</string>
    <key>StandardErrorPath</key>
    <string>${STATE_DIR}/launchd-weekly-audit.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "${PLIST}"

# Replace any prior registration, then load fresh.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST}"

echo "[weekly-audit] registered: ${LABEL}"
echo "  schedule : Sunday 00:00 local time (Saturday midnight)"
echo "  script   : ${SCRIPT_DIR}/weekly-audit.sh"
echo "  logs     : ${STATE_DIR}/"
echo "  verify   : launchctl print gui/\$(id -u)/${LABEL} | head -20"
