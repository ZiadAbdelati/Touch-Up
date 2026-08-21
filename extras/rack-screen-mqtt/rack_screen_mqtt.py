"""MQTT/Home Assistant bridge for the brightness of a DDC/CI rack display.

The module deliberately keeps DDC and MQTT behind small injectable boundaries.  This
makes the bridge usable on a small host and keeps its parsing and failure behaviour
straightforward to test without either a monitor or a broker.
"""

from __future__ import annotations

import json
import logging
import math
import re
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol

try:  # paho is an optional import for testability on development machines.
    import paho.mqtt.client as mqtt
except ImportError:  # pragma: no cover - exercised only when the dependency is absent
    mqtt = None  # type: ignore[assignment]


LOGGER = logging.getLogger(__name__)

DISCOVERY_TOPIC = "homeassistant/number/rack_screen_brightness/config"
COMMAND_TOPIC = "rack/deskpi_screen/brightness/set"
STATE_TOPIC = "rack/deskpi_screen/brightness/state"
AVAILABILITY_TOPIC = "rack/deskpi_screen/availability"
TARGET_SERIAL = "J257M96B00FL"
FALLBACK_DISPLAY_NAME = "RTK FHD"
DEFAULT_POLL_INTERVAL = 60.0


class MQTTClient(Protocol):
    def publish(self, topic: str, payload: str, qos: int = ..., retain: bool = ...) -> Any: ...


def _number(value: Any) -> float:
    """Return a finite numeric value, rejecting booleans."""
    if isinstance(value, bool):
        raise ValueError("boolean is not a brightness value")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("brightness must be numeric") from exc
    if not math.isfinite(result):
        raise ValueError("brightness must be finite")
    return result


def validate_percent(value: Any) -> float:
    """Validate a Home Assistant brightness command and return 0..100."""
    # MQTT commands are normally text. JSON numeric payloads are also accepted,
    # but objects/arrays are intentionally not interpreted.
    if isinstance(value, (bytes, bytearray)):
        value = value.decode("utf-8")
    if isinstance(value, str):
        text = value.strip()
        if not text:
            raise ValueError("brightness is empty")
        try:
            parsed: Any = json.loads(text)
        except json.JSONDecodeError:
            parsed = text
        value = parsed
    result = _number(value)
    if not 0 <= result <= 100:
        raise ValueError("brightness must be between 0 and 100")
    return result


def percent_to_raw(percent: Any, maximum: Any) -> int:
    """Map a percentage to the monitor's integer DDC range."""
    pct = validate_percent(percent)
    max_value = _number(maximum)
    if max_value <= 0:
        raise ValueError("DDC maximum must be positive")
    return max(0, min(int(round(pct * max_value / 100.0)), int(round(max_value))))


def raw_to_percent(current: Any, maximum: Any) -> float:
    """Map a DDC value to a percentage, preserving useful fractional values."""
    current_value = _number(current)
    max_value = _number(maximum)
    if max_value <= 0:
        raise ValueError("DDC maximum must be positive")
    return max(0.0, min(100.0, current_value * 100.0 / max_value))


_CURRENT_PATTERNS = (
    re.compile(r"(?:current|value|brightness)\s*[:=]\s*(-?\d+(?:\.\d+)?)", re.I),
    re.compile(r"\b(-?\d+(?:\.\d+)?)\s*(?:/|of)\s*(-?\d+(?:\.\d+)?)\b", re.I),
)
_MAX_PATTERNS = (
    re.compile(r"(?:maximum|max)\s*[:=]\s*(-?\d+(?:\.\d+)?)", re.I),
    re.compile(r"range\s*[:=]?\s*(?:0\s*[-–]\s*)?(-?\d+(?:\.\d+)?)", re.I),
    re.compile(r"\b(-?\d+(?:\.\d+)?)\s*(?:/|of)\s*(-?\d+(?:\.\d+)?)\b", re.I),
)


