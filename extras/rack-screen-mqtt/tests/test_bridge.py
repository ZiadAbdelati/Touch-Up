import json
import subprocess
import threading
import time
from pathlib import Path

import pytest

import sys

sys.path.insert(0, str(Path(__file__).parents[1]))
from rack_screen_mqtt import (  # noqa: E402
    AVAILABILITY_TOPIC,
    COMMAND_TOPIC,
    DISCOVERY_PAYLOAD,
    DISCOVERY_TOPIC,
    DDCController,
    BridgeConfig,
    RackScreenBridge,
    STATE_TOPIC,
    display_matches,
    parse_brightness_output,
    percent_to_raw,
    raw_to_percent,
    validate_percent,
)


DISPLAY = """Monitor Name: RTK FHD
Serial: J257M96B00FL
Current brightness: 30
Maximum brightness: 100
"""
DDCCTL = "/usr/local/bin/ddcctl"
REAL_DDCCTL_OUTPUT = """I: polling EDID for #2
I: got edid.serial: J257M96B00FL
I: got edid.name: RTK FHD
I: VCP control #16 (0x10) = current: 37, max: 100
"""


def completed(output=DISPLAY, returncode=0):
    return subprocess.CompletedProcess(["ddcctl"], returncode, output, "")


def completed_stderr(output=REAL_DDCCTL_OUTPUT, returncode=0):
    return subprocess.CompletedProcess(["ddcctl"], returncode, "", output)


def test_parse_common_ddcctl_formats():
    assert parse_brightness_output("Current: 30\nMax: 100") == (30.0, 100.0)
    assert parse_brightness_output("Brightness: 42 (range 0-255)") == (42.0, 255.0)
    assert parse_brightness_output("Current: 42, range: 0-255") == (42.0, 255.0)
    assert parse_brightness_output("30/100") == (30.0, 100.0)
    assert parse_brightness_output(REAL_DDCCTL_OUTPUT) == (37.0, 100.0)


def test_parse_rejects_missing_or_invalid_range():
    with pytest.raises(ValueError):
        parse_brightness_output("no brightness here")
    with pytest.raises(ValueError):
        parse_brightness_output("Current: 50 Max: 0")


def test_display_matches_serial_then_exact_name_fallback():
    assert display_matches("Serial: J257M96B00FL\nMonitor Name: something")
    assert not display_matches("Serial: other\nMonitor Name: RTK FHD")
    assert display_matches("Monitor Name: RTK FHD")
    assert not display_matches("Serial: J257M96B00FLX\nMonitor Name: RTK FHDX")
    assert display_matches(REAL_DDCCTL_OUTPUT)


def test_percent_mapping_and_validation():
    assert validate_percent(b" 25 ") == 25
    assert percent_to_raw(50, 255) == 128
    assert raw_to_percent(128, 255) == pytest.approx(50.196, abs=0.001)
    for value in (-1, 101, "", "nan", True, float("inf")):
        with pytest.raises(ValueError):
            validate_percent(value)


def test_scan_indices_and_cache():
    calls = []

    def runner(*args, **kwargs):
        calls.append(args)
        if args[2] == "2":
            return completed(DISPLAY)
        raise subprocess.CalledProcessError(1, args)

    ddc = DDCController(runner=runner)
    assert ddc.scan().index == 2
    assert [call[2] for call in calls] == ["1", "2"]
    calls.clear()
    assert ddc.read() == (30.0, 100.0)
    assert calls == [(DDCCTL, "-d", "2", "-b", "?")]


def test_read_rescans_when_cached_display_mismatches():
    outputs = iter([
        DISPLAY,
        "Serial: wrong\nMonitor Name: wrong\nCurrent: 10\nMax: 100",
        "Serial: J257M96B00FL\nMonitor Name: RTK FHD\nCurrent: 60\nMax: 100",
    ])

    def runner(*args, **kwargs):
        return completed(next(outputs))

    ddc = DDCController(runner=runner, max_index=1)
    assert ddc.scan().current == 30
    assert ddc.read() == (60.0, 100.0)


def test_scan_accepts_real_ddcctl_output_from_stderr():
    ddc = DDCController(runner=lambda *args, **kwargs: completed_stderr(), max_index=1)
    assert ddc.scan() == ddc._cached
    assert ddc._cached.current == 37


def test_set_writes_scaled_raw_and_reads_actual_value():
    calls = []

    def runner(*args, **kwargs):
        calls.append(args)
        if args[-1] == "?":
            return completed(DISPLAY)
        return completed_stderr(
            "E: Failed to find display in WindowServer's preferences!\n"
            "D: setting VCP control #16 => 50\n"
        )

    ddc = DDCController(runner=runner, max_index=1)
    assert ddc.set_percent(50) == 30  # mocked readback is authoritative
    assert calls == [
        (DDCCTL, "-d", "1", "-b", "?"),
        (DDCCTL, "-d", "1", "-b", "50"),
        (DDCCTL, "-d", "1", "-b", "?"),
    ]


