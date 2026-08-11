#!/usr/bin/env python3
"""Run a small, reversible LiquidBar hardware test.

This script intentionally changes fan and pump duties. It always attempts to
restore the exact values observed before the test.

SPDX-License-Identifier: GPL-3.0-or-later
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPOSITORY / "Resources"))

import device_helper  # noqa: E402


def validate(status: dict) -> tuple[list[int], int]:
    fans = status.get("fan_duty")
    pump = status.get("pump_duty")
    if not isinstance(fans, list) or len(fans) != 3 or not all(isinstance(v, int) for v in fans):
        raise RuntimeError(f"invalid initial fan duties: {fans!r}")
    if not isinstance(pump, int):
        raise RuntimeError(f"invalid initial pump duty: {pump!r}")
    if not all(30 <= value <= 100 for value in fans) or not 50 <= pump <= 100:
        raise RuntimeError(f"initial duties are outside LiquidBar safety limits: {fans!r}, {pump!r}")
    return fans, pump


def main() -> int:
    initial = device_helper.read_status()
    original_fans, original_pump = validate(initial)
    test_fans = [min(100, value + 5) for value in original_fans]
    test_pump = min(100, original_pump + 5)
    restored = False
    result: dict = {
        "initial": initial,
        "test_targets": {"fans": test_fans, "pump": test_pump},
    }

    try:
        device_helper.apply_speeds(test_fans, test_pump)
        time.sleep(4)
        observed = device_helper.read_status()
        result["observed"] = observed
        observed_fans, observed_pump = validate(observed)
        if observed_fans != test_fans or observed_pump != test_pump:
            raise RuntimeError(
                f"device did not report requested duties: {observed_fans!r}, {observed_pump!r}"
            )
    finally:
        try:
            device_helper.apply_speeds(original_fans, original_pump)
            time.sleep(2)
            restored_status = device_helper.read_status()
            result["restored"] = restored_status
            restored_fans, restored_pump = validate(restored_status)
            restored = restored_fans == original_fans and restored_pump == original_pump
        except Exception as error:
            result["restore_error"] = f"{type(error).__name__}: {error}"
        finally:
            device_helper.disconnect_all()

    result["restore_verified"] = restored
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if restored else 2


if __name__ == "__main__":
    raise SystemExit(main())
