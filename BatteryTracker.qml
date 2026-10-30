import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property string batteryPath: ""
  property var batteryPaths: []
  property var limitPaths: []
  property int batteryCount: 0
  property bool present: false
  property int capacity: -1
  property string status: ""
  property int cycleCount: -1
  property real full: -1
  property real fullDesign: -1
  property string capacityUnit: "Wh"
  readonly property real healthPct: (full > 0 && fullDesign > 0) ? (full / fullDesign * 100) : -1

  property bool supported: false
  property int limit: 100
  property bool limitUniform: true
  signal limitSyncRequired(int limit)
  property bool applying: false
  property bool justApplied: false
  readonly property string tmpfilesPath: "/etc/tmpfiles.d/battery-limiter.conf"

  property string lastLogDate: ""
  property var healthHistory: []

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/onlyvishesh.power-manager"
  readonly property string healthLog: stateDir + "/health-log.tsv"

  function refresh() { if (!probe.running) probe.running = true }

  function validPath(p) {
    return /^\/sys\/class\/power_supply\/[A-Za-z0-9_][A-Za-z0-9_.:@-]*$/.test(p)
  }

  function parseProbe(raw) {
    var rows = Model.parseBatteryProbe(raw)
    var agg = Model.aggregateBatteries(rows, function(p) { return root.validPath(p) })

    root.batteryCount = agg.batteryCount
    root.batteryPaths = agg.batteryPaths
    root.limitPaths = agg.limitPaths
    root.batteryPath = agg.batteryPaths.length > 0 ? agg.batteryPaths[0] : ""
    root.present = agg.present
    root.supported = agg.supported
    root.limitUniform = agg.limitUniform
    root.capacity = agg.capacity
    root.status = (agg.status || "").slice(0, 32)
    root.cycleCount = agg.cycleCount
    root.full = agg.full
    root.fullDesign = agg.fullDesign
    root.capacityUnit = agg.capacityUnit

    var oldLimit = root.limit
    root.limit = agg.supported ? agg.limit : 100

    if (root.justApplied) {
      root.justApplied = false
      if (root.limit === oldLimit) root.limitSyncRequired(root.limit)
    }

    root.logHealth()
  }

  function setLimit(pct) {
    pct = parseInt(pct, 10)
    if (isNaN(pct) || pct < 50 || pct > 100) return
    if (!root.supported || root.limitPaths.length === 0 || applyProc.running) return
    for (var i = 0; i < root.limitPaths.length; i++) {
      if (!root.validPath(root.limitPaths[i])) return
    }
    root.applying = true
    applyProc.pct = pct
    applyProc.command = ["pkexec", "/usr/local/libexec/omarchy-power-manager/power-manager-limit", String(pct), root.limitPaths.join(","), root.tmpfilesPath]
    applyProc.running = true
  }


  function logHealth() {
    if (root.healthPct <= 0 || appendProc.running) return
    var today = new Date().toISOString().slice(0, 10)
    if (root.lastLogDate === today) return
    root.lastLogDate = today
    appendProc.command = ["sh", "-c",
      "d=\"${1%/*}\"; mkdir -p \"$d\" 2>/dev/null || exit 0; " +
      "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 1 \"$1\" | grep -q \"^$2\"; } && exit 0; " +
      "tmp=$(mktemp \"$d/.health-XXXXXX\") || exit 0; " +
      "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 400 \"$1\"; " +
      "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\"; } > \"$tmp\" " +
      "&& mv -f \"$tmp\" \"$1\" || rm -f \"$tmp\"",
      "sh", root.healthLog, today, root.healthPct.toFixed(1),
      String(root.cycleCount), String(root.full), String(root.fullDesign), root.capacityUnit]
    appendProc.running = true
  }

  function parseHistory(raw) {
    var out = []
    var lines = raw.split("\n")
    for (var j = 0; j < lines.length && out.length < 400; j++) {
      var p = lines[j].split("\t")
      if (p.length < 3 || !/^\d{4}-\d{2}-\d{2}$/.test(p[0])) continue
      var h = parseFloat(p[1])
      var c = parseInt(p[2], 10)
      if (!(h > 0 && h <= 200)) continue
      out.push({ date: p[0], health: h, cycles: isNaN(c) ? -1 : c })
    }
    root.healthHistory = out
  }

  Component.onCompleted: {
    historyProc.running = true
    refresh()
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Process {
    id: probe
    command: ["sh", "-c",
      "for d in /sys/class/power_supply/*; do " +
      "[ -f \"$d/type\" ] || continue; " +
      "[ \"$(cat \"$d/type\" 2>/dev/null)\" = \"Battery\" ] || continue; " +
      "if [ -f \"$d/present\" ] && [ \"$(cat \"$d/present\" 2>/dev/null)\" = \"0\" ]; then continue; fi; " +
      "echo \"battery=$d\"; " +
      "for k in capacity present status cycle_count energy_now energy_full energy_full_design charge_now charge_full charge_full_design voltage_now charge_control_end_threshold; do " +
      "[ -f \"$d/$k\" ] && echo \"$k=$(cat \"$d/$k\" 2>/dev/null)\"; done; " +
      "echo end; done | head -c 16384"]
    stdout: StdioCollector {
      onStreamFinished: root.parseProbe(text.slice(0, 16384))
    }
  }

  Process {
    id: appendProc
    onExited: function(code, status) { historyProc.running = true }
  }

  Process {
    id: historyProc
    command: ["sh", "-c", "{ [ -f \"$1\" ] && [ ! -L \"$1\" ] && tail -n 400 \"$1\" || true; } | head -c 32768", "sh", root.healthLog]
    stdout: StdioCollector {
      onStreamFinished: root.parseHistory(text)
    }
  }

  Process {
    id: applyProc
    property int pct: 100
    onExited: function(code, status) {
      console.log("applyProc exited with code:", code, "status:", status)
      root.applying = false
      root.justApplied = true
      root.refresh()
      if (code === 0) {
        Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "low",
          "Power Manager", applyProc.pct === 100
            ? "Charge limit removed — stock behavior restored"
            : "Charge limit set to " + applyProc.pct + "%"])
      } else if (code !== 126) {
        Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "critical",
          "Power Manager", "Could not set the charge limit (exit " + code + ")"])
      }
    }
  }
}