def parse_brightness_output(output: str) -> tuple[float, float]:
    """Extract current and maximum brightness from common ddcctl output.

    ddcctl versions differ slightly (``Current: 30 Max: 100``, ``30/100``,
    and ``Brightness: 30 (range 0-100)`` are all seen in the field), so the
    parser is intentionally line-oriented and tolerant of punctuation.
    """
    text = str(output)
    current: float | None = None
    maximum: float | None = None
    for match in _CURRENT_PATTERNS:
        found = match.search(text)
        if found:
            current = float(found.group(1))
            if len(found.groups()) > 1 and maximum is None:
                maximum = float(found.group(2))
            break
    for match in _MAX_PATTERNS:
        found = match.search(text)
        if found:
            maximum = float(found.group(2) if len(found.groups()) > 1 else found.group(1))
            if current is None and len(found.groups()) > 1:
                current = float(found.group(1))
            break
    # Support bare two-number output as a final, conservative fallback.
    if current is None or maximum is None:
        numbers = [float(x) for x in re.findall(r"(?<![A-Za-z])\d+(?:\.\d+)?", text)]
        if len(numbers) >= 2:
            current = numbers[-2] if current is None else current
            maximum = numbers[-1] if maximum is None else maximum
    if current is None or maximum is None or maximum <= 0 or current < 0:
        raise ValueError("could not parse current/max brightness from ddcctl output")
    return current, maximum


def _combined_output(result: subprocess.CompletedProcess[str]) -> str:
    """Combine ddcctl's stdout/stderr; releases use both streams."""
    return "\n".join(part for part in (result.stdout, result.stderr) if part)


def _field(output: str, labels: tuple[str, ...]) -> str | None:
    for label in labels:
        match = re.search(rf"(?im)^\s*{re.escape(label)}\s*[:=]\s*(.*?)\s*$", output)
        if match:
            return match.group(1).strip().strip('"')
    lowered = " ".join(labels).lower()
    if "serial" in lowered:
        match = re.search(r"(?im)^\s*(?:I:\s*)?got\s+edid\.serial\s*:\s*(.*?)\s*$", output)
        if match:
            return match.group(1).strip().strip('"')
    if "name" in lowered or "model" in lowered:
        match = re.search(r"(?im)^\s*(?:I:\s*)?got\s+edid\.name\s*:\s*(.*?)\s*$", output)
        if match:
            return match.group(1).strip().strip('"')
    return None


def display_matches(output: str, serial: str = TARGET_SERIAL,
                    fallback_name: str = FALLBACK_DISPLAY_NAME) -> bool:
    """Match a DDC display by exact EDID serial, or exact model-name fallback."""
    serial_value = _field(output, ("Serial", "Serial number", "EDID serial", "EDID Serial"))
    if serial_value:
        return serial_value.strip() == serial
    name_value = _field(output, ("Name", "Model", "Monitor name", "Monitor Name",
                                 "Display name", "Display Name", "EDID name"))
    return bool(name_value and name_value.strip() == fallback_name)


@dataclass(frozen=True)
class Display:
    index: int
    current: float
    maximum: float
    serial: str | None = None
    name: str | None = None


Runner = Callable[..., subprocess.CompletedProcess[str]]


