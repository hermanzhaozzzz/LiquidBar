#!/usr/bin/env python3
"""Read device status, or explicitly test and restore connected Smart fan channels.

--write is required for speed changes. Only increase duty by five points, then
restore the observed duty in finally. Lights and LD display are never changed.
SPDX-License-Identifier: GPL-3.0-or-later
"""

# Every driver failure must still reach restoration and reporting.
# ruff: noqa: BLE001
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Resources"))
import device_helper


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--channels", nargs="+", type=int, choices=[1, 2, 3])
    parser.add_argument(
        "--observe-missing-tach",
        action="store_true",
        help="Allow one explicitly selected spinning fan without tach feedback; requires human observation.",
    )
    args = parser.parse_args()
    if args.observe_missing_tach and (
        not args.write or not args.channels or len(args.channels) != 1
    ):
        parser.error("--observe-missing-tach requires --write and one --channels value")
    result: dict = {}
    originals: dict[int, int] = {}
    tested: list[int] = []
    success = True
    try:
        initial = device_helper.read_status()
        result["initial"] = initial
        if args.write:
            channels = args.channels or [
                i for i in range(1, 4) if initial["fan_modes"][i - 1]
            ]
            if not channels:
                raise RuntimeError("no connected Smart fan channels were detected")
            for index in channels:
                duty = initial["fan_duty"][index - 1]
                if (
                    initial["fan_modes"][index - 1] is None
                    or not initial["fan_rpm"][index - 1]
                ):
                    if not args.observe_missing_tach:
                        raise RuntimeError(
                            f"fan{index} lacks tach feedback; select it alone with --observe-missing-tach"
                        )
                    result["human_observation_required"] = [index]
                    result["physical_speed_change_verified"] = False
                if not isinstance(duty, int) or not 30 <= duty <= 100:
                    raise RuntimeError(
                        f"fan{index} duty cannot be restored safely: {duty}"
                    )
                originals[index] = duty
            for index, duty in originals.items():
                # Add before the call: a timeout can still mean the write happened.
                tested.append(index)
                device_helper.manager.set_speed(
                    "smart", f"fan{index}", min(100, duty + 5)
                )
            time.sleep(4)
            observed = device_helper.read_status()
            result["observed"] = observed
            for index, duty in originals.items():
                if observed["fan_duty"][index - 1] != min(100, duty + 5):
                    raise RuntimeError(f"fan{index} duty readback mismatch")
            result["duty_write_readback_verified"] = True
    except Exception as error:
        success = False
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        restore_errors = {}
        for index in tested:
            try:
                device_helper.manager.set_speed(
                    "smart", f"fan{index}", originals[index]
                )
            except Exception as error:
                restore_errors[str(index)] = str(error)
        if tested:
            time.sleep(2)
            try:
                restored = device_helper.read_status()
                result["restored"] = restored
                result["restore_verified"] = not restore_errors and all(
                    restored["fan_duty"][i - 1] == originals[i] for i in tested
                )
            except Exception as error:
                restore_errors["readback"] = str(error)
                result["restore_verified"] = False
            success = success and result["restore_verified"]
        if restore_errors:
            result["restore_errors"] = restore_errors
        device_helper.disconnect_all()
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if success else 2


if __name__ == "__main__":
    raise SystemExit(main())
