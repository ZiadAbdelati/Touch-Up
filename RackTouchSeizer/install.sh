#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_dir="$script_dir/../build/rack-touch-seizer"
helper_target='/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer'
plist_target='/Library/LaunchDaemons/com.rofkek.rack-touch-seizer.plist'
label='system/com.rofkek.rack-touch-seizer'
touch_up_app='/Applications/Touch Up.app'

if [[ -z "${RACK_TOUCH_CODE_SIGN_IDENTITY:-}" ]]; then
  if [[ ! -d "$touch_up_app" ]]; then
    print -u2 "Touch Up is not installed at $touch_up_app"
    print -u2 'Set RACK_TOUCH_CODE_SIGN_IDENTITY explicitly or install the signed app first.'
    exit 1
  fi
  codesign --verify --deep --strict "$touch_up_app"
  signature_details=$(codesign -d --verbose=4 "$touch_up_app" 2>&1)
  RACK_TOUCH_CODE_SIGN_IDENTITY=$(print -r -- "$signature_details" |
    awk -F= '/^Authority=/{sub(/^[^=]*=/, ""); print; exit}')
  if [[ -z "$RACK_TOUCH_CODE_SIGN_IDENTITY" ]]; then
    print -u2 'Unable to derive a stable signing identity from Touch Up.'
    exit 1
  fi
fi

if [[ "$RACK_TOUCH_CODE_SIGN_IDENTITY" == '-' ]]; then
  print -u2 'The installed helper must use a stable signing identity, not an ad-hoc signature.'
  exit 1
fi
if ! security find-identity -v -p codesigning |
    grep -Fq "\"$RACK_TOUCH_CODE_SIGN_IDENTITY\""; then
  print -u2 "Signing identity is not available in the login keychain: $RACK_TOUCH_CODE_SIGN_IDENTITY"
  exit 1
fi
export RACK_TOUCH_CODE_SIGN_IDENTITY

echo 'Installing the GeekPi touchscreen mouse-suppression helper.'
echo "Signing identity: $RACK_TOUCH_CODE_SIGN_IDENTITY"
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
echo 'Installed and started.'
sleep 2
if [[ -S /var/run/com.rofkek.rack-touch-seizer.sock ]]; then
  echo 'Helper readiness socket is active.'
else
  echo 'The helper is waiting for Input Monitoring permission.'
  echo 'Add and enable this exact signed binary in System Settings → Privacy & Security → Input Monitoring:'
  echo "  $helper_target"
  echo 'The LaunchDaemon will retry automatically after permission is granted.'
fi
