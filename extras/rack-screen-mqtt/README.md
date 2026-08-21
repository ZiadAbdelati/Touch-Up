# Rack Screen MQTT/DDC bridge

This optional macOS service exposes the DeskPi/GeekPi rack display brightness
to Home Assistant through MQTT while controlling the monitor with `ddcctl`.
It identifies the target by EDID serial `J257M96B00FL`, with exact display-name
fallback `RTK FHD`.

No broker address, username, password, or live configuration is included in the
repository.

## Home Assistant contract

| Purpose | Topic or ID |
| --- | --- |
| Entity ID | `number.rack_screen_brightness` |
| Unique ID | `deskpi_2u_rack_screen_brightness` |
| Discovery | `homeassistant/number/rack_screen_brightness/config` |
| Commands | `rack/deskpi_screen/brightness/set` |
| State | `rack/deskpi_screen/brightness/state` |
| Availability | `rack/deskpi_screen/availability` |

Discovery, state, and availability are retained. The bridge validates 0–100
commands, coalesces rapid slider changes, converts percentages using the
monitor-reported DDC maximum, reads the applied value back, and polls every 60
seconds. Three consecutive DDC failures publish `offline`.

## Install

```sh
brew install ddcctl python@3.13
./install.sh
```

Installation is deliberately inactive. Configure MQTT with the hidden password
prompt:

```sh
"$HOME/Library/Application Support/com.rofkek.rack-screen-mqtt/configure.sh"
```

Then exercise DDC at 30% and 80%, restore the original value, and start the
LaunchAgent:

```sh
"$HOME/Library/Application Support/com.rofkek.rack-screen-mqtt/start.sh"
```

The service uses:

- source/config: `~/Library/Application Support/com.rofkek.rack-screen-mqtt/`
- agent: `~/Library/LaunchAgents/com.rofkek.rack-screen-mqtt.plist`
- logs: `~/Library/Logs/com.rofkek.rack-screen-mqtt/`

`config.json` is mode 600. Reinstalling preserves it.

## Verify and test

```sh
launchctl print "gui/$(id -u)/com.rofkek.rack-screen-mqtt"
tail -F "$HOME/Library/Logs/com.rofkek.rack-screen-mqtt/"*.log
python3 -m pip install -r requirements-dev.txt
python3 -m pytest tests -q
```

If DDC preflight fails, stop rather than loading the LaunchAgent. Replug the
display and retry; if the adapter does not pass DDC/CI, use a direct or
DDC-capable connection. Avoid arbitrary `ddcctl -W` reply-delay experiments,
which can wedge some display I²C paths until reboot.

## Uninstall

`./uninstall.sh` removes only the LaunchAgent and preserves local config/logs.
Use `./uninstall.sh --purge` only when intentionally deleting the local virtual
environment, credentials, and logs.
