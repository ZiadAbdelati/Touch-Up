# Touch Up — GeekPi rack-display integration

This is a hardware-specific fork of Sebastian Hueber's MIT-licensed
[Touch Up](https://github.com/shueber/Touch-Up). It makes a WCH-based
GeekPi/DeskPi 2U touchscreen behave as an absolute second-display touchscreen
on macOS while a JetKVM remains usable as the primary pointer display.

The fork is source-only and currently tested on an Intel NUC Hackintosh
(`x86_64`). It preserves the upstream app and framework, then adds a narrowly
matched, directly seized HID path and rack-specific event handling.

## What works

- A tap activates the corresponding point on `RTK FHD`, independent of the
  cursor position on JetKVM.
- A stationary 650 ms tap-and-hold performs one right-click and consumes the
  physical release so it does not immediately dismiss the context menu.
- One-finger drag works for Home Assistant sliders.
- One-finger movement over ordinary page content produces pixel scrolling;
  Accessibility sliders and deliberate horizontal slider movement receive
  captured mouse dragging.
- The cursor is hidden during rack interaction and restored to JetKVM.
- A deliberate downward pull beginning in the top 48 points reveals
  Safari/macOS chrome for touch-only navigation; other swipes still scroll.
- Slider drags are constrained to Accessibility-reported slider bounds, so a
  release outside a popup does not become a click-away.
- A watchdog cancels incomplete HID contacts, preventing a stuck drag or
  trapped cursor after an interrupted report stream.
- Direct HID capture reconnects after app or USB restarts.
- The optional MQTT/DDC companion preserves
  `number.rack_screen_brightness` in Home Assistant.

Pinch-to-zoom is **not available on the tested panel**. The controller advertises
a ten-contact digitizer report and accepts multitouch mode, but it only emits
the single-contact mouse-compatible stream on this hardware/macOS combination.
The experimental parser remains in the source for future firmware testing; it
does not make this panel multitouch.

## Tested hardware assumptions

| Item | Default |
| --- | --- |
| Touch controller | WCH `27c0:0859` |
| Rack display | `RTK FHD`, 1280×400 logical points |
| Cursor-return display | `JetKVM v1` |
| Raw calibration | X `−92.064…16435.664`, Y `−77.908…9905.108` |
| macOS architecture | Intel `x86_64` |

These defaults live together in `RackTouchProtocol.h`. A multi-point calibration
tool is included under `tools/`; because a separate calibration executable does
not share Touch Up's Input Monitoring identity, that tool uses the optional
legacy helper socket and is not part of normal runtime. The USB location ID is
discovered at runtime, so moving the touchscreen to another USB port no longer
requires recompiling.

## Components

- `Touch Up/` and `TouchUpCore/`: upstream app/framework plus direct, exclusive
  capture of the matching WCH mouse/digitizer interfaces and rack event mapping.
- `RackTouchSeizer/`: retained source for the earlier privileged-helper fallback.
  It is not installed or required by the current direct-capture configuration.
- `RackTouchProtocol.h`: shared packet format and hardware defaults.
- `extras/rack-screen-mqtt/`: independently installable MQTT/DDC brightness
  bridge; no broker credentials are stored in this repository.
- `docs/`: architecture, setup, recovery, and implementation notes.

## Build and install

1. Clone this branch on the target Mac and build the `Touch Up` scheme in
   Xcode with a stable Apple Development or Developer ID signing identity.
   Keep the bundle identifier unchanged so macOS can retain its privacy grants.
2. Put the signed app in `/Applications`, launch it, and grant both
   **Accessibility** and **Input Monitoring** in System Settings → Privacy &
   Security.
3. In Touch Up settings, confirm the detected touchscreen is mapped to
   `RTK FHD`. Quit and reopen the app after changing privacy grants.
4. Test tap, drag, and vertical scrolling with the normal mouse cursor parked
   on JetKVM.

The app should be added as a Login Item if it is not already started by another
per-user launcher. Do not run the legacy `RackTouchSeizer` LaunchDaemon at the
same time: both implementations attempt to seize the same HID interface.

## MQTT/DDC brightness

The companion service is documented in
[`extras/rack-screen-mqtt/README.md`](extras/rack-screen-mqtt/README.md). Its
installer copies source into the user's Application Support directory, creates
a private virtual environment, generates a per-user LaunchAgent, and preserves
an existing mode-600 configuration.

## Recovery and uninstall

First quit and reopen Touch Up and verify that its Accessibility and Input
Monitoring grants still refer to the installed, signed application. If the
legacy helper was previously installed and is still seizing the interface,
remove it cleanly:

```sh
./RackTouchSeizer/uninstall.sh
```

Useful direct-capture diagnostics:

```sh
log stream --style compact --predicate 'process == "Touch Up"'
ioreg -r -c IOHIDDevice -l | grep -E 'VendorID|ProductID|PrimaryUsage|LocationID'
```

See [`docs/RACK_SCREEN_SETUP.md`](docs/RACK_SCREEN_SETUP.md) for the complete
permission, testing, troubleshooting, and limitation notes.

## Upstream

The original general-purpose project and documentation are available from
[shueber/Touch-Up](https://github.com/shueber/Touch-Up). This fork's changes are
listed in [`CHANGELOG.md`](CHANGELOG.md). The upstream MIT license is retained.
