"""Behavior regressions using fake transports only; never access USB hardware."""

import contextlib
import io
import json
import struct
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Resources"))
import device_helper as helper


class FakeDevice:
    def __init__(self, pid):
        self.product_id = pid
        self.calls = []
        self.broken = False
        self.fail_channel = None

    def connect(self):
        self.calls.append("connect")

    def disconnect(self):
        self.calls.append("disconnect")

    def initialize(self):
        self.calls.append("initialize")
        return [
            ("LED 1 accessory 1", "HUE2 LED Strip", ""),
            ("LED 1 accessory 2", "HUE2 LED Strip", ""),
        ]

    def get_status(self):
        self.calls.append("status")
        if self.broken:
            raise OSError("unplugged")
        return [
            (f"Fan {i} {kind}", value, "")
            for i in range(1, 4)
            for kind, value in [
                ("speed", 1000 + i),
                ("duty", 50),
                ("control mode", "PWM"),
            ]
        ]

    def set_fixed_speed(self, channel, duty):
        if channel == self.fail_channel:
            raise OSError("write failed")
        self.calls.append((channel, duty))

    def set_color(self, channel, mode, colors, **kwargs):
        self.calls.append((channel, mode, colors, kwargs))


class FakeHID:
    def __init__(self):
        self.reports = []
        self.short = False
        self.closed = False

    def open_path(self, path):
        self.path = path

    def write(self, report):
        self.reports.append(report)
        return 2 if self.short else len(report)

    def close(self):
        self.closed = True


