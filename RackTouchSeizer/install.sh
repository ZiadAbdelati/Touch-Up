#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_dir="$script_dir/../build/rack-touch-seizer"
helper_target='/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer'
plist_target='/Library/LaunchDaemons/com.rofkek.rack-touch-seizer.plist'
label='system/com.rofkek.rack-touch-seizer'

echo 'Installing the GeekPi touchscreen mouse-suppression helper.'
echo 'macOS will ask for your administrator password.'
"$script_dir/build.sh" "$build_dir"
sudo -v

sudo launchctl bootout system "$plist_target" 2>/dev/null || true
sudo mkdir -p /Library/PrivilegedHelperTools
sudo chown root:wheel /Library/PrivilegedHelperTools
sudo chmod 755 /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$build_dir/rack-touch-seizer" "$helper_target"
sudo install -o root -g wheel -m 644 "$script_dir/com.rofkek.rack-touch-seizer.plist" "$plist_target"
sudo touch /Library/Logs/com.rofkek.rack-touch-seizer.log
sudo chown root:wheel /Library/Logs/com.rofkek.rack-touch-seizer.log
sudo chmod 644 /Library/Logs/com.rofkek.rack-touch-seizer.log
sudo launchctl bootstrap system "$plist_target"
sudo launchctl enable "$label"
sudo launchctl kickstart -k "$label"

echo
echo 'Installed and started. You can close this window.'
