# Theme corner regression

From an Omarchy Wayland session, run:

```bash
python3 tests/theme_smoke.py
```

The test loads one panel with temporary settings and power management disabled.
It selects a square-corner theme, opens the menu panel, and checks the card and
profile buttons. The test briefly shows a panel, then closes it. It does not
change your installed settings or apply hardware policies.

The test fails on the original hard-coded corners and passes with this fix.
Quickshell and an installed Omarchy shell are required. CI checks source syntax
and whitespace; it does not run this Wayland test on Ubuntu runners.

To capture the verified panel, pass a PNG destination:

```bash
python3 tests/theme_smoke.py /tmp/power-manager-theme.png
```

The checked-in screenshot in `assets/theme-corners-square.png` was captured
with this test. Existing shared-import and detached-widget warnings may appear.
