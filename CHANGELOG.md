# Changelog

## Rack screen integration — 2026-08-21

- Added a privileged helper that exclusively captures WCH/GeekPi controller
  interfaces `27c0:0859`, preventing macOS from clicking at the JetKVM cursor.
- Added a private Unix-socket report bridge between the helper and Touch Up.
- Added empirical full-panel calibration for the 1280×400 `RTK FHD` display.
- Added atomic tap injection, cursor-hidden drag, cursor restoration, and a
  stale-contact watchdog.
- Added Accessibility-aware slider constraints to prevent a drag release from
  dismissing Home Assistant popups.
- Added automatic mapping to `RTK FHD` and cursor return to `JetKVM v1`.
- Removed the original hard-coded USB location ID and user UID assumptions.
- Added helper build/install/uninstall scripts and ignored all generated or
  locally installed binaries.
- Added the source-only MQTT/DDC Home Assistant brightness bridge under
  `extras/rack-screen-mqtt`.
- Added setup, architecture, troubleshooting, privacy, and hardware-limit docs.

### Known limitation

The panel does not emit its advertised multitouch input frames after accepting
Digitizer Device Mode 2. The experimental two-contact parser therefore receives
no usable data on the tested controller, and pinch-to-zoom is unavailable.
