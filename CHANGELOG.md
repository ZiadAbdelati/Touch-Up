# Changelog

## Cursor recovery hardening — 2026-09-09

- Updated the known remote-console EDID name to `T749-fHD720` and added a
  main-display/non-rack fallback so adapter name changes cannot preserve a
  contaminated rack-screen cursor position.
- Added a multitouch inactivity watchdog that cancels a stale pinch/suppression
  state and restores normal single-touch input.
- Made helper-side USB removal close the active report stream so Touch Up resets
  an interrupted gesture immediately and reconnects cleanly.
- Added a synchronous shutdown recovery path that restores cursor association,
  position, and visibility even if delayed restore blocks cannot run.
- Reset active synthetic state before replacing a digitizer interface during a
  reconnect race.

## Reboot startup reliability — 2026-08-24

- Fixed startup when `/dev/console` is temporarily owned by `_windowserver`:
  the helper waits for a real interactive login account, and the user launcher
  verifies that the readiness socket belongs to its UID.
- Restored the signed `RackTouchSeizer` helper as the required owner of the WCH
  mouse interface after direct app capture proved unreliable across reboot.
- Added stable helper signing derived from the installed app's local signing
  identity so the helper's Input Monitoring grant survives normal restarts and
  same-identity rebuilds.
- Made the helper publish its private socket only after exclusive HID capture
  succeeds, and made the user launcher wait for that readiness gate.
- Limited Touch Up's direct HID match to the digitizer; physical mouse reports
  now arrive only through the helper bridge, eliminating dual ownership.
- Added a per-user LaunchAgent package that starts Touch Up fifteen seconds after
  Aqua login, avoiding early-boot display, USB HID, and privacy-service races.
- Opens the exact installed bundle path through LaunchServices, preserving its
  signed TCC identity instead of attributing HID access to the unsigned delay
  wrapper, and keeps bounded diagnostic logs.
- Added a combined rack-screen suite with one touch installer/uninstaller,
  runtime status checks, and optional MQTT/DDC installation.

## Rack interaction update — 2026-08-23

- Added a stationary 650 ms tap-and-hold gesture that emits one right-click,
  suppresses the release tap, and cancels as soon as a drag begins.
- Released non-Accessibility Home Assistant slider drags at their original
  control point, preventing an out-of-modal finger release from becoming a
  backdrop click-away while retaining the final dragged value.
- Added one-finger pixel scrolling over normal web content while preserving
  mouse-style dragging for Accessibility-detected sliders.
- Routed scroll events to the rack window without moving the JetKVM cursor.
- Delayed tap cursor restoration until WindowServer consumes the queued click
  and reasserted hiding whenever a receiving app unexpectedly shows the cursor.
- Added a top-edge downward-pull gesture to reveal Safari/macOS chrome, with a
  timed cursor return to JetKVM.
- Widened the top-edge start target to a fingertip-sized 48 points and changed
  reveal delivery from a single cross-display jump to a reliable inside-to-edge
  pointer trajectory.
- Fixed click-history distance checks so taps on different toolbar controls are
  not mislabeled as double/triple clicks when only one axis changes or the next
  tap is above or left of the previous one.
- Forwarded each physical touchscreen mouse report atomically so a rapid
  tap-to-swipe transition cannot lose its intervening button-up event.
- Narrowed the helper to the mouse-compatible interface while diagnosing an
  exclusive-open race. The signed helper-first split is the final runtime.
- Investigated direct mouse-sibling capture in Touch Up; reboot testing showed
  that macOS could match and seize the interface without delivering reports, so
  the packaged configuration keeps that path disabled.
- Record the rack controller location during direct HID matching so display
  mapping selects `RTK FHD` before any helper bridge packet exists.
- Open a vendor/product/usage-scoped helper HID manager exclusively, ensuring
  native WindowServer mouse events are suppressed without capturing JetKVM or
  any unrelated pointing device.
- Defer bridged mouse-report processing until the physical helper callback
  returns so WindowServer accepts synthetic tap and drag events reliably.
- Promote deliberate horizontal movement to the existing captured mouse-drag
  path when Safari does not expose a Home Assistant slider as `AXSlider`, while
  retaining vertical page scrolling.
- Made cursor restoration emit a real hidden mouse-move away from the top edge,
  allowing Safari fullscreen chrome to dismiss instead of remaining latched.
- Added a multi-point raw-coordinate calibration tool; edge accuracy is handled
  by measured calibration rather than application-specific hit exceptions.
- Refit the controller bounds from 15 top/center/bottom targets, reducing the
  measured error from 23.9 px RMS to 10.9 px RMS.
- Documented the signed helper-first installation and its privacy boundaries.

## Rack screen integration — 2026-08-21

- Added a privileged helper that exclusively captures WCH/GeekPi controller
  interfaces `27c0:0859`, preventing macOS from clicking at the JetKVM cursor.
- Added a private Unix-socket report bridge between the helper and Touch Up.
- Added empirical full-panel calibration for the 1280×400 `RTK FHD` display.
- Added atomic tap injection, cursor-hidden drag, cursor restoration, and a
  stale-contact watchdog.
- Added Accessibility-aware slider constraints to prevent a drag release from
  dismissing Home Assistant popups.
- Added automatic mapping to `RTK FHD` and remote-console cursor return.
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
