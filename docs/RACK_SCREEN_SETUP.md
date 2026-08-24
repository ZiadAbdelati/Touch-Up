# Rack screen setup and verification

## Prerequisites

- Intel macOS/Hackintosh target (`x86_64` tested)
- GeekPi/DeskPi controller reporting USB VID/PID `27c0:0859`
- `RTK FHD` rack display at 1280×400 logical resolution
- Xcode or Command Line Tools; Xcode is required to build the full app
- A stable Apple Development or Developer ID signing identity

## Install

Build the Touch Up app from `Touch Up.xcodeproj` with the same signing identity
you intend to keep using, then copy the product to `/Applications`. A stable
signature and unchanged bundle identifier let macOS associate later builds with
the existing privacy grants. Ad-hoc signing is unsuitable for this installation
because replacing the binary can invalidate its TCC identity.

Grant Touch Up under both **System Settings → Privacy & Security →
Accessibility** and **Input Monitoring**, then quit and reopen the app. In Touch
Up settings, map the detected touchscreen to `RTK FHD`.

Install the combined runtime package:

```sh
./extras/rack-screen-suite/install.sh
```

The installer derives the helper's stable signing identity from the installed
Touch Up app, installs the root LaunchDaemon first, then installs the per-user
launcher. On first install, add and enable the exact helper binary under
**Input Monitoring**:

```text
/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer
```

The helper exclusively owns only the WCH mouse-compatible interface. Its mode-
0600 readiness socket appears only after that exclusive open succeeds. The user
launcher waits for this socket before starting Touch Up, which captures the
digitizer and consumes the helper's atomic reports. This ordering is required.

Inspect the complete installation with:

```sh
./extras/rack-screen-suite/status.sh
```

## Acceptance tests

1. Park the mouse cursor on the JetKVM display.
2. Tap controls near all four edges of the rack dashboard; the touched controls
   should activate without revealing Safari's toolbar or the macOS menu bar.
3. Hold a context-clickable target without moving for about 650 ms. Exactly one
   context menu should appear, and lifting the finger must not dismiss it.
4. Drag a Home Assistant slider. The cursor should remain hidden and return to
   JetKVM after release.
5. Swipe vertically over ordinary dashboard content. The page should track the
   finger without selecting text or moving the visible JetKVM cursor.
6. Begin in the top 48 points and pull downward by at least 24 points. Safari
   and macOS navigation chrome should reveal; the cursor returns to JetKVM
   automatically after two seconds, and Safari should dismiss the chrome after
   observing that real pointer movement away from its top edge.
7. Drag beyond the edge of a slider popup and release. The value should change,
   but the release should not dismiss the popup.
8. After changing the panel or display scaling, repeat the edge/center tap test.
   The helper-based calibration workflow below is only needed if
   those targets are no longer accurate.
9. Unplug/replug the touch USB connection and repeat tap/hold/drag/scroll.
10. Quit and reopen the app and repeat.
11. Reboot and verify the delayed launcher, mapping, and cursor restoration.

Pinch is not an acceptance criterion because this controller did not emit
multitouch frames during testing.

## Diagnostics

```sh
log stream --style compact --predicate 'process == "Touch Up"'
ioreg -r -c IOHIDDevice -l | grep -E 'VendorID|ProductID|PrimaryUsage|LocationID'
codesign -d -r- /Applications/Touch\ Up.app
```

Expected markers include granted Input Monitoring, both WCH interface matches,
the helper's `Rack touchscreen mouse suppression active`, `Connected to
privileged rack-touch report bridge`, the `RTK FHD` mapping, and the first
five-byte absolute report. If the helper socket is absent, remove and re-add the
installed signed helper in Input Monitoring. If event injection is denied,
remove and re-add the signed app in Accessibility, then restart the suite.

To stop and remove the helper and launcher together while keeping the app,
privacy entries, and logs:

```sh
./extras/rack-screen-suite/uninstall.sh
```

## Customizing another installation

Edit the defaults in `RackTouchProtocol.h` before rebuilding:

- vendor/product IDs
- rack and cursor-return display names
- empirical raw calibration bounds
- logical panel dimensions used for drag thresholding

The 2026-08-23 15-point fit produced X `−92.064…16435.664` and Y
`−77.908…9905.108`. Its independent-axis residual was 10.9 px RMS / 21.2 px
maximum, versus 23.9 px RMS / 32.0 px maximum for the previous bounds. Affine
and quadratic fits were rejected because leave-one-out error did not improve.

`tools/calibrate.sh` obtains raw reports from the installed helper socket; a
separately built calibrator cannot inherit the helper's Input Monitoring grant.
If recalibration is necessary, stop Touch Up while leaving the helper running,
run the tool, record and review the fitted values, then rebuild and reopen the
signed app.

The runtime supports one matching rack controller at a time. Multi-seat/Fast
User Switching has not been tested. Display names must match macOS exactly.

## Runtime ownership

`RackTouchSeizer` is a required part of the tested configuration, not a legacy
fallback. It must start and obtain Input Monitoring before Touch Up. The helper
owns the mouse sibling; Touch Up owns the digitizer. The private socket is both
the event channel and the cross-launchd-domain readiness gate.
