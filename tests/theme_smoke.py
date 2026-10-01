"""Verify panel corners with power automation disabled.

Run manually from an Omarchy Wayland session. Optionally pass a PNG destination.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
shell = Path("/usr/share/omarchy/shell")
if not shutil.which("quickshell") or not shell.is_dir():
    sys.exit("The UI smoke test requires Quickshell and an installed Omarchy shell")
display = os.environ.get("WAYLAND_DISPLAY", "")
if not display:
    sys.exit("Run the UI smoke test inside a Wayland session")
if not display.startswith("/"):
    display = str(Path(os.environ["XDG_RUNTIME_DIR"]) / display)

with tempfile.TemporaryDirectory(prefix="power-manager-ui-") as directory:
    temporary = Path(directory)
    home = temporary / "home"
    (home / ".config").mkdir(parents=True)
    (home / ".config/onlyvishesh.power-manager.json").write_text('{"enabled":false}\n')
    imports = temporary / "imports"
    imports.mkdir()
    (imports / "qs").symlink_to(shell, target_is_directory=True)
    runtime = temporary / "runtime"
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
               WAYLAND_DISPLAY=display, QML_IMPORT_PATH=str(imports),
               QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="generic",
               POWER_MANAGER_PANEL=(ROOT / "Panel.qml").as_uri())
    env.pop("POWER_MANAGER_SCREENSHOT", None)
    if len(sys.argv) > 1:
        env["POWER_MANAGER_SCREENSHOT"] = str(Path(sys.argv[1]).resolve())
    try:
        result = subprocess.run(["quickshell", "-p", str(ROOT / "tests/theme_smoke.qml"), "--no-color"],
                                capture_output=True, text=True, env=env, timeout=12)
    except subprocess.TimeoutExpired as error:
        print((error.stdout or b"").decode() + (error.stderr or b"").decode(), end="")
        sys.exit("Panel smoke test timed out")
    print(result.stdout + result.stderr, end="")
    if result.returncode or "POWER_MANAGER_QML_SMOKE_PASS" not in result.stdout + result.stderr:
        sys.exit("Panel smoke test failed")
