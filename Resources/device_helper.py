#!/usr/bin/env python3
"""Persistent liquidctl bridge for LiquidBar.

Copyright (C) 2026 Huanan Zhao
SPDX-License-Identifier: GPL-3.0-or-later
"""

from __future__ import annotations

import json
import logging
import sys
import time
from typing import Any

from liquidctl.driver import find_liquidctl_devices


logging.getLogger("liquidctl").setLevel(logging.CRITICAL)

KRAKEN_PRODUCTS = {0x2007}
SMART_PRODUCTS = {0x2006}
VENDOR_NZXT = 0x1E71
FAN_MINIMUM = 30
PUMP_MINIMUM = 50

devices: dict[str, Any] = {}


def disconnect_all() -> None:
    for device in devices.values():
        try:
            device.disconnect()
        except Exception:
            pass
    devices.clear()


def discover(initialize: bool = True) -> None:
    disconnect_all()
    for device in find_liquidctl_devices(vendor=VENDOR_NZXT):
        product_id = getattr(device, "product_id", None)
        role = None
        if product_id in KRAKEN_PRODUCTS:
            role = "kraken"
        elif product_id in SMART_PRODUCTS:
            role = "smart"
        if role is None:
            continue
        device.connect()
        if initialize:
            device.initialize()
        devices[role] = device


def ensure_devices() -> None:
    if "kraken" not in devices or "smart" not in devices:
        discover()


def normalize_status(items: list[tuple[str, Any, str]]) -> dict[str, Any]:
    return {label: value for label, value, _unit in items}


def read_status() -> dict[str, Any]:
    ensure_devices()
    kraken = normalize_status(devices["kraken"].get_status())
    smart = normalize_status(devices["smart"].get_status())
    return {
        "liquid_temperature": kraken.get("Liquid temperature"),
        "pump_rpm": kraken.get("Pump speed"),
        "pump_duty": kraken.get("Pump duty"),
        "fan_rpm": [smart.get(f"Fan {index} speed") for index in range(1, 4)],
        "fan_duty": [smart.get(f"Fan {index} duty") for index in range(1, 4)],
        "fan_modes": [smart.get(f"Fan {index} control mode") for index in range(1, 4)],
        "noise_level": smart.get("Noise level"),
    }


def set_speed(device_role: str, channel: str, duty: int) -> None:
    ensure_devices()
    if device_role == "smart":
        if channel not in {"fan1", "fan2", "fan3", "sync"}:
            raise ValueError(f"unsupported fan channel: {channel}")
        duty = max(FAN_MINIMUM, min(100, int(duty)))
    elif device_role == "kraken":
        if channel != "pump":
            raise ValueError(f"unsupported pump channel: {channel}")
        duty = max(PUMP_MINIMUM, min(100, int(duty)))
    else:
        raise ValueError(f"unsupported device role: {device_role}")
    devices[device_role].set_fixed_speed(channel, duty)


def apply_speeds(fans: list[int], pump: int) -> None:
    if len(fans) != 3:
        raise ValueError("exactly three fan duties are required")
    for index, duty in enumerate(fans, start=1):
        set_speed("smart", f"fan{index}", duty)
    set_speed("kraken", "pump", pump)


def identify_fan(index: int, duty: int = 70, duration: float = 3.0) -> None:
    if index not in {1, 2, 3}:
        raise ValueError("fan index must be 1, 2, or 3")
    status = read_status()
    previous = status["fan_duty"][index - 1] or 50
    set_speed("smart", f"fan{index}", duty)
    try:
        time.sleep(max(1.0, min(5.0, duration)))
    finally:
        set_speed("smart", f"fan{index}", int(previous))


def dispatch(command: dict[str, Any]) -> dict[str, Any]:
    action = command.get("action")
    if action == "status":
        return read_status()
    if action == "initialize":
        discover(initialize=True)
        return {"devices": sorted(devices.keys())}
    if action == "set":
        set_speed(str(command["device"]), str(command["channel"]), int(command["duty"]))
        return {"applied": True}
    if action == "apply":
        apply_speeds([int(value) for value in command["fans"]], int(command["pump"]))
        return {"applied": True}
    if action == "identify":
        identify_fan(int(command["index"]))
        return {"identified": True}
    if action == "shutdown":
        disconnect_all()
        return {"shutdown": True}
    raise ValueError(f"unsupported action: {action}")


def respond(request_id: int | None, ok: bool, data: Any = None, error: str | None = None) -> None:
    payload = {"id": request_id, "ok": ok, "data": data, "error": error}
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main() -> None:
    for raw_line in sys.stdin:
        request_id = None
        try:
            command = json.loads(raw_line)
            request_id = command.get("id")
            result = dispatch(command)
            respond(request_id, True, result)
            if command.get("action") == "shutdown":
                return
        except Exception as error:
            disconnect_all()
            respond(request_id, False, error=f"{type(error).__name__}: {error}")


if __name__ == "__main__":
    try:
        main()
    finally:
        disconnect_all()
