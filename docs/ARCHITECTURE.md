# Architecture

## Event flow

```text
WCH 27c0:0859 touchscreen
        │ mouse + digitizer HID interfaces
        ▼
TouchUpCore IOHIDManager (logged-in user, exclusive open)
        │ deferred, atomic five-byte absolute report
        │ calibrated absolute point
        ▼
RTK FHD ── tap/drag Quartz events
        │
        └── cursor hidden during interaction, then restored to JetKVM
```

macOS otherwise consumes the controller's mouse-compatible interface. That
native event clicks wherever the global mouse cursor currently sits, even when
Touch Up separately maps the digitizer to the rack display. Touch Up therefore
matches the exact WCH vendor, product, usage page, and usage and opens that
narrow IOHID manager with `kIOHIDOptionsTypeSeizeDevice`. This suppresses the
duplicate native path without affecting JetKVM or an ordinary mouse.

Direct capture requires Input Monitoring. Quartz event injection and the
Accessibility slider lookup require Accessibility. The app uses a stable code
signature so macOS can persist both privacy grants across rebuilds and restarts.

## Single-contact path

The tested controller produces absolute X/Y/button values on its
mouse-compatible interface. The HID callback converts every physical report
into a five-byte button/X/Y report and defers processing to the next run-loop
turn. Deferring preserves physical contact-edge order while avoiding synthetic
events being discarded inside the seized source callback. TouchUpCore records
the runtime IOKit location ID and calibrates the measured raw ranges to
normalized panel coordinates.

A stationary down/up is emitted as an atomic click. Holding within the eight
point movement tolerance for 650 ms emits one atomic right-click; the eventual
physical release is consumed. Movement beyond eight logical screen points
cancels the hold timer and becomes a captured drag. During drag, Touch Up hides
the cursor, posts a balanced down/drag/up sequence, and restores the saved cursor
position after the receiving app processes mouse-up. If Accessibility identifies
the target as a slider, coordinates are clamped inside its bounds.

For Home Assistant custom sliders that Safari does not expose as `AXSlider`, a
deliberate horizontal gesture is promoted from scrolling to mouse dragging. The
last dragged event carries the requested value, while the balancing mouse-up is
delivered at the original control point. This keeps the down/up target inside
the modal and prevents its backdrop from treating an out-of-bounds release as a
click-away.

A 900 ms pre-drag watchdog allows a stationary hold to resolve without leaving
stale contact state. As soon as dragging begins, the timeout tightens to 300 ms
so an interrupted report stream cannot leave a synthetic mouse button latched.
Device removal and app shutdown perform the same gesture-state reset.

## Screen mapping

Rack reports are recognized by the runtime location ID recorded when the direct
HID interface is matched, not a fixed USB-port address. `RTK FHD` bypasses
upstream aspect-fit correction because its EDID advertises conventional modes
that do not describe the physical 1280×400 glass. Rotation is still honored.
Cursor restoration prefers `JetKVM v1`.

## Multitouch investigation

The HID descriptor advertises report `0x0d` with up to ten five-byte contact
records. Touch Up writes Digitizer Device Mode usage `0x52` to value `2` and
successfully reads that value back. Nonetheless, the tested hardware sends only
the single-contact mouse-compatible report. The long-report parser and synthetic
magnify path are retained as experimental instrumentation, but they are dormant
on this controller and are not claimed as working functionality.

## Security boundaries

- The app matches only vendor `0x27c0`, product `0x0859`, mouse and touchscreen
  usages before requesting exclusive access.
- The app needs Accessibility for Quartz event injection and Input Monitoring
  for HID access.
- Broker credentials for the optional brightness bridge live only in a
  mode-600 local `config.json` and are excluded from Git.

`RackTouchSeizer` and its mode-0600 Unix-socket bridge remain in the tree as a
legacy fallback and as a separately compiled regression target. They are not
part of the current runtime and must not be launched alongside direct capture.

## macOS compatibility risk

Cursor hiding for a background menu-bar app dynamically resolves private
WindowServer symbols (`_CGSDefaultConnection` and `CGSSetConnectionProperty`).
It falls back to the public CoreGraphics cursor API if those symbols disappear,
but behavior should be retested after major macOS updates. Synthetic magnify
event fields are also undocumented; they remain experimental.
