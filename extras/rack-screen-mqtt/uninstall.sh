#!/bin/bash
set -euo pipefail

LABEL="com.rofkek.rack-screen-mqtt"
APP_SUPPORT="$HOME/Library/Application Support/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/$LABEL"
purge=false
confirmed=false

usage() {
	printf 'Usage: %s [--purge] [--yes]\n' "$0"
	printf '  default: unload and remove the LaunchAgent; preserve app files, logs, and config\n'
	printf '  --purge: also remove %s and %s\n' "$APP_SUPPORT" "$LOG_DIR"
}
for arg in "$@"; do
	case "$arg" in
		--purge) purge=true ;;
		--yes) confirmed=true ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done

uid="$(id -u)"
launchctl bootout "gui/$uid/$LABEL" "$PLIST" >/dev/null 2>&1 || \
	launchctl unload "$PLIST" >/dev/null 2>&1 || true
if [ -f "$PLIST" ]; then
	rm -f "$PLIST"
fi

if [ "$purge" = true ]; then
	if [ "$confirmed" != true ]; then
		printf 'This permanently removes the app support directory, config, venv, and logs.\n'
		printf 'Type PURGE to continue: '
		read -r confirmation
		[ "$confirmation" = PURGE ] || { printf 'Purge cancelled; LaunchAgent removed.\n'; exit 0; }
	fi
	[ -z "$APP_SUPPORT" ] && { printf 'Refusing an empty app-support path.\n' >&2; exit 1; }
	[ -z "$LOG_DIR" ] && { printf 'Refusing an empty log path.\n' >&2; exit 1; }
	rm -rf "$APP_SUPPORT" "$LOG_DIR"
	printf 'Removed app support and logs.\n'
else
	printf 'LaunchAgent removed; preserved app support, config, and logs.\n'
	printf 'To remove those explicitly, rerun with --purge.\n'
fi
