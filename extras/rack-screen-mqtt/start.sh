#!/bin/bash
set -euo pipefail

LABEL="com.rofkek.rack-screen-mqtt"
APP_SUPPORT="$HOME/Library/Application Support/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="$APP_SUPPORT/config.json"
PYTHON="$APP_SUPPORT/.venv/bin/python3"

[ -x "$PYTHON" ] || { printf 'Service is not installed; run install.sh first.\n' >&2; exit 1; }
[ -f "$CONFIG" ] || { printf 'Configuration is missing; run configure.sh first.\n' >&2; exit 1; }
[ -f "$PLIST" ] || { printf 'LaunchAgent is missing; run install.sh first.\n' >&2; exit 1; }

"$PYTHON" "$APP_SUPPORT/preflight.py" --config "$CONFIG" --exercise

uid="$(id -u)"
launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$PLIST"
launchctl enable "gui/$uid/$LABEL" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$uid/$LABEL"
printf 'Started %s after a successful DDC exercise.\n' "$LABEL"
