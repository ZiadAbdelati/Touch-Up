#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
with_mqtt=false
touch_up_bundle_id='de.schafe.Touch-Up-notarized'

usage() {
  print -- "Usage: $0 [--with-mqtt]"
  print -- '  Removes Touch Up runtime components but leaves the application bundle.'
  print -- '  --with-mqtt  also remove the MQTT LaunchAgent, preserving its config.'
}

for arg in "$@"; do
  case "$arg" in
    --with-mqtt) with_mqtt=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || {
  print -u2 -- 'Error: this uninstaller targets macOS (Darwin)'
  exit 1
}

# Stop the app before unloading the owner of the report socket. This prevents
# a stale client from surviving a helper restart and keeps uninstall recoverable.
osascript -e "tell application id \"$touch_up_bundle_id\" to quit" >/dev/null 2>&1 || true
"$repo_root/extras/touch-up-launcher/uninstall.sh"
"$repo_root/RackTouchSeizer/uninstall.sh"

if [[ "$with_mqtt" == true ]]; then
  "$repo_root/extras/rack-screen-mqtt/uninstall.sh"
fi

print
print -- 'Touch runtime removed; /Applications/Touch Up.app was left in place.'
print -- 'The RackTouchSeizer log remains at /Library/Logs/com.rofkek.rack-touch-seizer.log.'
if [[ "$with_mqtt" == true ]]; then
  print -- 'MQTT app support, credentials, and logs were preserved by the component uninstaller.'
fi
