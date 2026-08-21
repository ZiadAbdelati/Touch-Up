# Architecture

## Event flow

```text
WCH 27c0:0859 touchscreen
        │ mouse + digitizer HID interfaces
        ▼
RackTouchSeizer (root LaunchDaemon, exclusive open)
        │ fixed-size RackTouchPacket over mode-0600 Unix socket
        ▼
TouchUpCore rack bridge (logged-in user)
        │ calibrated absolute point
        ▼
RTK FHD ── tap/drag Quartz events
        │
        └── cursor hidden during interaction, then restored to JetKVM
```

The helper is necessary because macOS otherwise consumes the controller's
mouse-compatible interface. That native event clicks wherever the global mouse
cursor currently sits, even when Touch Up separately maps the digitizer to the
rack display. Seizing only the exact WCH vendor/product interfaces suppresses
the duplicate native path without affecting a JetKVM or ordinary mouse.

## Single-contact path

The tested controller produces absolute X/Y/button values on its mouse
interface. The helper coalesces those values into a five-byte report and tags it
with the runtime IOKit location ID. TouchUpCore calibrates the measured raw
ranges to normalized panel coordinates.

A stationary down/up is emitted as an atomic click. Movement beyond eight
logical screen points becomes a captured drag. During drag, Touch Up hides the
cursor, posts a balanced down/drag/up sequence, and restores the saved cursor
position after the receiving app processes mouse-up. If Accessibility identifies
the target as a slider, coordinates are clamped inside its bounds.

The 300 ms watchdog releases a synthetic drag if the controller stops sending
before button-up. A socket disconnect performs the same gesture-state reset.

## Screen mapping

Rack reports are recognized by the runtime location ID delivered by the helper,
not a fixed USB-port address. `RTK FHD` bypasses upstream aspect-fit correction
because its EDID advertises conventional modes that do not describe the physical
1280×400 glass. Rotation is still honored. Cursor restoration prefers
`JetKVM v1`.

## Multitouch investigation

The HID descriptor advertises report `0x0d` with up to ten five-byte contact
records. The helper writes Digitizer Device Mode usage `0x52` to value `2` and
successfully reads that value back. Nonetheless, the tested hardware sends only
the single-contact mouse-compatible report. The long-report parser and synthetic
magnify path are retained as experimental instrumentation, but they are dormant
on this controller and are not claimed as working functionality.

## Security boundaries

- The daemon matches only vendor `0x27c0`, product `0x0859`, mouse and
  touchscreen usages.
- Its socket is owned by the current console user and has mode `0600`.
- New clients are verified with `getpeereid`.
- The app still needs Accessibility for Quartz event injection and Input
  Monitoring for HID access.
- Broker credentials for the optional brightness bridge live only in a
  mode-600 local `config.json` and are excluded from Git.

## macOS compatibility risk

Cursor hiding for a background menu-bar app dynamically resolves private
WindowServer symbols (`_CGSDefaultConnection` and `CGSSetConnectionProperty`).
It falls back to the public CoreGraphics cursor API if those symbols disappear,
but behavior should be retested after major macOS updates. Synthetic magnify
event fields are also undocumented; they remain experimental.
