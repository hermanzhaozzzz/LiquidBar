#!/usr/bin/env python3
"""Independent peripheral bridge. Copyright (C) 2026 Huanan Zhao.

SPDX-License-Identifier: GPL-3.0-or-later
LD protocol: Nortank12/deepcool-digital-linux/src/devices/ld_series.rs,
blob 3e0b215c83a359ce00893d3bc1050dc5c1d8459b. Output HID reports include
report ID 0x10 at byte zero; these are NOT feature reports.
"""

# Driver failures are isolated at the peripheral and JSON request boundaries.
# ruff: noqa: BLE001
from __future__ import annotations

import json
import logging
import math
import os
import select
import signal
import struct
import sys
import time
from typing import Any

import hid
from liquidctl.driver import find_liquidctl_devices

logging.getLogger("liquidctl").setLevel(logging.CRITICAL)
logger = logging.getLogger(__name__)
FAN_MINIMUM, PUMP_MINIMUM = 30, 50
CURVE_TIMEOUT = 15.0
PRODUCTS = {
    "smart": (0x1E71, {0x2006, 0x200D, 0x200F}),
    "kraken": (0x1E71, {0x2007}),
    "aura": (0x0B05, {0x18F3, 0x1939, 0x19AF}),
    "ld": (0x3633, {10}),
}
CAPABILITIES = {
    "smart": ["fan_control", "fan_rpm", "lighting"],
    "kraken": ["pump_control", "liquid_temperature"],
    "aura": ["lighting"],
    "ld": ["display"],
}
CHANNELS = {
    "smart": ["fan1", "fan2", "fan3", "led1", "led2", "sync"],
    "kraken": ["pump"],
    "aura": ["sync", "led1", "led2", "led3", "led4"],
    "ld": ["display"],
}


def number(value: Any, name: str, low: float, high: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TypeError(f"{name} must be numeric")
    if not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f"{name} must be between {low} and {high}")
    return float(value)


def ld_initial_reports(leading_zeros: bool = False) -> tuple[bytes, bytes]:
    first = bytes([16, 104, 1, 1, 2, 3, 1, 112, 22]).ljust(64, b"\0")
    second = bytes(
        [16, 104, 1, 1, 2, 2, int(leading_zeros), 111 if leading_zeros else 110, 22]
    ).ljust(64, b"\0")
    return first, second


def ld_status_report(
    temperature: Any, utilization: Any, power: Any, unit: str = "C"
) -> bytes:
    """Input temperature is Celsius even when the display unit is Fahrenheit."""
    temp = number(temperature, "temperature", 0, 150)
    usage = number(utilization, "utilization", 0, 100)
    watts = number(power, "power", 0, 65535)
    if unit not in {"C", "F"}:
        raise ValueError("unit must be C or F")
    if unit == "F":
        temp = temp * 1.8 + 32
    packet = bytearray(64)
    packet[:8] = bytes([16, 104, 1, 1, 11, 1, 2, 5])
    packet[8:10] = struct.pack(">H", int(watts))
    packet[10] = int(unit == "F")
    packet[11:15] = struct.pack(">f", temp)
    packet[15] = int(usage)
    packet[16] = sum(packet[1:16]) % 256
    packet[17] = 22
    return bytes(packet)