class DDCController:
    """Locate one display and perform serialized DDC brightness operations."""

    def __init__(self, runner: Runner | None = None, target_serial: str = TARGET_SERIAL,
                 fallback_name: str = FALLBACK_DISPLAY_NAME, max_index: int = 8,
                 ddc_path: str = "/usr/local/bin/ddcctl") -> None:
        self.runner = runner or self._run
        self.target_serial = target_serial
        self.fallback_name = fallback_name
        self.max_index = max_index
        self.ddc_path = ddc_path
        self._cached: Display | None = None
        self._lock = threading.Lock()

    @staticmethod
    def _run(*args: str, **kwargs: Any) -> subprocess.CompletedProcess[str]:
        kwargs.setdefault("text", True)
        kwargs.setdefault("capture_output", True)
        kwargs.setdefault("check", True)
        return subprocess.run(args, **kwargs)

    def _probe(self, index: int) -> Display | None:
        try:
            result = self.runner(self.ddc_path, "-d", str(index), "-b", "?", check=True,
                                text=True, capture_output=True)
        except (OSError, subprocess.SubprocessError):
            return None
        output = _combined_output(result)
        if not display_matches(output, self.target_serial, self.fallback_name):
            return None
        try:
            current, maximum = parse_brightness_output(output)
        except ValueError:
            return None
        return Display(index=index, current=current, maximum=maximum,
                       serial=_field(output, ("Serial", "Serial number", "EDID serial")),
                       name=_field(output, ("Name", "Model", "Monitor name", "Display name")))

    def scan(self) -> Display:
        for index in range(1, self.max_index + 1):
            display = self._probe(index)
            if display is not None:
                self._cached = display
                return display
        raise RuntimeError("target DDC display was not found")

    def _display(self, force_rescan: bool = False) -> Display:
        if force_rescan or self._cached is None:
            return self.scan()
        return self._cached

    def read(self) -> tuple[float, float]:
        """Read current/max, rescanning once if the cached display fails."""
        with self._lock:
            display = self._display()
            try:
                result = self.runner(self.ddc_path, "-d", str(display.index), "-b", "?",
                                     check=True, text=True, capture_output=True)
                output = _combined_output(result)
                if not display_matches(output, self.target_serial, self.fallback_name):
                    raise RuntimeError("cached display no longer matches")
                current, maximum = parse_brightness_output(output)
                self._cached = Display(display.index, current, maximum,
                                       _field(output, ("Serial", "Serial number", "EDID serial")),
                                       _field(output, ("Name", "Model", "Monitor name", "Display name")))
                return current, maximum
            except (OSError, subprocess.SubprocessError, RuntimeError, ValueError):
                display = self._display(force_rescan=True)
                return display.current, display.maximum

    def set_percent(self, percent: Any) -> float:
        """Set brightness, read it back, and return the actual percentage."""
        pct = validate_percent(percent)
        with self._lock:
            display = self._display()
            raw = percent_to_raw(pct, display.maximum)
            try:
                # A write often emits only a terse acknowledgement, so identity
                # validation is performed against the readback below.
                self.runner(self.ddc_path, "-d", str(display.index), "-b", str(raw),
                            check=True, text=True, capture_output=True)
                # ddcctl emits a non-fatal ``E: Failed to find display in
                # WindowServer's preferences`` line on this Hackintosh even
                # when the VCP write succeeds.  The readback below is the
                # authoritative result, so do not infer failure from that log
                # prefix.
                time.sleep(0.2)
                verify = self.runner(self.ddc_path, "-d", str(display.index), "-b", "?",
                                     check=True, text=True, capture_output=True)
                verify_output = _combined_output(verify)
                if not display_matches(verify_output, self.target_serial, self.fallback_name):
                    raise RuntimeError("cached display no longer matches")
                current, maximum = parse_brightness_output(verify_output)
                self._cached = Display(display.index, current, maximum,
                                       _field(verify_output, ("Serial", "Serial number", "EDID serial")),
                                       _field(verify_output, ("Name", "Model", "Monitor name", "Display name")))
                return raw_to_percent(current, maximum)
            except (OSError, subprocess.SubprocessError, RuntimeError, ValueError):
                # A changed USB/DDC topology is common; invalidate the cache so a
                # later operation scans all indices again. Best-effort scanning here
                # also makes the cache refresh immediate after a failed operation.
                self._cached = None
                try:
                    self.scan()
                except Exception:
                    pass
                raise


