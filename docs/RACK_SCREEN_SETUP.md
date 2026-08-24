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

The current build seizes the narrowly matched WCH interfaces directly. Do not
install or run `RackTouchSeizer`; if an earlier setup installed it, run
`./RackTouchSeizer/uninstall.sh` before launching the direct-capture app.

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
   The optional helper-assisted calibration workflow below is only needed if
   those targets are no longer accurate.
9. Unplug/replug the touch USB connection and repeat tap/hold/drag/scroll.
10. Quit and reopen the app and repeat.
11. Reboot and verify the app Login Item, mapping, and cursor restoration.

Pinch is not an acceptance criterion because this controller did not emit
multitouch frames during testing.

## Diagnostics

```sh
log stream --style compact --predicate 'process == "Touch Up"'
ioreg -r -c IOHIDDevice -l | grep -E 'VendorID|ProductID|PrimaryUsage|LocationID'
codesign -d -r- /Applications/Touch\ Up.app
```

Expected markers include granted Input Monitoring, both WCH interface matches,
the `RTK FHD` mapping, and the first five-byte absolute report. If the app does
not receive reports, remove and re-add the installed signed app in both privacy
panes, then quit and reopen it.

If a previous helper installation is still suppressing input, remove it:

```sh
./RackTouchSeizer/uninstall.sh
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

`tools/calibrate.sh` obtains raw reports from the optional legacy helper socket;
a separately built calibrator cannot inherit Touch Up's Input Monitoring grant.
If recalibration is necessary, quit Touch Up, temporarily install/start the
helper, run the tool, record and review the fitted values, uninstall the helper,
then rebuild and reopen the signed app. Never run the helper and Touch Up's
direct capture simultaneously.

The direct path supports one matching rack controller at a time. Multi-seat/Fast
User Switching has not been tested. Display names must match macOS exactly.

## Legacy helper

`RackTouchSeizer` is retained as an optional compatibility fallback and build
test. It is not needed for the tested signed direct-capture configuration. If it
was installed during an earlier iteration, uninstall it with:

```sh
./RackTouchSeizer/uninstall.sh
```

The script unloads the daemon and removes its executable/plist. It intentionally
leaves the diagnostic log in place.
