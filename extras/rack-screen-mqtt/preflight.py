#!/usr/bin/env python3
"""Verify the RTK display's DDC/CI path before the LaunchAgent is enabled."""

from __future__ import annotations

import argparse
import sys

from rack_screen_mqtt import BridgeConfig, DDCController, raw_to_percent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--exercise", action="store_true",
                        help="set 30%%, set 80%%, then restore the original value")
    args = parser.parse_args()

    config = BridgeConfig.from_json(args.config)
    controller = DDCController(ddc_path=config.ddc_path)
    try:
        display = controller.scan()
    except Exception:
        print(
            "DDC preflight failed: RTK FHD/J257M96B00FL was found by macOS, "
            "but ddcctl could not read VCP brightness. Replug/reboot first; if "
            "the failure persists, use a direct or DDC-capable video adapter.",
            file=sys.stderr,
        )
        return 2

    original_percent = raw_to_percent(display.current, display.maximum)
    print(
        f"DDC read passed on display {display.index}: "
        f"{original_percent:.2f}% (raw {display.current:g}/{display.maximum:g})"
    )
    if not args.exercise:
        return 0

    restored = False
    try:
        for requested in (30.0, 80.0):
            actual = controller.set_percent(requested)
            print(f"DDC set/readback passed: requested {requested:g}%, read {actual:.2f}%")
    finally:
        try:
            actual = controller.set_percent(original_percent)
            restored = True
            print(f"Restored original brightness: {actual:.2f}%")
        except Exception as exc:
            print(f"WARNING: could not restore original brightness ({type(exc).__name__})",
                  file=sys.stderr)
    return 0 if restored else 3


if __name__ == "__main__":
    raise SystemExit(main())
