#!/bin/zsh
set -u

touch_up_app='/Applications/Touch Up.app'
touch_up_bundle_id='de.schafe.Touch-Up-notarized'
helper_target='/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer'
helper_plist='/Library/LaunchDaemons/com.rofkek.rack-touch-seizer.plist'
helper_label='system/com.rofkek.rack-touch-seizer'
socket_path='/var/run/com.rofkek.rack-touch-seizer.sock'
launcher_label='com.rofkek.touch-up'
user_domain="gui/$(id -u)"
touch_up_log="$HOME/Library/Logs/com.rofkek.touch-up.log"
helper_log='/Library/Logs/com.rofkek.rack-touch-seizer.log'
mqtt_label='com.rofkek.rack-screen-mqtt'
mqtt_support="$HOME/Library/Application Support/$mqtt_label"
mqtt_config="$mqtt_support/config.json"
mqtt_plist="$HOME/Library/LaunchAgents/$mqtt_label.plist"
core_fail=0

pass() { print -- "PASS $*"; }
warn() { print -- "WARN $*"; }
fail() { print -- "FAIL $*"; core_fail=1; }

if [[ "$(uname -s)" != Darwin ]]; then
  fail 'macOS/Darwin required'
  exit "$core_fail"
fi

if [[ -d "$touch_up_app" && -x "$touch_up_app/Contents/MacOS/Touch Up" ]]; then
  if codesign --verify --deep --strict "$touch_up_app" >/dev/null 2>&1; then
    app_details="$(codesign -d --verbose=4 "$touch_up_app" 2>&1)"
    app_authority="$(print -r -- "$app_details" | awk -F= '/^Authority=/{print $2; exit}')"
    if [[ -n "$app_authority" && "$app_authority" != '(unavailable)' ]]; then
      pass "Touch Up strict signature ($app_authority)"
    else
      fail 'Touch Up signature has no stable Authority'
    fi
  else
    fail 'Touch Up strict/deep signature'
    app_authority=''
  fi
  app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$touch_up_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$app_bundle_id" == "$touch_up_bundle_id" ]]; then
    pass "Touch Up bundle ID ($app_bundle_id)"
  else
    fail "Touch Up bundle ID (${app_bundle_id:-<missing>})"
  fi
else
  fail 'Touch Up.app or executable missing'
  app_authority=''
fi

if [[ -x "$helper_target" && -f "$helper_plist" ]]; then
  if codesign --verify --strict "$helper_target" >/dev/null 2>&1; then
    helper_details="$(codesign -d --verbose=4 "$helper_target" 2>&1)"
    helper_authority="$(print -r -- "$helper_details" | awk -F= '/^Authority=/{print $2; exit}')"
    if [[ -n "$app_authority" && "$app_authority" != '(unavailable)' && \
      -n "$helper_authority" && "$helper_authority" != '(unavailable)' && \
      "$helper_authority" == "$app_authority" ]]; then
      pass 'RackTouchSeizer strict signature matches Touch Up'
    else
      fail 'RackTouchSeizer signature does not match Touch Up'
    fi
  else
    fail 'RackTouchSeizer strict signature'
  fi
else
  fail 'RackTouchSeizer binary or LaunchDaemon plist missing'
fi

if launchctl print "$helper_label" >/dev/null 2>&1; then
  pass 'RackTouchSeizer LaunchDaemon loaded'
else
  fail 'RackTouchSeizer LaunchDaemon not loaded'
fi
controller_present=false
if hidutil list 2>/dev/null | grep -Eq '0x27c0[[:space:]]+0x859'; then
  controller_present=true
  pass 'WCH 27c0:0859 controller present'
else
  warn 'WCH 27c0:0859 controller not detected'
fi
if [[ -S "$socket_path" ]]; then
  socket_mode="$(stat -f %Sp "$socket_path" 2>/dev/null || true)"
  socket_owner="$(stat -f %Su "$socket_path" 2>/dev/null || true)"
  if [[ "$socket_mode" == 'srw-------' && "$socket_owner" == "$(id -un)" ]]; then
    pass "RackTouchSeizer readiness socket ($socket_mode $socket_owner)"
  else
    fail "RackTouchSeizer socket permissions ($socket_mode ${socket_owner:-unknown})"
  fi
else
  if [[ "$controller_present" == true ]]; then
    fail 'RackTouchSeizer readiness socket absent (check helper Input Monitoring)'
  else
    warn 'RackTouchSeizer readiness socket absent while controller is disconnected'
  fi
fi

if launchctl print "$user_domain/$launcher_label" >/dev/null 2>&1; then
  pass 'Touch Up delayed LaunchAgent loaded'
else
  fail 'Touch Up delayed LaunchAgent not loaded'
fi
if pgrep -f '/Applications/Touch Up\.app/Contents/MacOS/Touch Up' >/dev/null 2>&1; then
  pass 'Touch Up process running'
else
  warn 'Touch Up process not running'
fi
if [[ -f "$touch_up_log" ]] && grep -Fq 'Connected to privileged rack-touch report bridge.' "$touch_up_log"; then
  pass 'Touch Up report bridge log marker'
else
  warn 'Touch Up report bridge marker not found in recent log'
fi
if [[ -f "$helper_log" ]] && grep -Eq 'exclusive|suppression active|physical reports active' "$helper_log"; then
  pass 'RackTouchSeizer controller log marker'
else
  warn 'RackTouchSeizer controller marker not found in log'
fi

if [[ -f "$mqtt_plist" || -d "$mqtt_support" ]]; then
  if [[ -f "$mqtt_config" ]]; then
    mqtt_mode="$(stat -f %Mp%Lp "$mqtt_config" 2>/dev/null || print -- unknown)"
    if [[ "$mqtt_mode" == 0600 ]]; then
      if grep -Eq '"host"[[:space:]]*:[[:space:]]*"[^"[:space:]]' "$mqtt_config" 2>/dev/null; then
        pass "MQTT config present (mode $mqtt_mode; values hidden)"
      else
        warn "MQTT config present but broker host is not configured (mode $mqtt_mode)"
      fi
    else
      warn "MQTT config present with mode $mqtt_mode (expected 0600)"
    fi
  else
    warn 'MQTT support directory exists without config.json'
  fi
  if launchctl print "$user_domain/$mqtt_label" >/dev/null 2>&1; then
    pass 'MQTT LaunchAgent loaded'
  else
    warn 'MQTT LaunchAgent not loaded/inactive'
  fi
else
  print -- 'INFO MQTT bridge not installed'
fi

exit "$core_fail"