class Aura18F3:
    """OpenRGB config-derived protocol; Martin Hartl et al., GPL-2.0-or-later."""

    product_id = 0x18F3

    def __init__(self, driver: Any) -> None:
        self.driver = driver
        self.groups: dict[str, tuple[int, int, int]] = {}
        self.firmware = ""

    def connect(self) -> None:
        self.driver.connect()

    def disconnect(self) -> None:
        self.driver.disconnect()

    def write(self, data: list[int]) -> None:
        packet = bytes(data).ljust(65, b"\0")
        if len(packet) != 65:
            raise ValueError("Aura report exceeds 65 bytes")
        count = self.driver.device.write(packet)
        if count != len(packet):
            raise OSError(f"Aura short write: {count}/65")

    def query(self, command: int, reply: int) -> list[int]:
        self.driver.device.clear_enqueued_reports()
        self.write([0xEC, command])
        data = list(self.driver.device.read(65))
        if len(data) < 64 or data[:2] != [0xEC, reply]:
            raise OSError("Unexpected Aura configuration response")
        return data

    def initialize(self) -> list[tuple[str, Any, str]]:
        firmware = self.query(0x82, 0x02)
        self.firmware = bytes(firmware[2:18]).split(b"\0", 1)[0].decode("ascii")
        config = self.query(0xB0, 0x30)[4:64]
        fixed, argb, rgb = config[0x1B], config[2], config[0x1D]
        if fixed + argb > 16 or fixed + argb == 0:
            raise ValueError("Unsupported Aura LED mask geometry")
        if rgb > fixed:
            rgb = 0
        zero_based = self.firmware.startswith("AULA3-AR32")
        self.groups = {}
        if fixed:
            self.groups["led1"] = (argb if zero_based else 0, 0, fixed)
        for index in range(argb):
            effect = index if zero_based or not fixed else index + 1
            self.groups[f"led{index + 2}"] = (effect, fixed + index, 1)
        self.write([0xEC, 0x52, 0x53, 0x00, 0x01])
        return [
            ("Firmware version", self.firmware, ""),
            ("Fixed LED slots", fixed, ""),
            ("RGB headers", rgb, ""),
            ("ARGB headers", argb, ""),
            ("ARGB start LED", fixed, ""),
        ]

    def set_color(
        self, channel: str, mode: str, colors: list[list[int]], **_kwargs: Any
    ) -> None:
        mode_code = {"static": 1, "off": 0, "breathing": 2, "rainbow": 5}[mode]
        if channel != "sync" and channel not in self.groups:
            raise ValueError(f"Aura channel {channel} is not present")
        selected = (
            list(self.groups.values()) if channel == "sync" else [self.groups[channel]]
        )
        color = colors[0] if colors else [0, 0, 0]
        for effect, start, count in selected:
            self.write([0xEC, 0x35, effect, 0, 0, mode_code])
            mask = ((1 << count) - 1) << start
            self.write(
                [0xEC, 0x36, mask >> 8, mask & 0xFF, 0]
                + [0] * (3 * start)
                + color * count
            )
        # EC 3F 55 saves an effect to device storage, not an ordinary update.


