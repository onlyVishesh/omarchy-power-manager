import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model

// Singleton idle -> suspend/hibernate engine for the power-manager plugin.
//
// This used to live inside Panel.qml, a bar-widget instantiated once per
// monitor. On a multi-monitor rig that meant N competing timers all racing
// to call `systemctl suspend`, worked around with a fragile "elect the
// instance bound to Quickshell.screens[0]" guard that silently stopped
// matching on this machine's 4-monitor setup (zero "IDLE DEBUG" lines ever
// fired). Moving it into a "service" kind fixes that at the root: Quickshell
// instantiates services exactly once regardless of monitor count, so no
// election hack is needed at all.
//
// It rides on Omarchy's own first-party idle detection (`omarchy.idle`,
// via Wayland idle-notify) rather than logind's IdleHint/IdleAction, which
// nothing on this system ever feeds -- so it calls `systemctl suspend`
// directly once the configured extra time has elapsed past lock.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/onlyvishesh.power-manager.json"

  property var config: Model.defaultConfig()

  readonly property var upowerStates: ({ Charging: 1, Discharging: 2, FullyCharged: 4, PendingCharge: 3 })
  readonly property bool discharging: {
    var d = UPower.displayDevice
    return !!(d && d.isPresent && UPower.onBattery)
  }
  readonly property real batteryFrac: Model.batteryFraction(UPower.displayDevice)

  function getVal(key, def) {
    if (!root.config) return def
    var parts = key.split('.')
    var obj = root.config
    for (var i = 0; i < parts.length; i++) {
      if (!obj || obj[parts[i]] === undefined) return def
      obj = obj[parts[i]]
    }
    return obj
  }

  readonly property string currentStateKey: root.discharging ? (root.batteryFrac <= (getVal("batteryThreshold", 30) / 100.0) ? "batteryLow" : "batteryHigh") : "ac"
  readonly property int idleSleepMins: getVal("idle." + currentStateKey + ".sleepAfterMinutes", 0)
  readonly property string idleAction: getVal("idle." + currentStateKey + ".afterSleep", "ignore")

  property bool wasIdle: false
  property int idleCountdown: 0

  function logEvent(msg) {
    console.log("power-manager idle: " + msg)
  }

  FileView {
    id: configWatcher
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: reload()
    onFileChanged: reload()
    function reload() {
      try {
        root.config = Model.mergeWithDefaults(JSON.parse(text()))
      } catch (e) {}
    }
  }

  Process {
    id: idleStatusProc
    command: ["sh", "-c", "echo \"$(qs ipc --any-display -p /usr/share/omarchy/shell call idle status 2>/dev/null)\" \"|||\" \"$(qs ipc --any-display -p /usr/share/omarchy/shell call lock status 2>/dev/null)\""]
    stdout: SplitParser {
      onRead: function(line) {
        var res = String(line).trim()
        if (res === "" || res.indexOf("|||") === -1) return
        try {
          var parts = res.split("|||")
          var idleSt = JSON.parse(parts[0].trim())
          var lockSt = JSON.parse(parts[1].trim())

          var isSleepable = (idleSt.inIdleCycle === true || lockSt.locked === true)
          var isTyping = (lockSt.locked === true && (lockSt.authenticating || lockSt.unlocking || lockSt.previewTyped > 0))

          if (isSleepable) {
            if (!root.wasIdle) {
              root.wasIdle = true
              var elapsed = 0
              if (lockSt.locked) elapsed = idleSt.lock
              else if (idleSt.inIdleCycle) elapsed = idleSt.screensaver

              root.idleCountdown = (root.idleSleepMins * 60) - elapsed

              // Always ensure at least 60 seconds of countdown upon waking up
              // so a short configured timeout can't loop immediately.
              if (root.idleCountdown < 60) root.idleCountdown = 60

              root.logEvent("sleepable, starting countdown: " + root.idleCountdown)
            } else {
              if (isTyping) {
                root.idleCountdown = 60 // pause and give 60s to type password
              } else {
                root.idleCountdown -= 5
              }

              if (root.idleCountdown <= 0) {
                var cmd = ""
                if (root.idleAction === "suspend") cmd = "systemctl suspend"
                else if (root.idleAction === "hibernate") cmd = "systemctl hibernate"
                else if (root.idleAction === "suspend-then-hibernate") cmd = "systemctl suspend-then-hibernate"
                else if (root.idleAction === "hybrid-sleep") cmd = "systemctl hybrid-sleep"
                else if (root.idleAction === "poweroff") cmd = "systemctl poweroff"
                if (cmd !== "") {
                  root.logEvent("executing: " + cmd)
                  idleActionProc.command = ["bash", "-c", cmd]
                  idleActionProc.running = true
                }

                // Reset so it re-evaluates the (possibly changed) timeout next time.
                root.wasIdle = false
              }
            }
          } else {
            if (root.wasIdle) root.logEvent("canceled by user activity")
            root.wasIdle = false
          }
        } catch (e) {}
      }
    }
  }

  Process { id: idleActionProc }

  Timer {
    id: pollTimer
    running: root.getVal("enabled", true) && root.idleSleepMins > 0 && root.idleAction !== "ignore"
    repeat: true
    interval: 5000
    onTriggered: idleStatusProc.running = true
  }

  Component.onCompleted: logEvent("service-ready")
}
