#!/bin/bash
set -euo pipefail

LABEL="com.rofkek.rack-screen-mqtt"
SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
APP_SUPPORT="$HOME/Library/Application Support/$LABEL"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/$LABEL"
CONFIG="$APP_SUPPORT/config.json"
VENV="$APP_SUPPORT/.venv"
SCRIPT="$APP_SUPPORT/rack_screen_mqtt.py"
PREFLIGHT="$APP_SUPPORT/preflight.py"
CONFIGURE="$APP_SUPPORT/configure.sh"
START="$APP_SUPPORT/start.sh"
REQUIREMENTS="$APP_SUPPORT/requirements.txt"
TEMPLATE="$SOURCE_DIR/$LABEL.plist.template"

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

check_ddcctl() {
	if command -v ddcctl >/dev/null 2>&1; then
		printf 'Found ddcctl at %s\n' "$(command -v ddcctl)"
		return 0
	fi
	cat >&2 <<'EOF'
ddcctl is required but was not found on PATH.
Install it separately (for example, with `brew install ddcctl`), then run
this installer again. The installer never installs ddcctl automatically.
EOF
	return 1
}

find_brew_python() {
	local brew_python=""
	if command -v brew >/dev/null 2>&1; then
		brew_python="$(brew --prefix python@3.13 2>/dev/null || true)/bin/python3.13"
		if [ -x "$brew_python" ]; then
			printf '%s\n' "$brew_python"
			return 0
		fi
	fi
	for brew_python in /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 \
		/opt/homebrew/bin/python3 /usr/local/bin/python3; do
		if [ -x "$brew_python" ]; then
			printf '%s\n' "$brew_python"
			return 0
		fi
	done
	return 1
}

render_plist() {
	local python="$1"
	"$python" - "$TEMPLATE" "$PLIST" "$VENV/bin/python3" "$SCRIPT" "$CONFIG" \
		"$LOG_DIR/$LABEL.out.log" "$LOG_DIR/$LABEL.err.log" "$LABEL" <<'PY'
import html
import pathlib
import sys

template_path, output_path, python_path, script_path, config_path, stdout_path, stderr_path, label = sys.argv[1:]
values = {
    "__PYTHON__": python_path,
    "__SCRIPT__": script_path,
    "__CONFIG__": config_path,
    "__STDOUT__": stdout_path,
    "__STDERR__": stderr_path,
    "__LABEL__": label,
}
text = pathlib.Path(template_path).read_text(encoding="utf-8")
for token, value in values.items():
    text = text.replace(token, html.escape(value, quote=False))
if "__" in text:
    raise SystemExit("plist template contains an unresolved placeholder")
pathlib.Path(output_path).write_text(text, encoding="utf-8")
PY
	chmod 600 "$PLIST"
}

[ "$(uname -s)" = "Darwin" ] || die "this installer targets macOS (Darwin)"
[ -f "$SOURCE_DIR/rack_screen_mqtt.py" ] || die "rack_screen_mqtt.py is missing from $SOURCE_DIR"
[ -f "$SOURCE_DIR/preflight.py" ] || die "preflight.py is missing from $SOURCE_DIR"
[ -f "$SOURCE_DIR/configure.sh" ] || die "configure.sh is missing from $SOURCE_DIR"
[ -f "$SOURCE_DIR/start.sh" ] || die "start.sh is missing from $SOURCE_DIR"
[ -f "$SOURCE_DIR/requirements.txt" ] || die "requirements.txt is missing from $SOURCE_DIR"
[ -f "$SOURCE_DIR/$LABEL.plist.template" ] || die "LaunchAgent template is missing"
check_ddcctl || exit 1

PYTHON="$(find_brew_python)" || die "Homebrew python3 was not found. Install Homebrew Python, then retry."
printf 'Using Homebrew Python: %s\n' "$PYTHON"

mkdir -p "$APP_SUPPORT" "$LAUNCH_AGENTS" "$LOG_DIR"
chmod 700 "$APP_SUPPORT" "$LOG_DIR"
install -m 755 "$SOURCE_DIR/rack_screen_mqtt.py" "$SCRIPT"
install -m 755 "$SOURCE_DIR/preflight.py" "$PREFLIGHT"
install -m 755 "$SOURCE_DIR/configure.sh" "$CONFIGURE"
install -m 755 "$SOURCE_DIR/start.sh" "$START"
install -m 644 "$SOURCE_DIR/requirements.txt" "$REQUIREMENTS"
if [ ! -e "$CONFIG" ]; then
	install -m 600 "$SOURCE_DIR/config.example.json" "$CONFIG"
else
	chmod 600 "$CONFIG"
	printf 'Preserving existing configuration: %s\n' "$CONFIG"
fi

if [ ! -x "$VENV/bin/python3" ]; then
	"$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python3" -m pip install --requirement "$REQUIREMENTS"
render_plist "$PYTHON"

# Installation is deliberately inert. configure.sh stores credentials, and
# start.sh refuses to load the LaunchAgent until DDC read/write/readback passes.
uid="$(id -u)"
launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true

printf '\nInstalled %s in an inactive state.\n' "$LABEL"
printf 'Configure MQTT credentials with: %s\n' "$CONFIGURE"
printf 'Then validate DDC and start with: %s\n' "$START"
printf 'Logs: %s\n' "$LOG_DIR"
