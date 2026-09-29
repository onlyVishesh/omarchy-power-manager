# Popup routing regression

From an Omarchy Wayland session, run:

```bash
python3 tests/qml_smoke.py
```

The test loads two isolated widget instances with temporary settings and power
management disabled. It opens the standalone menu panel and asserts that the
bar popup remains closed. The test briefly shows a panel, then closes it.
It does not change your installed settings or apply hardware policies.

The test fails on the original routing and passes with this fix. Quickshell
and an installed Omarchy shell are required. CI checks source syntax and
whitespace. It does not run this Wayland integration test on Ubuntu runners.

Shared-import and detached-widget warnings can appear. The existing duplicate
IPC-target warning with two widgets is outside this routing fix.
