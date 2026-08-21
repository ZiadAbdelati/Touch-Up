#!/bin/bash
set -euo pipefail

LABEL="com.rofkek.rack-screen-mqtt"
APP_SUPPORT="$HOME/Library/Application Support/$LABEL"
CONFIG="$APP_SUPPORT/config.json"
VENV="$APP_SUPPORT/.venv"

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

[ -d "$APP_SUPPORT" ] || die "the service is not installed; run install.sh first"
if [ -x "$VENV/bin/python3" ]; then
	PYTHON="$VENV/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
	PYTHON="$(command -v python3)"
else
	die "python3 is required to write JSON configuration"
fi

existing_host=""
existing_port="1883"
existing_username=""
existing_tls="false"
existing_ca_path=""
if [ -f "$CONFIG" ]; then
	broker_line="$("$PYTHON" - "$CONFIG" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        broker = json.load(stream).get("broker", {})
except (OSError, ValueError, TypeError):
    broker = {}
print(
    str(broker.get("host", "")),
    str(broker.get("port", 1883)),
    str(broker.get("username", "")),
    str(bool(broker.get("tls", False))).lower(),
    str(broker.get("ca_path", "")),
    sep="|",
)
PY
)"
	IFS='|' read -r existing_host existing_port existing_username existing_tls existing_ca_path <<< "$broker_line"
fi

printf 'MQTT broker settings (password input is hidden).\n'
read -r -p "Broker host [$existing_host]: " broker_host
broker_host="${broker_host:-$existing_host}"
[ -n "$broker_host" ] || die "broker host cannot be empty"

read -r -p "Broker port [$existing_port]: " broker_port
broker_port="${broker_port:-$existing_port}"
case "$broker_port" in
	''|*[!0-9]*) die "broker port must be an integer from 1 to 65535" ;;
esac
[ "$broker_port" -ge 1 ] && [ "$broker_port" -le 65535 ] || die "broker port must be from 1 to 65535"

read -r -p "Broker username [${existing_username:+configured; leave blank to keep}]: " broker_username
broker_username="${broker_username:-$existing_username}"
read -r -s -p "Broker password [leave blank to keep current]: " broker_password
printf '\n'
password_changed=0
if [ -n "$broker_password" ]; then
	password_changed=1
fi

tls_default="$existing_tls"
read -r -p "Use TLS (true/false) [$tls_default]: " tls_value
tls_value="${tls_value:-$tls_default}"
tls_value="$(printf '%s' "$tls_value" | tr '[:upper:]' '[:lower:]')"
case "$tls_value" in
	true|yes|y|1) tls_value=true ;;
	false|no|n|0) tls_value=false ;;
	*) die "TLS must be true or false" ;;
esac

read -r -p "CA certificate path [${existing_ca_path:-none}]: " ca_path
ca_path="${ca_path:-$existing_ca_path}"
if [ "$tls_value" = true ] && [ -n "$ca_path" ] && [ ! -f "$ca_path" ]; then
	die "CA certificate does not exist: $ca_path"
fi

umask 077
tmp_config="$(mktemp "$APP_SUPPORT/config.json.tmp.XXXXXX")"
cleanup() {
	rm -f "$tmp_config"
}
trap cleanup EXIT HUP INT TERM

BROKER_HOST="$broker_host" BROKER_PORT="$broker_port" BROKER_USERNAME="$broker_username" \
BROKER_TLS="$tls_value" BROKER_CA_PATH="$ca_path" BROKER_PASSWORD="$broker_password" \
BROKER_PASSWORD_CHANGED="$password_changed" \
"$PYTHON" - "$CONFIG" "$tmp_config" <<'PY'
import json
import os
import pathlib
import sys

config_path, output_path = sys.argv[1:]
current = {}
try:
    with open(config_path, encoding="utf-8") as stream:
        current = json.load(stream)
except (OSError, ValueError, TypeError):
    current = {}
broker = current.get("broker") if isinstance(current.get("broker"), dict) else {}
password = os.environ.get("BROKER_PASSWORD", "")
if os.environ.get("BROKER_PASSWORD_CHANGED") != "1":
    password = broker.get("password", "")
new_config = current if isinstance(current, dict) else {}
new_config["broker"] = {
    "host": os.environ["BROKER_HOST"],
    "port": int(os.environ["BROKER_PORT"]),
    "username": os.environ["BROKER_USERNAME"],
    "password": password,
    "tls": os.environ["BROKER_TLS"] == "true",
    "ca_path": os.environ.get("BROKER_CA_PATH", ""),
}
new_config.setdefault("ddc", {"path": "/usr/local/bin/ddcctl"})
new_config.setdefault("poll_seconds", 60)
pathlib.Path(output_path).write_text(json.dumps(new_config, indent=2) + "\n", encoding="utf-8")
PY
chmod 600 "$tmp_config"
mv -f "$tmp_config" "$CONFIG"
trap - EXIT HUP INT TERM

printf 'Configuration saved with mode 600: %s\n' "$CONFIG"
printf 'The service remains stopped. Run %s/start.sh after the DDC adapter is ready.\n' "$APP_SUPPORT"