class DeviceManager:
    def __init__(self) -> None:
        self.devices: dict[str, Any] = {}
        self.errors: dict[str, str] = {}
        self.initialized: set[str] = set()
        self.last_scan = -math.inf
        self.ld_path: bytes | None = None
        self.ld_handle: Any = None
        self.display_state: dict[str, Any] = {"enabled": False, "last_update": None}
        self.lighting_state: dict[str, Any] = {}
        self.metadata: dict[str, Any] = {}
        self.curve_deadline: float | None = None
        self.curve_failsafe: dict[str, Any] | None = None

    def failsafe(self, reason: str) -> dict[str, Any]:
        """An armed software curve loses its lease: request full speed once."""
        # EOF and the parent's SIGTERM can arrive together. Do not interrupt
        # the full-speed sequence halfway through its three channels.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
        try:
            return self._failsafe(reason)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def _failsafe(self, reason: str) -> dict[str, Any]:
        if self.curve_deadline is None:
            return {"applied": True, "errors": {}}
        self.curve_deadline = None
        errors: dict[str, str] = {}
        device = self.devices.get("smart")
        if device is None:
            errors["smart"] = "Smart handle unavailable; full speed was not confirmed"
        else:
            # A missing tach signal does not mean a motor is disconnected.
            for index in range(1, 4):
                try:
                    device.set_fixed_speed(f"fan{index}", 100)
                except Exception as error:
                    errors[f"smart/fan{index}"] = str(error)
        self.curve_failsafe = {
            "reason": reason,
            "applied": not errors,
            "errors": errors,
        }
        if errors:
            logger.error("Smart curve failsafe incomplete: %s", errors)
        return self.curve_failsafe

    def expire_curve(self) -> None:
        if self.curve_deadline is not None and time.monotonic() >= self.curve_deadline:
            self.failsafe("heartbeat timeout")

    def disconnect(self, role: str) -> None:
        device = self.devices.pop(role, None)
        if device is not None:
            try:
                device.disconnect()
            except Exception as error:
                logger.debug("Device close failed: %s", error)
        self.initialized.discard(role)
        if role == "ld" and self.ld_handle is not None:
            try:
                self.ld_handle.close()
            except Exception as error:
                logger.debug("Device close failed: %s", error)
            self.ld_handle = None

    def disconnect_all(self) -> None:
        self.failsafe("helper disconnected")
        for role in PRODUCTS:
            self.disconnect(role)
        self.ld_path = None
        self.last_scan = -math.inf
        self.display_state["enabled"] = False

    def failed(self, role: str, error: Exception) -> None:
        self.errors[role] = f"{type(error).__name__}: {error}"
        if role == "smart":
            self.failsafe("Smart communication failure")
        self.disconnect(role)
        if role == "ld":
            self.display_state["enabled"] = False

    def discover(self, force: bool = False) -> None:
        """Connect without initialization, speed changes, or lighting writes."""
        if not force and time.monotonic() - self.last_scan < 15:
            return
        self.last_scan = time.monotonic()
        for vendor, roles in [(0x1E71, ("smart", "kraken")), (0x0B05, ("aura",))]:
            try:
                candidates = list(find_liquidctl_devices(vendor=vendor))
            except Exception as error:
                for role in roles:
                    if role not in self.devices:
                        self.errors[role] = f"Discovery failed: {error}"
                continue
            seen: set[str] = set()
            for device in candidates:
                pid = getattr(device, "product_id", None)
                role = next((r for r in roles if pid in PRODUCTS[r][1]), None)
                if role is None or role in seen:
                    continue
                seen.add(role)
                if role in self.devices:
                    continue
                try:
                    if role == "aura" and pid == 0x18F3:
                        device = Aura18F3(device)
                    device.connect()
                    self.devices[role] = device
                    self.errors.pop(role, None)
                except Exception as error:
                    try:
                        device.disconnect()
                    except Exception as close_error:
                        logger.debug("Device close failed: %s", close_error)
                    self.errors[role] = f"{type(error).__name__}: {error}"
            for role in roles:
                if role not in seen:
                    self.disconnect(role)
                    self.errors.pop(role, None)
        try:
            displays = hid.enumerate(0x3633, 10)
            path = displays[0]["path"] if displays else None
            if path != self.ld_path:
                self.disconnect("ld")
                self.display_state["enabled"] = False
                self.errors.pop("ld", None)
            self.ld_path = path
            if path is not None and self.ld_handle is None:
                # A new, bounded discovery cycle may offer the same HID path for
                # retry. Do not replay any display command here.
                self.errors.pop("ld", None)
        except Exception as error:
            self.failed("ld", error)

    def require(self, role: str, initialize: bool = True) -> Any:
        self.discover()
        device = self.devices.get(role)
        if device is None:
            raise RuntimeError(self.errors.get(role, f"{role} device is not connected"))
        if initialize and role not in self.initialized:
            try:
                result = device.initialize()
                self.metadata[role] = {str(k): str(v) for k, v, _ in result or []}
                self.initialized.add(role)
            except Exception as error:
                self.failed(role, error)
                raise
        return device

    def inventory(self) -> dict[str, Any]:
        self.discover()
        result = {}
        for role in PRODUCTS:
            present = role in self.devices if role != "ld" else self.ld_path is not None
            result[role] = {
                "connected": present and role not in self.errors,
                "capabilities": CAPABILITIES[role],
                "channels": (
                    ["sync", *self.devices[role].groups]
                    if role == "aura"
                    and isinstance(self.devices.get(role), Aura18F3)
                    and self.devices[role].groups
                    else CHANNELS[role]
                ),
                "error": self.errors.get(role),
                "state": "ready"
                if role in self.initialized
                else "detected"
                if present
                else "offline",
                "metadata": self.metadata.get(role, {}),
            }
        return result

    def status(self) -> dict[str, Any]:
        self.discover()
        status: dict[str, dict[str, Any]] = {"smart": {}, "kraken": {}}
        for role in status:
            if role not in self.devices:
                continue
            try:
                device = self.require(role)
                status[role] = {label: value for label, value, _ in device.get_status()}
                self.errors.pop(role, None)
            except Exception as error:
                self.failed(role, error)
        smart, kraken = status["smart"], status["kraken"]
        return {
            "liquid_temperature": kraken.get("Liquid temperature"),
            "pump_rpm": kraken.get("Pump speed"),
            "pump_duty": kraken.get("Pump duty"),
            "fan_rpm": [smart.get(f"Fan {i} speed") for i in range(1, 4)],
            "fan_duty": [smart.get(f"Fan {i} duty") for i in range(1, 4)],
            "fan_modes": [smart.get(f"Fan {i} control mode") for i in range(1, 4)],
            "noise_level": smart.get("Noise level"),
            "devices": self.inventory(),
            "errors": dict(self.errors),
            "display": dict(self.display_state),
            "lighting": dict(self.lighting_state),
            "curve": {
                "armed": self.curve_deadline is not None,
                "failsafe": self.curve_failsafe,
            },
        }

    def set_speed(self, role: str, channel: str, duty: Any) -> None:
        if role == "smart" and channel in {"fan1", "fan2", "fan3", "sync"}:
            minimum = FAN_MINIMUM
        elif role == "kraken" and channel == "pump":
            minimum = PUMP_MINIMUM
        else:
            raise ValueError(f"unsupported speed target: {role}/{channel}")
        value = max(minimum, int(number(duty, "duty", 0, 100)))
        device = self.require(role)
        try:
            device.set_fixed_speed(channel, value)
            self.errors.pop(role, None)
        except Exception as error:
            self.failed(role, error)
            raise

    def apply(
        self,
        fans: list[int] | None = None,
        pump: int | None = None,
        curve: bool = False,
    ) -> dict[str, Any]:
        if not isinstance(curve, bool):
            raise TypeError("curve must be boolean")
        if curve and fans is None:
            raise ValueError("arming a curve requires all three fan targets")
        if fans is not None:
            if not isinstance(fans, list) or len(fans) != 3:
                raise ValueError("exactly three fan duties are required")
            for duty in fans:
                number(duty, "fan duty", 0, 100)
        if pump is not None:
            number(pump, "pump duty", 0, 100)
        self.discover()
        if curve:
            self.require("smart")
            self.curve_deadline = time.monotonic() + CURVE_TIMEOUT
            self.curve_failsafe = None
        applied: dict[str, bool] = {}
        errors: dict[str, str] = {}
        skipped: list[str] = []
        completed_channels: list[str] = []
        for role, duties in [
            ("smart", fans),
            ("kraken", None if pump is None else [pump]),
        ]:
            if duties is None:
                continue
            if (
                role == "kraken"
                and role not in self.devices
                and role not in self.errors
                and fans is not None
            ):
                skipped.append(role)
                continue
            try:
                for index, duty in enumerate(duties, 1):
                    channel = f"fan{index}" if role == "smart" else "pump"
                    self.set_speed(role, channel, duty)
                    completed_channels.append(f"{role}/{channel}")
                applied[role] = True
            except Exception as error:
                applied[role] = False
                errors[role] = f"{type(error).__name__}: {error}"
        if applied.get("smart"):
            self.curve_deadline = time.monotonic() + CURVE_TIMEOUT if curve else None
        return {
            "applied": bool(applied) and all(applied.values()),
            "devices": applied,
            "errors": errors,
            "skipped": skipped,
            "completed_channels": completed_channels,
        }

    def lighting(self, command: dict[str, Any]) -> dict[str, Any]:
        role, channel = command.get("device"), command.get("channel", "sync")
        mode, speed = command.get("mode", "fixed"), command.get("speed", "normal")
        if role not in {"smart", "aura"}:
            raise ValueError("lighting device must be smart or aura")
        allowed = {"led1", "led2", "sync"} if role == "smart" else set(CHANNELS["aura"])
        if channel not in allowed:
            raise ValueError(f"unsupported lighting channel: {channel}")
        if mode not in {"fixed", "static", "off", "breathing", "rainbow"}:
            raise ValueError(f"unsupported lighting mode: {mode}")
        if speed not in {"slowest", "slower", "normal", "faster", "fastest"}:
            raise ValueError(f"unsupported lighting speed: {speed}")
        colors = command.get("colors", [])
        if not isinstance(colors, list) or len(colors) > 8:
            raise ValueError("colors must contain at most eight RGB triples")
        validated = []
        for color in colors:
            if not isinstance(color, list) or len(color) != 3:
                raise ValueError("each color must be an RGB triple")
            validated.append([int(number(v, "color component", 0, 255)) for v in color])
        if mode in {"fixed", "static", "breathing"} and not validated:
            raise ValueError("this lighting mode requires a color")
        self.discover()
        if (
            role == "aura"
            and channel != "sync"
            and mode not in {"fixed", "static"}
            and not isinstance(self.devices.get(role), Aura18F3)
        ):
            raise ValueError("Aura dynamic modes and off affect all channels; use sync")
        native_mode = (
            {"fixed": "static"}.get(mode, mode)
            if role == "aura"
            else {"static": "fixed", "rainbow": "rainbow-flow"}.get(mode, mode)
        )
        if mode in {"rainbow", "off"}:
            validated = []
        if role == "aura":
            validated = validated[:1]
        device = self.require(role)
        try:
            device.set_color(channel, native_mode, validated, speed=speed)
            self.errors.pop(role, None)
        except Exception as error:
            self.failed(role, error)
            raise
        state = {
            "channel": channel,
            "mode": mode,
            "colors": validated,
            "speed": speed,
            "source": "last_command",
        }
        self.lighting_state[role] = state
        return {"applied": True, "device": role, "lighting": state}

    def display(self, command: dict[str, Any]) -> dict[str, Any]:
        enabled = command.get("enabled", True)
        if not isinstance(enabled, bool):
            raise TypeError("enabled must be boolean")
        if not enabled:
            self.display_state["enabled"] = False
            # No undocumented blank/off report: the physical display may persist.
            return {"applied": True, "display": dict(self.display_state)}
        packet = ld_status_report(
            command.get("temperature"),
            command.get("utilization"),
            command.get("power"),
            command.get("unit", "C"),
        )
        self.discover()
        if self.ld_path is None:
            raise RuntimeError("LD-Series 3633:000a display is not connected")
        try:
            if self.ld_handle is None:
                self.ld_handle = hid.device()
                self.ld_handle.open_path(self.ld_path)
            if "ld" not in self.initialized:
                for initial in ld_initial_reports():
                    self._ld_write(initial)
                self.initialized.add("ld")
            self._ld_write(packet)
            self.errors.pop("ld", None)
        except Exception as error:
            self.failed("ld", error)
            raise
        self.display_state = {
            "enabled": True,
            "last_update": time.time(),
            "temperature": command["temperature"],
            "utilization": command["utilization"],
            "power": command["power"],
            "unit": command.get("unit", "C"),
            "source": "last_command",
        }
        return {"applied": True, "display": dict(self.display_state)}

    def _ld_write(self, packet: bytes) -> None:
        written = self.ld_handle.write(packet)
        if written != len(packet):
            raise OSError(f"LD display short write: {written}/{len(packet)}")


