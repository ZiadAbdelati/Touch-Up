#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
build_dir="$repo_root/build/calibrator"
output_csv=/tmp/rack-touch-calibration.csv
touch_up_was_running=false

if [[ ! -S /var/run/com.rofkek.rack-touch-seizer.sock ]]; then
  print -u2 'Calibration requires the optional RackTouchSeizer report socket.'
  print -u2 'Install/start the legacy helper temporarily, calibrate, then uninstall it before reopening Touch Up.'
  exit 1
fi

if pgrep -x 'Touch Up' >/dev/null; then
  touch_up_was_running=true
  osascript -e 'tell application "Touch Up" to quit' >/dev/null 2>&1 || true
  for _ in {1..30}; do
    pgrep -x 'Touch Up' >/dev/null || break
    sleep 0.1
  done
fi

restore_touch_up() {
  if $touch_up_was_running; then
    open -a 'Touch Up'
  fi
}
trap restore_touch_up EXIT

mkdir -p "$build_dir"
rm -f "$output_csv"
xcrun clang -arch x86_64 -mmacosx-version-min=11.0 -fobjc-arc -fblocks \
  -I"$repo_root" \
  "$script_dir/RackTouchCalibrator.m" \
  -framework Cocoa \
  -lpthread \
  -o "$build_dir/RackTouchCalibrator"

echo 'Tap and briefly hold each red crosshair on RTK FHD until it advances.'
echo 'Touch Up is paused for exclusive capture and will reopen afterward.'
"$build_dir/RackTouchCalibrator"
python3 "$script_dir/fit_calibration.py" "$output_csv"
