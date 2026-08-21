# Rack screen setup and verification

## Prerequisites

- Intel macOS/Hackintosh target (`x86_64` tested)
- GeekPi/DeskPi controller reporting USB VID/PID `27c0:0859`
- `RTK FHD` rack display at 1280×400 logical resolution
- Xcode or Command Line Tools; Xcode is required to build the full app
- Administrator access for the HID helper

## Install

Build the Touch Up app from `Touch Up.xcodeproj`, copy the product to
`/Applications`, and then run:

```sh
./RackTouchSeizer/install.sh
```

The helper installer builds from source and installs:

- `/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer`
- `/Library/LaunchDaemons/com.rofkek.rack-touch-seizer.plist`
- `/Library/Logs/com.rofkek.rack-touch-seizer.log`

Grant Touch Up under both **System Settings → Privacy & Security →
Accessibility** and **Input Monitoring**, then quit and reopen the app. In Touch
Up settings, map the detected touchscreen to `RTK FHD`.

## Acceptance tests

1. Park the mouse cursor on the JetKVM display.
2. Tap controls near all four edges of the rack dashboard; the touched controls
   should activate without revealing Safari's toolbar or the macOS menu bar.
3. Drag a Home Assistant slider. The cursor should remain hidden and return to
   JetKVM after release.
4. Drag beyond the edge of a slider popup and release. The value should change,
   but the release should not dismiss the popup.
5. Unplug/replug the touch USB connection and repeat tap/drag.
6. Restart the helper and the app independently and repeat.
7. Reboot and verify the helper, app Login Item, mapping, and cursor restoration.

Pinch is not an acceptance criterion because this controller did not emit
multitouch frames during testing.

## Diagnostics

```sh
sudo launchctl print system/com.rofkek.rack-touch-seizer
ps aux | grep '[r]ack-touch-seizer'
ls -l /var/run/com.rofkek.rack-touch-seizer.sock
tail -F /Library/Logs/com.rofkek.rack-touch-seizer.log
```

Expected markers include both interface matches, a successful Device Mode
write/readback, the Touch Up bridge connection, and five-byte absolute reports.

If the socket belongs to a previous console user, restart the helper:

```sh
sudo launchctl kickstart -k system/com.rofkek.rack-touch-seizer
```

If input is fully suppressed because the app is not running, unload the helper:

```sh
sudo launchctl bootout system /Library/LaunchDaemons/com.rofkek.rack-touch-seizer.plist
```

## Customizing another installation

Edit the defaults in `RackTouchProtocol.h` before rebuilding:

- vendor/product IDs
- rack and cursor-return display names
- empirical raw calibration bounds
- logical panel dimensions used for drag thresholding

The helper supports one matching rack controller at a time. Multi-seat/Fast User
Switching is not supported; restart the daemon after changing the active console
user. Display names must match macOS exactly.

## Uninstall

```sh
./RackTouchSeizer/uninstall.sh
```

The uninstall script unloads the daemon and removes its executable/plist. It
intentionally leaves the diagnostic log in place.
