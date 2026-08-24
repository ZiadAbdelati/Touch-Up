#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
touch_up_app='/Applications/Touch Up.app'
touch_up_bundle_id='de.schafe.Touch-Up-notarized'
helper_target='/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer'
socket_path='/var/run/com.rofkek.rack-touch-seizer.sock'
launcher_label='com.rofkek.touch-up'
user_domain="gui/$(id -u)"
with_mqtt=false

die() {
  print -u2 -- "Error: $*"
  exit 1
}

usage() {
  print -- "Usage: $0 [--with-mqtt]"
  print -- '  Installs the signed Touch Up runtime and privileged rack helper.'
  print -- '  --with-mqtt  also install the optional inactive MQTT/DDC bridge.'
}

for arg in "$@"; do
  case "$arg" in
    --with-mqtt) with_mqtt=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || die 'this installer targets macOS (Darwin)'
[[ -d "$touch_up_app" ]] || die "missing application bundle: $touch_up_app"
[[ -x "$touch_up_app/Contents/MacOS/Touch Up" ]] || die 'Touch Up executable is missing or not executable'
[[ -x "$repo_root/RackTouchSeizer/install.sh" ]] || die 'RackTouchSeizer installer is missing'
[[ -x "$repo_root/extras/touch-up-launcher/install.sh" ]] || die 'Touch Up launcher installer is missing'

signature_error=''
if ! signature_error="$(codesign --verify --deep --strict --verbose=2 "$touch_up_app" 2>&1)"; then
  print -u2 -- "$signature_error"
  die 'Touch Up has no valid strict/deep code signature'
fi
signature_details="$(codesign -d --verbose=4 "$touch_up_app" 2>&1)"
app_authority="$(print -r -- "$signature_details" | awk -F= '/^Authority=/{print $2; exit}')"
[[ -n "$app_authority" && "$app_authority" != '(unavailable)' ]] || \
  die 'Touch Up signature has no usable Authority; install a stable locally signed app first'

app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$touch_up_app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$app_bundle_id" == "$touch_up_bundle_id" ]] || \
  die "unexpected Touch Up bundle identifier: ${app_bundle_id:-<missing>} (expected $touch_up_bundle_id)"

identity_list="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! print -r -- "$identity_list" | awk -F'"' -v wanted="$app_authority" \
  '$2 == wanted { found = 1 } END { exit(found ? 0 : 1) }'; then
  die "the app signing Authority is not a valid local codesigning identity: $app_authority"
fi

print -- "Validated $touch_up_app"
print -- "  Bundle ID: $app_bundle_id"
print -- "  Signing identity: $app_authority"

# A running user app can win exclusive ownership before the newly installed
# system helper. Stop it first; the helper-gated launcher is installed last.
launchctl bootout "$user_domain/$launcher_label" >/dev/null 2>&1 || true
osascript -e 'tell application id "de.schafe.Touch-Up-notarized" to quit' \
  >/dev/null 2>&1 || true

# RackTouchSeizer/build.sh consumes this environment variable. Keeping the
# export in the suite makes the helper use the same leaf identity as the app.
export RACK_TOUCH_CODE_SIGN_IDENTITY="$app_authority"
print --
print -- 'Installing RackTouchSeizer first so it owns the WCH mouse interface before Touch Up starts.'
"$repo_root/RackTouchSeizer/install.sh"

helper_error=''
if ! helper_error="$(codesign --verify --strict --verbose=2 "$helper_target" 2>&1)"; then
  print -u2 -- "$helper_error"
  die 'installed RackTouchSeizer is not strictly signed'
fi
helper_details="$(codesign -d --verbose=4 "$helper_target" 2>&1)"
helper_authority="$(print -r -- "$helper_details" | awk -F= '/^Authority=/{print $2; exit}')"
[[ "$helper_authority" == "$app_authority" ]] || \
  die "RackTouchSeizer identity does not match Touch Up ($helper_authority)"

print --
print -- 'Installing the per-user delayed launcher.'
"$repo_root/extras/touch-up-launcher/install.sh"

if [[ "$with_mqtt" == true ]]; then
  print --
  print -- 'Installing optional MQTT/DDC bridge (its existing configuration is preserved).'
  "$repo_root/extras/rack-screen-mqtt/install.sh"
fi

print
print -- 'Touch runtime installed.'
print -- 'First install privacy steps (System Settings > Privacy & Security):'
print -- '  1. Accessibility: enable Touch Up.'
print -- '  2. Input Monitoring: enable Touch Up.'
print -- '  3. Input Monitoring: enable RackTouchSeizer / the installed helper at:'
print -- "     $helper_target"
print -- 'Log out/in or restart the affected apps after changing privacy grants.'
print -- "Run $script_dir/status.sh for read-only health checks."
print -- "The helper socket is created only after exclusive WCH mouse capture succeeds: $socket_path"
