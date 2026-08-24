#!/bin/zsh
set -euo pipefail

# Login can complete before WindowServer has published the final display list,
# before the USB touchscreen interfaces settle, or before TCC/keychain services
# can resolve the app's code requirement. Starting immediately can therefore
# leave a running menu-bar app that never acquired the usable rack mapping.
delay_seconds=${TOUCH_UP_START_DELAY_SECONDS:-15}
sleep "$delay_seconds"

touch_up_app='/Applications/Touch Up.app'
touch_up_executable="$touch_up_app/Contents/MacOS/Touch Up"
if [[ ! -x "$touch_up_executable" ]]; then
  print -u2 "Touch Up executable not found: $touch_up_executable"
  exit 1
fi

log_dir="$HOME/Library/Logs"
log_file="$log_dir/com.rofkek.touch-up.log"
mkdir -p "$log_dir"
if [[ -f "$log_file" && $(stat -f %z "$log_file") -ge 1048576 ]]; then
  mv -f "$log_file" "$log_file.1"
fi

helper_socket='/var/run/com.rofkek.rack-touch-seizer.sock'
helper_timeout=${RACK_TOUCH_HELPER_TIMEOUT_SECONDS:-90}
expected_socket_uid=$(id -u)
if [[ "$helper_timeout" != <-> ]]; then
  print -u2 "Invalid RACK_TOUCH_HELPER_TIMEOUT_SECONDS: $helper_timeout"
  exit 1
fi

helper_ready() {
  [[ -S "$helper_socket" ]] || return 1
  [[ "$(stat -f %u "$helper_socket" 2>/dev/null)" == "$expected_socket_uid" ]] || return 1
  [[ "$(stat -f %Sp "$helper_socket" 2>/dev/null)" == 'srw-------' ]]
}

# The helper creates its socket only after it has successfully opened the WCH
# mouse interface exclusively. Waiting on that readiness gate prevents Touch Up
# from winning the login race and starving the helper of physical reports.
deadline=$((SECONDS + helper_timeout))
while ! helper_ready && (( SECONDS < deadline )); do
  sleep 1
done
if ! helper_ready; then
  message="Rack touch helper did not publish a socket for uid ${expected_socket_uid} after ${helper_timeout}s: $helper_socket"
  print -r -- "$message" >> "$log_file"
  print -u2 -r -- "$message"
  exit 1
fi

# LaunchServices assigns TCC responsibility to the signed application bundle.
# Directly exec'ing the binary from this unsigned wrapper makes macOS attribute
# Input Monitoring to the wrapper and deny HID access after login.
exec /usr/bin/open -W -g -o "$log_file" --stderr "$log_file" "$touch_up_app"
