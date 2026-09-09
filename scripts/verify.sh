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
for shell_script in "$repo_root"/extras/touch-up-launcher/*.sh; do
  zsh -n "$shell_script"
done
for shell_script in "$repo_root"/extras/rack-screen-suite/*.sh; do
  zsh -n "$shell_script"
done

plutil -lint \
  "$repo_root/RackTouchSeizer/com.rofkek.rack-touch-seizer.plist" \
  "$repo_root/extras/rack-screen-mqtt/com.rofkek.rack-screen-mqtt.plist.template" \
  "$repo_root/extras/touch-up-launcher/com.rofkek.touch-up.plist.template"

if grep -q 'CreateDeviceMatchingDictionary(kHIDPage_GenericDesktop' \
    "$repo_root/TouchUpCore/HIDInterpreter.c"; then
  echo 'Touch Up must not match the mouse sibling in helper-first mode.' >&2
  exit 1
fi
grep -q '/var/run/com.rofkek.rack-touch-seizer.sock' \
  "$repo_root/extras/touch-up-launcher/start.sh"
grep -q 'stat -f %u' "$repo_root/extras/touch-up-launcher/start.sh"
grep -q 'stat -f %Sp' "$repo_root/extras/touch-up-launcher/start.sh"

python3 - "$repo_root/RackTouchSeizer/RackTouchSeizer.c" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
exclusive_open = source.index(
    "IOHIDManagerOpen(gManager, kIOHIDOptionsTypeSeizeDevice)"
)
ready_socket = source.index("if (StartReportServer() != 0)", exclusive_open)
if ready_socket < exclusive_open:
    raise SystemExit("helper readiness socket is created before exclusive HID open")
if "consoleInfo->st_uid < 501" not in source:
    raise SystemExit("helper can publish its socket for an early-boot service account")
if "account->pw_name[0] == '_'" not in source:
    raise SystemExit("helper does not reject underscore-prefixed service accounts")
if "ReplaceClient(-1);" not in source:
    raise SystemExit("helper removal does not reset the active report client")
PY

grep -q 'Rack digitizer watchdog cancelled a stale multitouch contact' \
  "$repo_root/TouchUpCore/HIDInterpreter.c"
grep -q 'RackPreferredRestoreScreen' \
  "$repo_root/TouchUpCore/TUCTouchInputManager.m"
grep -q 'RackForceCursorRestore(self)' \
  "$repo_root/TouchUpCore/TUCTouchInputManager.m"

if python3 -c 'import pytest' >/dev/null 2>&1; then
  (cd "$repo_root/extras/rack-screen-mqtt" && python3 -m pytest tests -q)
else
  echo 'pytest is not installed; skipped MQTT unit tests (see requirements-dev.txt).'
fi

(cd "$repo_root" && git diff --check)
echo 'Source verification passed.'