manager = DeviceManager()
devices = manager.devices


def disconnect_all() -> None:
    manager.disconnect_all()


def read_status() -> dict[str, Any]:
    return manager.status()


def apply_speeds(fans: list[int], pump: int | None = None) -> dict[str, Any]:
    return manager.apply(fans, pump)


def dispatch(command: dict[str, Any]) -> dict[str, Any]:
    action = command.get("action")
    if action == "status":
        return manager.status()
    if action == "inventory":
        return {"devices": manager.inventory(), "errors": dict(manager.errors)}
    if action == "initialize":
        manager.disconnect_all()
        manager.discover(force=True)
        return manager.status()
    if action == "set":
        if command.get("device") == "smart" and manager.curve_deadline is not None:
            safe = manager.failsafe("manual channel override")
            if safe["errors"]:
                raise RuntimeError(f"cannot leave curve mode safely: {safe['errors']}")
        manager.set_speed(
            str(command["device"]), str(command["channel"]), command["duty"]
        )
        return {"applied": True}
    if action == "apply":
        return manager.apply(
            command.get("fans"), command.get("pump"), command.get("curve", False)
        )
    if action == "curve_disarm":
        return manager.failsafe("curve disabled")
    if action == "lighting":
        return manager.lighting(command)
    if action == "display":
        return manager.display(command)
    if action == "identify":
        index = command.get("index")
        if isinstance(index, bool) or index not in {1, 2, 3}:
            raise ValueError("fan index must be 1, 2, or 3")
        previous = manager.status()["fan_duty"][index - 1]
        if previous is None or previous < FAN_MINIMUM:
            raise RuntimeError("cannot safely identify without a restorable fan duty")
        manager.set_speed("smart", f"fan{index}", max(70, previous))
        try:
            time.sleep(3)
        finally:
            manager.set_speed("smart", f"fan{index}", previous)
        return {"identified": True}
    if action == "shutdown":
        manager.disconnect_all()
        return {"shutdown": True}
    raise ValueError(f"unsupported action: {action}")