@dataclass
class BridgeConfig:
    broker_host: str = "localhost"
    broker_port: int = 1883
    username: str | None = None
    password: str | None = None
    tls: bool = False
    ca_path: str | None = None
    client_id: str = "rack-screen-mqtt"
    poll_interval: float = DEFAULT_POLL_INTERVAL
    ddc_path: str = "/usr/local/bin/ddcctl"
    discovery_topic: str = DISCOVERY_TOPIC
    command_topic: str = COMMAND_TOPIC
    state_topic: str = STATE_TOPIC
    availability_topic: str = AVAILABILITY_TOPIC

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "BridgeConfig":
        broker = data.get("broker") if isinstance(data.get("broker"), Mapping) else data
        ddc = data.get("ddc") if isinstance(data.get("ddc"), Mapping) else {}
        return cls(
            broker_host=str(broker.get("host", broker.get("hostname", cls.broker_host))),
            broker_port=int(broker.get("port", cls.broker_port)),
            username=broker.get("username") or None, password=broker.get("password") or None,
            tls=bool(broker.get("tls", False)),
            ca_path=broker.get("ca_path") or None,
            client_id=str(broker.get("client_id", cls.client_id)),
            poll_interval=float(data.get("poll_interval", data.get("poll_seconds", cls.poll_interval))),
            ddc_path=str(ddc.get("path", "/usr/local/bin/ddcctl")),
        )

    @classmethod
    def from_json(cls, path: str | Path) -> "BridgeConfig":
        with Path(path).open(encoding="utf-8") as handle:
            return cls.from_mapping(json.load(handle))

    def validate(self) -> None:
        if not self.broker_host.strip():
            raise ValueError("MQTT broker host is required; run configure.sh")
        if not 1 <= self.broker_port <= 65535:
            raise ValueError("MQTT broker port must be from 1 to 65535")
        if self.poll_interval <= 0:
            raise ValueError("poll interval must be positive")
        if not self.ddc_path.startswith("/"):
            raise ValueError("ddc.path must be absolute for launchd")


