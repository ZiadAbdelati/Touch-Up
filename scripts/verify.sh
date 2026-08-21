#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
build_dir="$repo_root/build/verify"
module_cache="${TMPDIR:-/tmp}/rack-touch-clang-cache"

mkdir -p "$build_dir" "$module_cache"

"$repo_root/RackTouchSeizer/build.sh" "$build_dir/helper"

common=(
  -arch x86_64
  -mmacosx-version-min=11.0
  -O2
  -fmodules
  -fmodules-cache-path="$module_cache"
  -fblocks
  -I"$repo_root"
)

xcrun clang "${common[@]}" -std=gnu11 \
  -c "$repo_root/TouchUpCore/HIDInterpreter.c" \
  -o "$build_dir/HIDInterpreter.o"

objc_sources=(Touch TUCTouch TUCScreen TUCCursorUtilities TUCTouchInputManager)
for source_name in "${objc_sources[@]}"; do
  xcrun clang "${common[@]}" -fobjc-arc \
    -c "$repo_root/TouchUpCore/$source_name.m" \
    -o "$build_dir/$source_name.o"
done

xcrun clang -arch x86_64 -mmacosx-version-min=11.0 -dynamiclib \
  "$build_dir/Touch.o" \
  "$build_dir/TUCTouch.o" \
  "$build_dir/TUCScreen.o" \
  "$build_dir/TUCCursorUtilities.o" \
  "$build_dir/TUCTouchInputManager.o" \
  "$build_dir/HIDInterpreter.o" \
  -framework Foundation \
  -framework AppKit \
  -framework CoreGraphics \
  -framework IOKit \
  -framework ColorSync \
  -install_name '@rpath/TouchUpCore.framework/Versions/A/TouchUpCore' \
  -o "$build_dir/TouchUpCore"

for shell_script in "$repo_root"/RackTouchSeizer/*.sh; do
  zsh -n "$shell_script"
done
for shell_script in "$repo_root"/extras/rack-screen-mqtt/*.sh; do
  bash -n "$shell_script"
done

plutil -lint \
  "$repo_root/RackTouchSeizer/com.rofkek.rack-touch-seizer.plist" \
  "$repo_root/extras/rack-screen-mqtt/com.rofkek.rack-screen-mqtt.plist.template"

if python3 -c 'import pytest' >/dev/null 2>&1; then
  (cd "$repo_root/extras/rack-screen-mqtt" && python3 -m pytest tests -q)
else
  echo 'pytest is not installed; skipped MQTT unit tests (see requirements-dev.txt).'
fi

(cd "$repo_root" && git diff --check)
echo 'Source verification passed.'
