from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from quantscope_bench.telemetry.energy import (
    RaplEnergySource,
    UnavailableEnergySource,
    delta_reading,
    select_energy_source,
)


class EnergySourceTests(unittest.TestCase):
    def test_reads_rapl_microjoules_as_joules(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            energy_path = root / "intel-rapl:0" / "energy_uj"
            energy_path.parent.mkdir()
            energy_path.write_text("2500000\n", encoding="utf-8")
            source = RaplEnergySource(root)

            self.assertTrue(source.available())
            self.assertEqual(source.read_joules(), 2.5)

    def test_reports_unavailable_or_decreasing_counters(self) -> None:
        source = select_energy_source((UnavailableEnergySource(),))
        self.assertFalse(delta_reading(source, None, None).available)

        rollover = delta_reading(RaplEnergySource(Path("/missing")), 3.0, 2.0)
        self.assertFalse(rollover.available)