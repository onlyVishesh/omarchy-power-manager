from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ChargeLimitTests(unittest.TestCase):
    def execute_fixture(self, directory, value, battery, persistence):
        # Keep production validation and writes intact, but map system roots
        # into a disposable fixture so valid requests never touch hardware.
        script = directory / "power-manager-limit"
        script.write_text((ROOT / "scripts/power-manager-limit").read_text()
                          .replace("/sys/class/power_supply/", str(directory / "power_supply") + "/")
                          .replace("/etc/tmpfiles.d/battery-limiter.conf", str(directory / "persistence")))
        harness = 'id() { printf "0\\n"; }; source "$1" "$2" "$3" "$4"'
        return subprocess.run(["bash", "-c", harness, "bash", str(script), str(value),
                               str(battery), str(persistence)], capture_output=True, text=True)

    def test_rejects_out_of_range_and_ambiguous_numbers(self):
        # Simulate the root boundary, but all write targets stay in a disposable fixture.
        harness = 'id() { printf "0\\n"; }; source "$1" "$2" "$3" "$4"'
        with tempfile.TemporaryDirectory() as directory:
            for value in ("-1", "101", "1000", "08", "0100", "nan"):
                with self.subTest(value=value):
                    result = subprocess.run(["bash", "-c", harness, "bash", str(ROOT / "scripts/power-manager-limit"),
                                             value, directory, str(Path(directory) / "persistence")], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Invalid limit format", result.stdout)

    def test_cannot_write_arbitrary_files(self):
        harness = 'id() { printf "0\\n"; }; source "$1" 80 "$2" "$3"'
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "not-a-battery"
            target.mkdir()
            threshold = target / "charge_control_end_threshold"
            threshold.write_text("100\n")
            persistence = Path(directory) / "not-a-system-rule"
            result = subprocess.run(["bash", "-c", harness, "bash", str(ROOT / "scripts/power-manager-limit"),
                                     str(target), str(persistence)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(threshold.read_text(), "100\n")
            self.assertFalse(persistence.exists())

    def test_valid_limits_still_apply_and_manage_persistence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            battery = directory / "power_supply/BAT0"
            battery.mkdir(parents=True)
            (battery / "type").write_text("Battery\n")
            threshold = battery / "charge_control_end_threshold"
            persistence = directory / "persistence"
            for value in (0, 80, 100):
                with self.subTest(value=value):
                    result = self.execute_fixture(directory, value, battery, persistence)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(threshold.read_text(), f"{value}\n")
                    if value == 100:
                        self.assertFalse(persistence.exists())
                    else:
                        self.assertEqual(persistence.read_text(),
                                         f"w {threshold} - - - - {value}\n")

    def test_each_target_boundary_rejects_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            battery = directory / "power_supply/BAT0"
            battery.mkdir(parents=True)
            threshold = battery / "charge_control_end_threshold"
            persistence = directory / "persistence"
            cases = (
                ("Mains", battery, persistence),
                ("Battery", battery / "../BAT0", persistence),
                ("Battery", battery, directory / "other-rule"),
            )
            for kind, target, rule in cases:
                with self.subTest(kind=kind, target=target, rule=rule):
                    (battery / "type").write_text(kind + "\n")
                    threshold.write_text("100\n")
                    result = self.execute_fixture(directory, 80, target, rule)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Invalid battery or persistence path", result.stdout)
                    self.assertEqual(threshold.read_text(), "100\n")
                    self.assertFalse(rule.exists())


if __name__ == "__main__":
    unittest.main()
