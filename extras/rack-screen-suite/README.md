# Rack screen suite

This is the single entry point for the signed Touch Up runtime on macOS. It
keeps the existing component installers as the owners of their installation
layouts, but orders them so `RackTouchSeizer` seizes the WCH mouse-compatible
interface first. The per-user launcher waits for the helper's mode-0600 Unix
socket before opening `Touch Up.app`.

## Install

From this repository:

```zsh
./extras/rack-screen-suite/install.sh
./extras/rack-screen-suite/status.sh
```

Use `--with-mqtt` to also run the optional MQTT/DDC installer:

```zsh
./extras/rack-screen-suite/install.sh --with-mqtt
```

The installer requires Darwin, a valid strict/deep signature on
`/Applications/Touch Up.app`, bundle ID `de.schafe.Touch-Up-notarized`, and a
matching identity in `security find-identity -v -p codesigning`. It exports the
app's first codesign `Authority` as `RACK_TOUCH_CODE_SIGN_IDENTITY` before
calling `RackTouchSeizer/install.sh`; the helper therefore has the same leaf
identity as the app.

On first install, grant these macOS privacy permissions in System Settings >
Privacy & Security, then relaunch the affected processes:

1. Accessibility: `Touch Up`.
2. Input Monitoring: `Touch Up`.
3. Input Monitoring: `RackTouchSeizer`, shown as the installed helper
   `/Library/PrivilegedHelperTools/com.rofkek.rack-touch-seizer`.

The helper creates `/var/run/com.rofkek.rack-touch-seizer.sock` only after its
exclusive WCH mouse open succeeds. A missing socket is consequently a useful
readiness/privacy/controller warning, not a reason for Touch Up to race the
helper.

## Status and uninstall

`status.sh` is read-only and never calls `sudo`. It reports app/helper
signature agreement, LaunchDaemon and LaunchAgent state, socket readiness,
process/log bridge markers, and (when present) MQTT config mode and inactive
state without printing credentials.

```zsh
./extras/rack-screen-suite/status.sh
./extras/rack-screen-suite/uninstall.sh
./extras/rack-screen-suite/uninstall.sh --with-mqtt
```

Uninstall stops Touch Up, removes the delayed launcher and privileged helper,
and leaves the app bundle and helper log in place. `--with-mqtt` invokes the
MQTT component's default uninstall, which removes its LaunchAgent but
preserves app support, virtualenv, logs, and `config.json`. The MQTT purge
option is intentionally not used by this suite.

## Recovery and security notes

The helper runs as root because exclusive HID ownership is required. It
accepts report-bridge clients only from the current console user and protects
the socket with mode `0600`; it captures only the matching WCH mouse interface.
Touch Up remains a signed app and is launched through LaunchServices so TCC
attributes Accessibility/Input Monitoring to the app bundle. Never grant
privacy access to an unsigned replacement of either component.

If the cursor behaves unexpectedly, run `status.sh`, quit Touch Up, and use
`uninstall.sh` to unload the helper. Reinstall only after confirming the app's
signature and privacy grants. The app itself is not deleted by this suite.