DISCOVERY_PAYLOAD: dict[str, Any] = {
    "unique_id": "deskpi_2u_rack_screen_brightness",
    "default_entity_id": "number.rack_screen_brightness",
    "command_topic": COMMAND_TOPIC,
    "state_topic": STATE_TOPIC,
    "availability_topic": AVAILABILITY_TOPIC,
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


class RackScreenBridge:
    """MQTT lifecycle, retained HA topics, polling, and coalesced commands."""

    def __init__(self, config: BridgeConfig | None = None, ddc: DDCController | None = None,
                 mqtt_client: MQTTClient | None = None, mqtt_module: Any = None) -> None:
        self.config = config or BridgeConfig()
        self.ddc = ddc or DDCController(ddc_path=self.config.ddc_path)
        self.client = mqtt_client
        self.mqtt_module = mqtt_module if mqtt_module is not None else mqtt
        self._stop = threading.Event()
        self._worker: threading.Thread | None = None
        self._poller: threading.Thread | None = None
        self._pending: Any = None
        self._pending_event = threading.Event()
        self._queue_lock = threading.Lock()
        self._consecutive_failures = 0
        self._availability_status: str | None = None

    def _publish(self, topic: str, payload: Mapping[str, Any] | str, retain: bool = True) -> None:
        if self.client is None:
            return
        body = json.dumps(payload, separators=(",", ":")) if isinstance(payload, Mapping) else payload
        self.client.publish(topic, body, qos=1, retain=retain)

    def _publish_state(self, percentage: float) -> None:
        rounded = round(percentage, 2)
        payload = str(int(rounded)) if rounded.is_integer() else f"{rounded:.2f}".rstrip("0")
        self._publish(self.config.state_topic, payload)

    def _publish_availability(self, status: str) -> None:
        if self._availability_status != status:
            self._availability_status = status
            self._publish(self.config.availability_topic, status)

    def _record_success(self, percentage: float | None = None) -> None:
        self._consecutive_failures = 0
        self._publish_availability("online")
        if percentage is not None:
            self._publish_state(percentage)

    def _record_failure(self, error: Exception) -> None:
        self._consecutive_failures += 1
        LOGGER.warning("DDC operation failed (%d consecutive failures): %s",
                       self._consecutive_failures, type(error).__name__)
        if self._consecutive_failures >= 3:
            self._publish_availability("offline")

    def on_connect(self, client: Any, userdata: Any, flags: Any, reason_code: Any, properties: Any = None) -> None:
        try:
            connected = int(reason_code) == 0
        except (TypeError, ValueError):
            connected = getattr(reason_code, "value", reason_code) == 0
        if not connected:
            return
        client.subscribe(self.config.command_topic, qos=1)
        self._publish(self.config.discovery_topic if hasattr(self.config, "discovery_topic") else DISCOVERY_TOPIC,
                      DISCOVERY_PAYLOAD)
        try:
            current, maximum = self.ddc.read()
            self._record_success(raw_to_percent(current, maximum))
        except Exception as exc:  # keep MQTT alive while the display is absent
            self._record_failure(exc)

    def on_message(self, client: Any, userdata: Any, message: Any) -> None:
        try:
            value = validate_percent(message.payload)
        except (UnicodeDecodeError, ValueError) as exc:
            LOGGER.warning("Ignoring invalid brightness command: %s", type(exc).__name__)
            return
        with self._queue_lock:
            self._pending = value
            self._pending_event.set()

    def _command_loop(self) -> None:
        while True:
            self._pending_event.wait(0.25)
            with self._queue_lock:
                has_pending = self._pending is not None
            if self._stop.is_set() and not has_pending:
                return
            # Let rapid Home Assistant slider updates settle, then apply only
            # the latest value so the monitor's small DDC MCU is not flooded.
            time.sleep(0.15)
            with self._queue_lock:
                value, self._pending = self._pending, None
                self._pending_event.clear()
            if value is None:
                continue
            try:
                self._record_success(self.ddc.set_percent(value))
            except Exception as exc:
                self._record_failure(exc)
            if self._stop.is_set():
                return

    def poll_once(self) -> float | None:
        try:
            current, maximum = self.ddc.read()
            percentage = raw_to_percent(current, maximum)
            self._record_success(percentage)
            return percentage
        except Exception as exc:
            self._record_failure(exc)
            return None

    def _poll_loop(self) -> None:
        while not self._stop.wait(self.config.poll_interval):
            self.poll_once()

    def start(self) -> "RackScreenBridge":
        if self.client is None:
            if self.mqtt_module is None:
                raise RuntimeError("paho-mqtt is required to start the bridge")
            callback_api = getattr(getattr(self.mqtt_module, "CallbackAPIVersion", None), "VERSION2", None)
            if callback_api is None:
                self.client = self.mqtt_module.Client(client_id=self.config.client_id)
            else:
                self.client = self.mqtt_module.Client(callback_api, client_id=self.config.client_id)
            if self.config.username is not None:
                self.client.username_pw_set(self.config.username, self.config.password)
            if self.config.tls:
                tls_kwargs = {"ca_certs": self.config.ca_path} if self.config.ca_path else {}
                self.client.tls_set(**tls_kwargs)
        self.client.will_set(self.config.availability_topic, "offline", qos=1, retain=True)
        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message
        self.client.connect(self.config.broker_host, self.config.broker_port, keepalive=60)
        self.client.loop_start()
        self._worker = threading.Thread(target=self._command_loop, name="ddc-command", daemon=True)
        self._worker.start()
        self._poller = threading.Thread(target=self._poll_loop, name="ddc-poll", daemon=True)
        self._poller.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        self._pending_event.set()
        if self._worker is not None:
            self._worker.join(timeout=2)
        if self._poller is not None:
            self._poller.join(timeout=2)
        if self.client is not None:
            try:
                self.client.publish(self.config.availability_topic, "offline", qos=1, retain=True)
                loop_stop = getattr(self.client, "loop_stop", None)
                if loop_stop is not None:
                    loop_stop()
                disconnect = getattr(self.client, "disconnect", None)
                if disconnect is not None:
                    disconnect()
            finally:
                self._availability_status = "offline"


def main(config_path: str = "config.json") -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    config = BridgeConfig.from_json(config_path)
    config.validate()
    bridge = RackScreenBridge(config=config).start()
    stop_event = threading.Event()

    def request_stop(signum: int, frame: Any) -> None:
        del signum, frame
        stop_event.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        stop_event.wait()
    except KeyboardInterrupt:
        pass
    finally:
        bridge.stop()


if __name__ == "__main__":  # pragma: no cover
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.json", help="path to JSON configuration")
    args = parser.parse_args()
    main(args.config)
