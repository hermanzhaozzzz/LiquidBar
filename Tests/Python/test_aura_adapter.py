"""Golden Aura reports from the captured board config and OpenRGB."""

import unittest
from unittest.mock import patch

from test_device_helper import FakeDevice, helper


class AuraTransport:
    def __init__(self):
        self.writes = []
        self.short = False
        self.fixed = 5
        self.argb = 1

    def clear_enqueued_reports(self):
        pass

    def write(self, report):
        self.writes.append(bytes(report))
        return 1 if self.short else len(report)

    def read(self, length):
        reply = bytearray(65)
        if self.writes[-1][1] == 0x82:
            reply[:2] = bytes([0xEC, 2])
            reply[2:17] = b"AULA3-6K75-0207\0"
        else:
            reply[:2] = bytes([0xEC, 0x30])
            reply[4 + 2] = self.argb
            reply[4 + 0x1B] = self.fixed
            reply[4 + 0x1D] = 2
        return list(reply)


class AuraProtocolTests(unittest.TestCase):
    def setUp(self):
        self.driver = FakeDevice(0x18F3)
        self.driver.device = AuraTransport()
        self.adapter = helper.Aura18F3(self.driver)

    def test_argb_uses_fifth_offset_and_0020_mask_without_flash_commit(self):
        self.adapter.initialize()
        self.adapter.set_color("led2", "static", [[0, 0, 255]])
        packets = self.driver.device.writes
        self.assertEqual(len(packets), 5)
        self.assertEqual(packets[2], bytes.fromhex("ec52530001").ljust(65, b"\0"))
        self.assertEqual(packets[3], bytes.fromhex("ec3501000001").ljust(65, b"\0"))
        expected = bytearray(65)
        expected[:5] = bytes.fromhex("ec36002000")
        expected[20:23] = b"\0\0\xff"
        self.assertEqual(packets[4], bytes(expected))
        self.assertFalse(any(p[1] == 0x3F for p in packets))

    def test_sync_only_writes_present_fixed_and_argb_groups(self):
        self.adapter.initialize()
        self.adapter.set_color("sync", "static", [[255, 0, 0]])
        packets = self.driver.device.writes[3:]
        self.assertEqual(len(packets), 4)
        self.assertEqual([p[2] for p in packets if p[1] == 0x35], [0, 1])
        self.assertEqual(
            [p[2:4] for p in packets if p[1] == 0x36], [b"\0\x1f", b"\0\x20"]
        )
        with self.assertRaises(ValueError):
            self.adapter.set_color("led3", "static", [[255, 0, 0]])

    def test_impossible_geometry_rejected_before_lighting_write(self):
        self.driver.device.fixed = 16
        with self.assertRaises(ValueError):
            self.adapter.initialize()
        self.assertEqual([p[1] for p in self.driver.device.writes], [0x82, 0xB0])

    def test_no_gen1_until_explicit_lighting(self):
        manager = helper.DeviceManager()
        with (
            patch.object(
                helper,
                "find_liquidctl_devices",
                side_effect=lambda vendor: [self.driver] if vendor == 0x0B05 else [],
            ),
            patch.object(helper.hid, "enumerate", return_value=[]),
        ):
            manager.status()
            self.assertEqual(self.driver.device.writes, [])
            manager.lighting(
                {
                    "device": "aura",
                    "channel": "led2",
                    "mode": "fixed",
                    "colors": [[0, 0, 255]],
                }
            )
            self.assertEqual(len(self.driver.device.writes), 5)
            self.assertEqual(
                manager.inventory()["aura"]["channels"], ["sync", "led1", "led2"]
            )

    def test_short_write_fails(self):
        self.driver.device.short = True
        with self.assertRaises(OSError):
            self.adapter.initialize()


if __name__ == "__main__":
    unittest.main()