class DeviceTests(unittest.TestCase):
    def setUp(self):
        self.smart = FakeDevice(0x2006)
        self.aura = FakeDevice(0x19AF)
        self.hid = FakeHID()
        self.m = helper.DeviceManager()
        self.patches = [
            patch.object(
                helper,
                "find_liquidctl_devices",
                side_effect=lambda vendor: (
                    [self.smart] if vendor == 0x1E71 else [self.aura]
                ),
            ),
            patch.object(helper.hid, "enumerate", return_value=[{"path": b"ld"}]),
            patch.object(helper.hid, "device", return_value=self.hid),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def test_missing_kraken_does_not_hide_fans_or_repeat_initialization(self):
        for _ in range(3):
            result = self.m.status()
            self.assertEqual(result["fan_rpm"], [1001, 1002, 1003])
            self.assertIsNone(result["liquid_temperature"])
            self.assertFalse(result["devices"]["kraken"]["connected"])
        self.assertEqual(self.smart.calls.count("initialize"), 1)
        self.assertEqual(self.smart.calls.count("connect"), 1)
        self.assertNotIn("initialize", self.aura.calls)
        self.assertEqual(self.hid.reports, [])

    def test_inventory_does_not_initialize_or_write(self):
        inventory = self.m.inventory()
        self.assertTrue(inventory["ld"]["connected"])
        self.assertEqual(self.smart.calls, ["connect"])
        self.assertEqual(self.aura.calls, ["connect"])
        self.assertEqual(self.hid.reports, [])

    def test_smart_accessory_metadata_preserved(self):
        metadata = self.m.status()["devices"]["smart"]["metadata"]
        self.assertEqual(metadata["LED 1 accessory 2"], "HUE2 LED Strip")

    def test_missing_kraken_apply_is_not_partial_failure(self):
        result = self.m.apply([40, 50, 60], 90)
        self.assertTrue(result["applied"])
        self.assertEqual(result["skipped"], ["kraken"])
        self.assertEqual(self.smart.calls.count("initialize"), 1)
        self.assertIn(("fan3", 60), self.smart.calls)

    def test_partial_apply_identifies_completed_channels_no_retry(self):
        self.smart.fail_channel = "fan2"
        result = self.m.apply([40, 50, 60])
        self.assertFalse(result["applied"])
        self.assertEqual(result["completed_channels"], ["smart/fan1"])
        self.assertEqual(self.smart.calls.count(("fan1", 40)), 1)
        self.assertNotIn(("fan3", 60), self.smart.calls)

    def test_bad_batch_rejected_before_any_write(self):
        with self.assertRaises((ValueError, TypeError)):
            self.m.apply([40, 50, float("nan")])
        self.assertEqual(self.smart.calls, [])

    def test_smart_failure_does_not_disconnect_other_devices(self):
        self.m.inventory()
        self.smart.broken = True
        status = self.m.status()
        self.assertIn("smart", status["errors"])
        self.assertTrue(status["devices"]["aura"]["connected"])
        self.assertTrue(status["devices"]["ld"]["connected"])
        self.assertNotIn("disconnect", self.aura.calls)
        self.assertEqual(self.m.status()["fan_rpm"], [None] * 3)
        self.assertEqual(self.smart.calls.count("connect"), 1)

    def test_smart_led1_routing(self):
        self.m.lighting(
            {
                "device": "smart",
                "channel": "led1",
                "mode": "fixed",
                "colors": [[12, 34, 56]],
            }
        )
        self.assertIn(
            ("led1", "fixed", [[12, 34, 56]], {"speed": "normal"}), self.smart.calls
        )
        self.assertNotIn("initialize", self.aura.calls)

    def test_aura_static_and_dynamic_scope(self):
        self.m.lighting(
            {
                "device": "aura",
                "channel": "led2",
                "mode": "fixed",
                "colors": [[255, 0, 0]],
            }
        )
        self.assertIn(
            ("led2", "static", [[255, 0, 0]], {"speed": "normal"}), self.aura.calls
        )
        with self.assertRaises((ValueError, TypeError)):
            self.m.lighting({"device": "aura", "channel": "led2", "mode": "off"})

    def test_smart_rainbow_alias(self):
        self.m.lighting({"device": "smart", "channel": "led1", "mode": "rainbow"})
        self.assertIn(
            ("led1", "rainbow-flow", [], {"speed": "normal"}), self.smart.calls
        )

    def test_invalid_rgb_and_fan_targets_do_not_write(self):
        with self.assertRaises((ValueError, TypeError)):
            self.m.lighting(
                {
                    "device": "smart",
                    "channel": "fan1",
                    "mode": "fixed",
                    "colors": [[1, 2, 3]],
                }
            )
        with self.assertRaises((ValueError, TypeError)):
            self.m.set_speed("aura", "fan1", 50)
        self.assertEqual(self.smart.calls, [])

    def test_display_initialization_only_once_and_disable_sends_nothing(self):
        request = {
            "enabled": True,
            "temperature": 59.25,
            "utilization": 31,
            "power": 85,
        }
        self.m.display(request)
        self.m.display(request)
        self.assertEqual(len(self.hid.reports), 4)
        self.assertEqual(self.hid.reports[:2], list(helper.ld_initial_reports()))
        self.assertEqual(self.hid.reports[2], helper.ld_status_report(59.25, 31, 85))
        self.m.display({"enabled": False})
        self.assertEqual(len(self.hid.reports), 4)
        self.assertFalse(self.m.display_state["enabled"])

    def test_missing_sensor_is_not_fabricated(self):
        with self.assertRaises((ValueError, TypeError)):
            self.m.display({"enabled": True, "temperature": 50, "utilization": 20})
        self.assertEqual(self.hid.reports, [])

    def test_short_hid_write_is_failure_and_closes_handle(self):
        self.hid.short = True
        with self.assertRaises(OSError):
            self.m.display(
                {"enabled": True, "temperature": 50, "utilization": 20, "power": 80}
            )
        self.assertTrue(self.hid.closed)
        self.assertIn("ld", self.m.errors)

    def test_transport_keeps_ids_after_bad_command(self):
        requests = "\n".join(
            json.dumps(c)
            for c in [
                {"id": 1, "action": "inventory"},
                {"id": 2, "action": "bogus"},
                {"id": 3, "action": "status"},
                {"id": 4, "action": "shutdown"},
            ]
        )
        output = io.StringIO()
        with (
            patch.object(helper, "manager", self.m),
            patch.object(sys, "stdin", io.StringIO(requests)),
            contextlib.redirect_stdout(output),
        ):
            helper.main()
        responses = [json.loads(s) for s in output.getvalue().splitlines()]
        self.assertEqual([r["id"] for r in responses], [1, 2, 3, 4])
        self.assertEqual([r["ok"] for r in responses], [True, False, True, True])
        self.assertEqual(self.smart.calls.count("connect"), 1)


class PacketTests(unittest.TestCase):
    def test_golden_celsius_packet(self):
        expected = bytes.fromhex(
            "106801010b010205005500426d00001f" + "a0" + "16"
        ).ljust(64, b"\0")
        packet = helper.ld_status_report(59.25, 31, 85)
        self.assertEqual(packet, expected)

    def test_fahrenheit_and_big_endian_power(self):
        packet = helper.ld_status_report(50, 100, 300, "F")
        self.assertEqual(packet[8:11], b"\x01\x2c\x01")
        self.assertEqual(struct.unpack(">f", packet[11:15])[0], 122)
        self.assertEqual(packet[16], sum(packet[1:16]) % 256)
        self.assertEqual(len(packet), 64)

    def test_invalid_sensor_numbers_rejected(self):
        for value in (None, True, float("nan"), float("inf"), -1, 151):
            with self.assertRaises((ValueError, TypeError)):
                helper.ld_status_report(value, 10, 30)


if __name__ == "__main__":
    unittest.main()
