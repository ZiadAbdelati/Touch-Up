# Touch Up — GeekPi rack-display integration

This is a hardware-specific fork of Sebastian Hueber's MIT-licensed
[Touch Up](https://github.com/shueber/Touch-Up). It makes a WCH-based
GeekPi/DeskPi 2U touchscreen behave as an absolute second-display touchscreen
on macOS while a JetKVM remains usable as the primary pointer display.

The fork is source-only and currently tested on an Intel NUC Hackintosh
(`x86_64`). It preserves the upstream app and framework, then adds a narrowly
matched privileged HID helper and rack-specific event path.

## What works

- A tap activates the corresponding point on `RTK FHD`, independent of the
  cursor position on JetKVM.
- One-finger drag works for Home Assistant sliders.
- The cursor is hidden during rack interaction and restored to JetKVM.
- Slider drags are constrained to Accessibility-reported slider bounds, so a
  release outside a popup does not become a click-away.
- A watchdog cancels incomplete HID contacts, preventing a stuck drag or
  trapped cursor after an interrupted report stream.
- The helper reconnects after app, daemon, or USB restarts.
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
| Raw calibration | X `166…16249`, Y `180…9264` |
| macOS architecture | Intel `x86_64` |

These defaults live together in `RackTouchProtocol.h`. The USB location ID is
discovered at runtime, so moving the touchscreen to another USB port no longer
requires recompiling. The helper also derives the current console user's UID
and group rather than assuming account 501.

## Components

- `Touch Up/` and `TouchUpCore/`: upstream app/framework plus rack event mapping.
- `RackTouchSeizer/`: root LaunchDaemon that exclusively captures only the
  matching WCH mouse/digitizer interfaces and forwards reports through a
  mode-0600 Unix socket.
- `RackTouchProtocol.h`: shared packet format and hardware defaults.
- `extras/rack-screen-mqtt/`: independently installable MQTT/DDC brightness
  bridge; no broker credentials are stored in this repository.
- `docs/`: architecture, setup, recovery, and implementation notes.

## Build and install

1. Clone this branch on the target Mac and build the `Touch Up` scheme in
   Xcode. The app retains the upstream bundle identifiers, so changing signing
   identities or bundle IDs may require re-granting privacy permissions.
2. Build and install the helper:

   ```sh
   ./RackTouchSeizer/build.sh
   ./RackTouchSeizer/install.sh
   ```

   `install.sh` recompiles the helper, asks for an administrator password, and
   installs it under `/Library/PrivilegedHelperTools` with a system
   LaunchDaemon.
3. Put the built app in `/Applications`, launch it, and grant both
   **Accessibility** and **Input Monitoring** in System Settings → Privacy &
   Security.
4. In Touch Up settings, confirm the detected touchscreen is mapped to
   `RTK FHD`. Quit and reopen the app after changing privacy grants.
5. Test tap and drag with the normal mouse cursor parked on JetKVM.

The app should be added as a Login Item if it is not already started by another
per-user launcher. The root helper starts automatically at boot and waits until
a console user is logged in before creating its private socket.

## MQTT/DDC brightness

The companion service is documented in
[`extras/rack-screen-mqtt/README.md`](extras/rack-screen-mqtt/README.md). Its
installer copies source into the user's Application Support directory, creates
a private virtual environment, generates a per-user LaunchAgent, and preserves
an existing mode-600 configuration.

## Recovery and uninstall

If touch stops or the helper has seized the interface while the app is absent:

```sh
sudo launchctl bootout system /Library/LaunchDaemons/com.rofkek.rack-touch-seizer.plist
```

To remove it cleanly:

```sh
./RackTouchSeizer/uninstall.sh
```

Useful diagnostics:

```sh
sudo launchctl print system/com.rofkek.rack-touch-seizer
ls -l /var/run/com.rofkek.rack-touch-seizer.sock
tail -F /Library/Logs/com.rofkek.rack-touch-seizer.log
```

See [`docs/RACK_SCREEN_SETUP.md`](docs/RACK_SCREEN_SETUP.md) for the complete
permission, testing, troubleshooting, and limitation notes.

## Upstream

The original general-purpose project and documentation are available from
[shueber/Touch-Up](https://github.com/shueber/Touch-Up). This fork's changes are
listed in [`CHANGELOG.md`](CHANGELOG.md). The upstream MIT license is retained.
