# Touch Up — GeekPi rack-display integration

This is a hardware-specific fork of Sebastian Hueber's MIT-licensed
[Touch Up](https://github.com/shueber/Touch-Up). It makes a WCH-based
GeekPi/DeskPi 2U touchscreen behave as an absolute second-display touchscreen
on macOS while a JetKVM remains usable as the primary pointer display.

The fork is source-only and currently tested on an Intel NUC Hackintosh
(`x86_64`). It preserves the upstream app and framework, then adds a signed,
narrowly matched HID helper, a private local report bridge, and rack-specific
event handling.

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
- The helper and report bridge reconnect after app or USB restarts.
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
| Cursor-return display | `T749-fHD720`, then the main non-rack display |
| Raw calibration | X `−92.064…16435.664`, Y `−77.908…9905.108` |
| macOS architecture | Intel `x86_64` |

These defaults live together in `RackTouchProtocol.h`. A multi-point calibration
tool is included under `tools/`; because a separate calibration executable does
not have HID privacy access, it consumes the installed helper socket. The USB
location ID is discovered at runtime, so moving the touchscreen to another USB
port no longer requires recompiling.

## Components

- `Touch Up/` and `TouchUpCore/`: upstream app/framework plus direct capture of
  the WCH digitizer, private helper-socket input, and rack event mapping.
- `RackTouchSeizer/`: signed LaunchDaemon that exclusively owns only the WCH
  mouse-compatible interface and forwards atomic physical reports locally.
- `RackTouchProtocol.h`: shared packet format and hardware defaults.
- `extras/rack-screen-mqtt/`: independently installable MQTT/DDC brightness
  bridge; no broker credentials are stored in this repository.
- `extras/touch-up-launcher/`: delayed per-user launcher that avoids the
  post-reboot display/USB/privacy initialization race, waits for helper
  readiness, and preserves the signed app's TCC responsibility.
- `extras/rack-screen-suite/`: combined install, uninstall, and status commands
  for the helper, launcher, and optional MQTT/DDC service.
- `docs/`: architecture, setup, recovery, and implementation notes.

## Build and install

1. Clone this branch on the target Mac and build the `Touch Up` scheme in
   Xcode with a stable Apple Development or Developer ID signing identity.
   Keep the bundle identifier unchanged so macOS can retain its privacy grants.
2. Put the signed app in `/Applications`, launch it, and grant both
   **Accessibility** and **Input Monitoring** in System Settings → Privacy &
   Security.
3. Install the combined runtime package. It signs the helper with the same
   locally available leaf identity as the app, installs the system helper
   first, and installs the helper-gated user launcher second:

```sh
./extras/rack-screen-suite/install.sh
```

4. Add `/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer` to
   **Input Monitoring** on first install. A stable helper signature allows this
   grant to persist through normal reboots and same-identity rebuilds.
5. In Touch Up settings, confirm the detected touchscreen is mapped to
   `RTK FHD`. Quit and reopen the app after changing privacy grants.
6. Test tap, drag, and vertical scrolling with the normal mouse cursor parked
   on JetKVM.

Check the complete runtime without exposing credentials:

```sh
./extras/rack-screen-suite/status.sh
```

## MQTT/DDC brightness

The companion service is documented in
[`extras/rack-screen-mqtt/README.md`](extras/rack-screen-mqtt/README.md). Its
installer copies source into the user's Application Support directory, creates
a private virtual environment, generates a per-user LaunchAgent, and preserves
an existing mode-600 configuration.

## Recovery and uninstall

First run the suite status command and verify that the signed helper readiness
socket exists before Touch Up starts. Then verify that both privacy grants still
refer to the installed signed app and that Input Monitoring contains the signed
helper. Remove the touch runtime while leaving the app and privacy entries in
place with:

```sh
./extras/rack-screen-suite/uninstall.sh
```

Useful diagnostics:

```sh
log stream --style compact --predicate 'process == "Touch Up"'
tail -F /Library/Logs/com.rofkek.rack-touch-seizer.log
ioreg -r -c IOHIDDevice -l | grep -E 'VendorID|ProductID|PrimaryUsage|LocationID'
```

See [`docs/RACK_SCREEN_SETUP.md`](docs/RACK_SCREEN_SETUP.md) for the complete
permission, testing, troubleshooting, and limitation notes.

## Upstream

The original general-purpose project and documentation are available from
[shueber/Touch-Up](https://github.com/shueber/Touch-Up). This fork's changes are
listed in [`CHANGELOG.md`](CHANGELOG.md). The upstream MIT license is retained.
