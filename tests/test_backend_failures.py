import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackendFailureTests(unittest.TestCase):
    def execute_apply(self, directory, helper=None):
        apply = directory / "power-manager-apply"
        apply.write_bytes((ROOT / "scripts/power-manager-apply").read_bytes())
        apply.chmod(0o755)
        if helper is not None:
            switch = directory / "power-manager-profile-switch"
            switch.write_text(helper)
            switch.chmod(0o755)
        config = directory / "settings.json"
        config.write_text('{"enabled":true}')
        env = dict(os.environ, OMARCHY_UDEV_DIR=str(directory / "udev"))
        return subprocess.run([str(apply), str(config)], capture_output=True, text=True, env=env)

    def test_missing_helper_fails_before_creating_rules(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = self.execute_apply(directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('"success": true', result.stdout)
            self.assertFalse((directory / "udev").exists())

    def test_preserves_helper_failure_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.execute_apply(Path(temporary), "#!/bin/sh\nexit 42\n")
            self.assertEqual(result.returncode, 42)
            self.assertNotIn('"success": true', result.stdout)

    def test_charge_write_failure_does_not_create_persistence_rule(self):
        # A directory at the threshold path guarantees a write failure, even as root.
        harness = 'id() { printf "0\\n"; }; source "$1" 80 "$2" "$3"'
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            battery = directory / "power_supply/BAT0"
            (battery / "charge_control_end_threshold").mkdir(parents=True)
            (battery / "type").write_text("Battery\n")
            persistence = directory / "persistence"
            # Map only the filesystem roots into the fixture. This also exercises
            # the write failure after the separate validation PR is merged.
            script = directory / "power-manager-limit"
            script.write_text((ROOT / "scripts/power-manager-limit").read_text()
                              .replace("/sys/class/power_supply/", str(directory / "power_supply") + "/")
                              .replace("/etc/tmpfiles.d/battery-limiter.conf", str(persistence)))
            result = subprocess.run(["bash", "-c", harness, "bash", str(script),
                                     str(battery), str(persistence)], capture_output=True, text=True)
            self.assertIn("Is a directory", result.stderr)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('"success": true', result.stdout)
            self.assertFalse(persistence.exists())


if __name__ == "__main__":
    unittest.main()
