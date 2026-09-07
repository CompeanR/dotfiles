from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parents[1]
SCRIPT = PLUGIN_DIR / "ram.py"
spec = importlib.util.spec_from_file_location("ram_status", SCRIPT)
assert spec and spec.loader
ram = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = ram
spec.loader.exec_module(ram)

MEMINFO = """\
MemTotal:        8388608 kB
MemFree:         1048576 kB
MemAvailable:    4194304 kB
SwapTotal:       4194304 kB
SwapFree:        3145728 kB
"""


class FormatStatusTest(unittest.TestCase):
    def test_used_available_percent_and_swap(self) -> None:
        self.assertEqual(ram.format_status(MEMINFO), "4/8G 50%  swap 1/4G")

    def test_hides_unused_swap(self) -> None:
        idle_swap = """\
MemTotal:        8388608 kB
MemAvailable:    4194304 kB
SwapTotal:       4194304 kB
SwapFree:        4194304 kB
"""
        self.assertEqual(ram.format_status(idle_swap), "4/8G 50%")

    def test_hides_swap_that_rounds_to_zero(self) -> None:
        tiny_swap = """\
MemTotal:        8388608 kB
MemAvailable:    4194304 kB
SwapTotal:       4194304 kB
SwapFree:        4177920 kB
"""
        self.assertEqual(ram.format_status(tiny_swap), "4/8G 50%")

    def test_warns_when_ram_is_at_least_90_percent(self) -> None:
        tight = """\
MemTotal:        8388608 kB
MemAvailable:     524288 kB
SwapTotal:             0 kB
"""
        self.assertEqual(ram.format_status(tight), "! 7.5/8G 94%")


if __name__ == "__main__":
    unittest.main()
