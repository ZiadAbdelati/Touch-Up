#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
support_dir="$HOME/Library/Application Support/com.rofkek.touch-up"
start_target="$support_dir/start.sh"
launch_agent="$HOME/Library/LaunchAgents/com.rofkek.touch-up.plist"
staged_plist="$support_dir/com.rofkek.touch-up.plist"
user_domain="gui/$(id -u)"

mkdir -p "$support_dir" "$HOME/Library/LaunchAgents"
install -m 755 "$script_dir/start.sh" "$start_target"

escaped_start=${start_target//&/\\&}
escaped_start=${escaped_start//|/\\|}
sed "s|__START_SCRIPT__|$escaped_start|g" \
  "$script_dir/com.rofkek.touch-up.plist.template" > "$staged_plist"
plutil -lint "$staged_plist"
install -m 644 "$staged_plist" "$launch_agent"

launchctl bootout "$user_domain/com.rofkek.touch-up" >/dev/null 2>&1 || true
osascript -e 'tell application id "de.schafe.Touch-Up-notarized" to quit' \
  >/dev/null 2>&1 || true
launchctl bootstrap "$user_domain" "$launch_agent"
launchctl enable "$user_domain/com.rofkek.touch-up"

echo "Installed delayed Touch Up launcher: $launch_agent"
echo 'Touch Up will start after a 15-second login delay, wait for the helper readiness socket, and restart after a failed exit.'
