#!/bin/zsh
set -euo pipefail

launch_agent="$HOME/Library/LaunchAgents/com.rofkek.touch-up.plist"
support_dir="$HOME/Library/Application Support/com.rofkek.touch-up"
user_domain="gui/$(id -u)"

launchctl bootout "$user_domain/com.rofkek.touch-up" >/dev/null 2>&1 || true
rm -f "$launch_agent" "$support_dir/start.sh" \
  "$support_dir/com.rofkek.touch-up.plist"
rmdir "$support_dir" >/dev/null 2>&1 || true

echo 'Removed the delayed Touch Up launcher.'
