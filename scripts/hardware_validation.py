#!/usr/bin/env python3
"""Explicit, supervised peripheral checks using real CPU telemetry.

No command runs without --write. Lighting remains at the requested test colors;
the devices do not expose their previous lighting settings for restoration.
No blank/off command is sent at exit. This LD unit goes blank after updates stop.
SPDX-License-Identifier: GPL-3.0-or-later
"""

from __future__ import annotations

import argparse
import ctypes
import datetime
import json
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Resources"))
import device_helper


class DisplayOnlyManager(device_helper.DeviceManager):
    """Use production display packets without opening unrelated controllers."""

    def discover(self, force: bool = False) -> None:
        if not force and time.monotonic() - self.last_scan < 15:
            return
        self.last_scan = time.monotonic()
        displays = device_helper.hid.enumerate(0x3633, 10)
        path = displays[0]["path"] if displays else None
        if path != self.ld_path:
            self.disconnect("ld")
        self.ld_path = path


class CPULoad:
    def __init__(self) -> None:
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.lib.mach_host_self.restype = ctypes.c_uint32
        self.lib.host_statistics.argtypes = [
            ctypes.c_uint32,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_int32),
            ctypes.POINTER(ctypes.c_uint32),
        ]
        self.previous: list[int] | None = None

    def sample(self) -> float | None:
        ticks = (ctypes.c_int32 * 4)()
        count = ctypes.c_uint32(4)
        status = self.lib.host_statistics(
            self.lib.mach_host_self(), 3, ticks, ctypes.byref(count)
        )
        if status != 0 or count.value != 4:
            raise RuntimeError(f"host_statistics failed: {status}, count={count.value}")
        current = [ctypes.c_uint32(value).value for value in ticks]
        previous, self.previous = self.previous, current
        if previous is None:
            return None
        delta = [(a - b) % (2**32) for a, b in zip(current, previous, strict=True)]
        total = sum(delta)
        if not total:
            return None
        return 100 * (delta[0] + delta[1] + delta[3]) / total


class CPUReader:
    """Only the native helper's read-only CPU action is exposed here."""

    def __init__(self, executable: Path) -> None:
        self.process = subprocess.Popen(
            [str(executable), "--motherboard-helper"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None,
        )
        self.buffer = b""
        self.next_id = 0

    def read(self) -> dict:
        self.next_id += 1
        assert self.process.stdin and self.process.stdout
        self.process.stdin.write(
            (json.dumps({"id": self.next_id, "action": "cpu"}) + "\n").encode()
        )
        self.process.stdin.flush()
        deadline = time.monotonic() + 10
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if (
                remaining <= 0
                or not select.select([self.process.stdout], [], [], remaining)[0]
            ):
                raise TimeoutError("read-only CPU telemetry timed out")
            chunk = os.read(self.process.stdout.fileno(), 4096)
            if not chunk:
                raise RuntimeError("read-only CPU helper exited unexpectedly")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        result = json.loads(line)
        if result.get("id") != self.next_id or result.get("error"):
            raise RuntimeError(f"CPU telemetry response failed: {result}")
        return result["cpu"]

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        self.process.wait(timeout=10)
        if self.process.returncode:
            raise RuntimeError(f"CPU helper exited {self.process.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["lighting", "display"])
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--seconds", type=int, default=40)
    parser.add_argument(
        "--native-helper", type=Path, default=ROOT / ".build/debug/LiquidBar"
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.write:
        parser.error(
            "--write is required; this script changes physical lights or the display"
        )
    if not 2 <= args.seconds <= 900:
        parser.error("--seconds must be 2...900")
    report = {
        "phase": args.phase,
        "started_at": datetime.datetime.now().astimezone().isoformat(),
        "human_validation": "pending",
        "samples": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save() -> None:
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    def interrupted(_signal: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    cpu = None
    display_manager = None
    result = 0
    try:
        if args.phase == "lighting":
            before = device_helper.manager.status()
            report["before_fan_duty"] = before["fan_duty"]
            for role, channel, color in [
                ("smart", "led1", [255, 0, 0]),
                ("aura", "sync", [0, 0, 255]),
            ]:
                command = {
                    "device": role,
                    "channel": channel,
                    "mode": "fixed",
                    "colors": [color],
                }
                response = device_helper.manager.lighting(command)
                report["samples"].append({"command": command, "response": response})
                save()
            after = device_helper.manager.status()
            report["after_fan_duty"] = after["fan_duty"]
            report["fan_duties_unchanged"] = before["fan_duty"] == after["fan_duty"]
        else:
            display_manager = DisplayOnlyManager()
            cpu = CPUReader(args.native_helper)
            load = CPULoad()
            load.sample()
            time.sleep(1)
            deadline = time.monotonic() + args.seconds
            while time.monotonic() < deadline:
                utilization = load.sample()
                metrics = cpu.read()
                if (
                    utilization is None
                    or metrics.get("temperature") is None
                    or metrics.get("powerWatts") is None
                ):
                    raise RuntimeError(
                        "all three real CPU measurements are required; no placeholders sent"
                    )
                command = {
                    "enabled": True,
                    "temperature": metrics["temperature"],
                    "utilization": utilization,
                    "power": metrics["powerWatts"],
                    "unit": "C",
                }
                response = display_manager.display(command)
                sample = {
                    "time": datetime.datetime.now().astimezone().isoformat(),
                    "sent": command,
                    "response": response,
                }
                report["samples"].append(sample)
                save()
                print(
                    json.dumps(
                        {
                            "temperature_C": command["temperature"],
                            "load_percent": utilization,
                            "power_W": command["power"],
                            "write_acknowledged": response["applied"],
                        }
                    ),
                    flush=True,
                )
                time.sleep(2)
    except KeyboardInterrupt:
        report["interrupted"] = True
    except Exception as error:  # noqa: BLE001 - evidence must survive failed hardware I/O.
        report["error"] = f"{type(error).__name__}: {error}"
        result = 2
    finally:
        device_helper.disconnect_all()
        if display_manager is not None:
            display_manager.disconnect_all()
        if cpu is not None:
            try:
                cpu.close()
            except Exception as error:  # noqa: BLE001
                report["cpu_helper_close_error"] = str(error)
                result = 2
        report["finished_at"] = datetime.datetime.now().astimezone().isoformat()
        save()
    print(
        json.dumps(
            {
                "output": str(args.output),
                "samples": len(report["samples"]),
                "error": report.get("error"),
                "human_validation": "pending",
            }
        ),
        flush=True,
    )
    return result


if __name__ == "__main__":
    raise SystemExit(main())