class FakeClient:
    def __init__(self):
        self.published = []
        self.subscriptions = []

    def publish(self, topic, payload, qos=0, retain=False):
        self.published.append((topic, payload, qos, retain))

    def subscribe(self, topic, qos=0):
        self.subscriptions.append((topic, qos))


class FakeDDC:
    def __init__(self, reads=None, sets=None):
        self.reads = list(reads or [(50, 100)])
        self.sets = list(sets or [50])
        self.set_values = []

    def read(self):
        result = self.reads.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    def set_percent(self, value):
        self.set_values.append(value)
        result = self.sets.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def test_connect_publishes_discovery_and_subscribes():
    client = FakeClient()
    ddc = FakeDDC()
    bridge = RackScreenBridge(BridgeConfig(), ddc=ddc, mqtt_client=client)
    bridge.on_connect(client, None, None, 0)
    assert client.subscriptions == [(COMMAND_TOPIC, 1)]
    topics = [item[0] for item in client.published]
    assert DISCOVERY_TOPIC in topics
    assert AVAILABILITY_TOPIC in topics
    discovery = json.loads(next(item[1] for item in client.published if item[0] == DISCOVERY_TOPIC))
    assert discovery == DISCOVERY_PAYLOAD
    state = next(item[1] for item in client.published if item[0] == STATE_TOPIC)
    assert state == "50"


def test_invalid_mqtt_commands_are_ignored():
    client = FakeClient()
    bridge = RackScreenBridge(ddc=FakeDDC(), mqtt_client=client)
    bridge.on_message(client, None, type("Message", (), {"payload": b"101"})())
    assert bridge._pending is None


def test_commands_are_coalesced_to_latest_value():
    client = FakeClient()
    ddc = FakeDDC()
    bridge = RackScreenBridge(ddc=ddc, mqtt_client=client)
    bridge._worker = threading.Thread(target=bridge._command_loop, daemon=True)
    bridge._worker.start()
    for value in (10, 20, 30):
        bridge.on_message(client, None, type("Message", (), {"payload": str(value).encode()})())
    time.sleep(0.05)
    bridge.stop()
    assert ddc.set_values == [30]


def test_three_failures_mark_offline_and_success_recovers():
    client = FakeClient()
    ddc = FakeDDC(reads=[RuntimeError(), RuntimeError(), RuntimeError(), (25, 100)])
    bridge = RackScreenBridge(ddc=ddc, mqtt_client=client)
    assert bridge.poll_once() is None
    assert bridge.poll_once() is None
    assert bridge.poll_once() is None
    assert bridge.poll_once() == 25
    availability = [item[1] for item in client.published if item[0] == AVAILABILITY_TOPIC]
    assert availability == ["offline", "online"]


def test_config_json_loader(tmp_path):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"broker": {"host": "mqtt", "port": 1884,
                                              "username": "u", "password": "p"},
                                "poll_interval": 12}), encoding="utf-8")
    config = BridgeConfig.from_json(path)
    assert (config.broker_host, config.broker_port, config.username, config.poll_interval,
            config.ddc_path) == (
        "mqtt", 1884, "u", 12, "/usr/local/bin/ddcctl"
    )


def test_discovery_payload_exactly_preserves_existing_home_assistant_contract():
    assert DISCOVERY_PAYLOAD == {
        "unique_id": "deskpi_2u_rack_screen_brightness",
        "default_entity_id": "number.rack_screen_brightness",
        "command_topic": "rack/deskpi_screen/brightness/set",
        "state_topic": "rack/deskpi_screen/brightness/state",
        "availability_topic": "rack/deskpi_screen/availability",
        "payload_available": "online",
        "payload_not_available": "offline",
        "unit_of_measurement": "%",
        "icon": "mdi:brightness-6",
        "device": {
            "identifiers": ["deskpi_2u_rack_screen"],
            "manufacturer": "DeskPi / Realtek HDMI Controller",
            "model": "RTK FHD DDC/CI Display",
            "name": "DeskPi 2U Rack Screen",
        },
        "step": 1,
        "name": "Brightness",
        "mode": "slider",
        "max": 100,
        "min": 0,
    }


def test_config_validation_rejects_unconfigured_or_invalid_values():
    with pytest.raises(ValueError, match="broker host"):
        BridgeConfig(broker_host="").validate()
    with pytest.raises(ValueError, match="broker port"):
        BridgeConfig(broker_port=70000).validate()
    with pytest.raises(ValueError, match="poll interval"):
        BridgeConfig(poll_interval=0).validate()
    with pytest.raises(ValueError, match="ddc.path"):
        BridgeConfig(ddc_path="ddcctl").validate()
