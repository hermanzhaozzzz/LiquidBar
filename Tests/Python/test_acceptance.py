"""Independent recovery checks. All USB transports are replaced with fakes."""

import unittest
from types import SimpleNamespace
from unittest.mock import patch

from test_device_helper import FakeHID, helper


class AuraCapturedConfigurationAcceptance(unittest.TestCase):
    def test_x570_argb_uses_slot_five_and_does_not_save_device_storage(self):
        # Captured EC B0 response from this X570 board. The four-byte response
        # header is not part of OpenRGB's 60-byte config_table.
        captured = bytes.fromhex(
            "ec 30 00 00 1e 9f 01 01 00 00 78 3c 00 00 00 00 "
            "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 05 "
            "06 02 01 f4 00 00 00 00 00 00 00 00 00 00 00 00 "
            "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "
            "00 "
        )
        self.assertEqual(len(captured), 65)
        firmware = (b"\xec\x02" + b"AULA3-6K75-0207\0").ljust(65, b"\0")
        reports = []
        replies = iter([firmware, captured])
        transport = SimpleNamespace(
            clear_enqueued_reports=lambda: None,
            read=lambda size: next(replies),
            write=lambda packet: reports.append(bytes(packet)) or len(packet),
        )
        adapter = helper.Aura18F3(SimpleNamespace(device=transport))
        adapter.initialize()
        self.assertEqual(set(adapter.groups), {"led1", "led2"})
        reports.clear()
        adapter.set_color("led2", "static", [[0, 0, 255]])
        expected_mode = bytes.fromhex("ec3501000001").ljust(65, b"\0")
        expected_color = bytes.fromhex(
            "ec360020000000000000000000000000000000000000ff"
        ).ljust(65, b"\0")
        self.assertEqual(reports, [expected_mode, expected_color])
        self.assertFalse(any(packet[:2] == b"\xec\x3f" for packet in reports))


class PeripheralRecoveryAcceptance(unittest.TestCase):
    def test_ld_recovers_after_transient_write_error_without_replug_or_app_restart(self):
        device = FakeHID()
        device.short = True
        manager = helper.DeviceManager()
        command = {"enabled": True, "temperature": 55, "utilization": 20, "power": 65}
        with (
            patch.object(helper, "find_liquidctl_devices", return_value=[]),
            patch.object(helper.hid, "enumerate", return_value=[{"path": b"same-display"}]),
            patch.object(helper.hid, "device", return_value=device),
            patch.object(helper.time, "monotonic", return_value=0) as clock,
        ):
            with self.assertRaises(OSError):
                manager.display(command)
            self.assertFalse(manager.inventory()["ld"]["connected"])
            device.short = False
            clock.return_value = 16  # A normal later discovery cycle; no replug.
            inventory = manager.inventory()
            self.assertTrue(inventory["ld"]["connected"], "The UI must be able to retry the same connected display")
            manager.display(command)
            self.assertNotIn("ld", manager.errors)
            self.assertTrue(manager.display_state["enabled"])


if __name__ == "__main__":
    unittest.main()
