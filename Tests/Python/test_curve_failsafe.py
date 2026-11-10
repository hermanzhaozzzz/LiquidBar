"""Subprocess lifecycle checks with fake USB devices only."""

import json
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from test_device_helper import FakeDevice, helper

BOOTSTRAP = r"""
import pathlib, signal, sys
sys.path.insert(0, sys.argv[1])
from test_device_helper import FakeDevice, helper
trace = pathlib.Path(sys.argv[2])
class RecordingSmart(FakeDevice):
    def set_fixed_speed(self, channel, duty):
        if duty == 100 and channel == 'fan2' and trace.with_suffix('.fail').exists():
            raise OSError('injected fallback failure')
        with trace.open("a") as out:
            out.write(f"{channel}:{duty}\n")
        super().set_fixed_speed(channel, duty)
smart = RecordingSmart(0x2006)
helper.find_liquidctl_devices = lambda vendor: [smart] if vendor == 0x1e71 else []
helper.hid.enumerate = lambda *args: []
helper.CURVE_TIMEOUT = 0.3
signal.signal(signal.SIGTERM, helper.terminate)
raise SystemExit(helper.run())
"""


class CurveLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.trace = Path(self.directory.name) / "writes.txt"
        self.process = subprocess.Popen(
            [
                sys.executable,
                "-B",
                "-u",
                "-c",
                BOOTSTRAP,
                str(Path(__file__).parent),
                str(self.trace),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.cleanup_process)

    def cleanup_process(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=3)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()

    def apply(self, curve=True):
        request = {"id": 1, "action": "apply", "fans": [40, 50, 60], "curve": curve}
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        self.assertTrue(response["ok"])
        self.assertTrue(response["data"]["applied"])

    def writes(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def assert_full_speed(self):
        self.assertEqual(self.writes()[-3:], ["fan1:100", "fan2:100", "fan3:100"])
        self.assertEqual(len(self.writes()), 6)

    def test_parent_eof_armed_curve_sets_full_speed(self):
        self.apply()
        self.process.stdin.close()
        self.process.wait(timeout=3)
        self.assert_full_speed()

    def test_sigterm_armed_curve_sets_full_speed(self):
        self.apply()
        self.process.send_signal(signal.SIGTERM)
        self.process.wait(timeout=3)
        self.assert_full_speed()

    def test_eof_and_sigterm_together_do_not_interrupt_failsafe(self):
        self.apply()
        self.process.stdin.close()
        self.process.send_signal(signal.SIGTERM)
        self.process.wait(timeout=3)
        self.assert_full_speed()

    def test_heartbeat_expiry_sets_full_speed_without_parent_exit(self):
        self.apply()
        deadline = time.monotonic() + 3
        while len(self.writes()) < 6 and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertIsNone(self.process.poll())
        self.assert_full_speed()
        # EOF after expiry must not replay the failsafe.
        self.process.stdin.close()
        self.process.wait(timeout=3)
        self.assert_full_speed()

    def test_manual_targets_survive_normal_eof(self):
        self.apply(curve=False)
        self.process.stdin.close()
        self.process.wait(timeout=3)
        self.assertEqual(self.writes(), ["fan1:40", "fan2:50", "fan3:60"])

    def test_failed_fallback_exits_nonzero_for_parent_to_report(self):
        self.apply()
        self.trace.with_suffix(".fail").touch()
        self.process.stdin.close()
        self.process.wait(timeout=3)
        self.assertEqual(self.process.returncode, 2)
        self.assertIn("incomplete", self.process.stderr.read())

    def test_explicit_disarm_sets_full_speed_and_reports(self):
        self.apply()
        self.process.stdin.write('{"id":2,"action":"curve_disarm"}\n')
        self.process.stdin.flush()
        result = json.loads(self.process.stdout.readline())
        self.assertTrue(result["data"]["applied"])
        self.assert_full_speed()


class CurveFailureTests(unittest.TestCase):
    def test_failed_failsafe_reports_failure_not_success(self):
        manager = helper.DeviceManager()
        smart = FakeDevice(0x2006)
        smart.fail_channel = "fan2"
        manager.devices["smart"] = smart
        manager.curve_deadline = time.monotonic() + 10
        with self.assertLogs(helper.logger, level="ERROR"):
            result = manager.failsafe("test")
        self.assertFalse(result["applied"])
        self.assertIn("smart/fan2", result["errors"])
        self.assertIn(("fan1", 100), smart.calls)
        self.assertIn(("fan3", 100), smart.calls)

    def test_successful_manual_batch_disarms_without_fullspeed_pulse(self):
        manager = helper.DeviceManager()
        smart = FakeDevice(0x2006)
        with (
            patch.object(
                helper,
                "find_liquidctl_devices",
                side_effect=lambda vendor: [smart] if vendor == 0x1E71 else [],
            ),
            patch.object(helper.hid, "enumerate", return_value=[]),
        ):
            manager.apply([40, 50, 60], curve=True)
            self.assertIsNotNone(manager.curve_deadline)
            manager.apply([60, 65, 70])
            self.assertIsNone(manager.curve_deadline)
            manager.failsafe("EOF")
        self.assertNotIn(("fan1", 100), smart.calls)


if __name__ == "__main__":
    unittest.main()