def respond(
    request_id: int | None, ok: bool, data: Any = None, error: str | None = None
) -> None:
    payload = {"id": request_id, "ok": ok, "data": data, "error": error}
    sys.stdout.write(
        json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        + "\n"
    )
    sys.stdout.flush()


def request_lines(stream: Any):
    """Poll stdin against the lease deadline without TextIO read-ahead races."""
    try:
        descriptor = stream.fileno()
    except (AttributeError, OSError):
        yield from stream  # In-memory test streams have no idle interval.
        return
    pending = b""
    while True:
        manager.expire_curve()
        timeout = (
            None
            if manager.curve_deadline is None
            else max(0.0, manager.curve_deadline - time.monotonic())
        )
        ready, _, _ = select.select([descriptor], [], [], timeout)
        if not ready:
            manager.expire_curve()
            continue
        chunk = os.read(descriptor, 4096)
        if not chunk:
            if pending.strip():
                yield pending.decode("utf-8")
            return
        pending += chunk
        if len(pending) > 1_000_000:
            raise ValueError("request exceeded 1 MB")
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            yield line.decode("utf-8")


def main() -> None:
    try:
        for raw_line in request_lines(sys.stdin):
            manager.expire_curve()
            request_id = None
            try:
                command = json.loads(raw_line)
                if not isinstance(command, dict):
                    raise TypeError("request must be an object")
                request_id = command.get("id")
                if isinstance(request_id, bool) or not isinstance(request_id, int):
                    raise TypeError("request id must be an integer")
                result = dispatch(command)
                respond(request_id, True, result)
                if command.get("action") == "shutdown":
                    return
            except Exception as error:
                # One failed peripheral must not disconnect the others.
                respond(request_id, False, error=f"{type(error).__name__}: {error}")
    finally:
        manager.failsafe("parent EOF or helper termination")


def terminate(_signal: int, _frame: Any) -> None:
    raise SystemExit(0)


def run() -> int:
    signal.signal(signal.SIGTERM, terminate)
    exit_code = 0
    try:
        main()
    except SystemExit as error:
        exit_code = int(error.code or 0)
    finally:
        disconnect_all()
    if manager.curve_failsafe is not None and not manager.curve_failsafe["applied"]:
        return 2
    return exit_code


if __name__ == "__main__":
    raise SystemExit(run())
