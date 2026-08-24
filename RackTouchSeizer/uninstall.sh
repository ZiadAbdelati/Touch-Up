#!/bin/zsh
set -euo pipefail

plist_target='/Library/LaunchDaemons/com.rofkek.rack-touch-seizer.plist'
helper_target='/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer'
socket_target='/var/run/com.rofkek.rack-touch-seizer.sock'

echo 'Removing the GeekPi touchscreen mouse-suppression helper.'
sudo -v
sudo launchctl bootout system "$plist_target" 2>/dev/null || true
sudo rm -f "$plist_target" "$helper_target" "$socket_target"
echo 'Removed. The log remains at /Library/Logs/com.rofkek.rack-touch-seizer.log.'
