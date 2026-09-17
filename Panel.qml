import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model
import QtQuick.Controls as QQC2

Panel {
  id: root
  signal refreshUi()
  implicitWidth: barBtn.implicitWidth
  implicitHeight: barBtn.implicitHeight
  moduleName: "onlyvishesh.power-manager"
  ipcTarget: "onlyvishesh.power-manager"
  manageIpc: true

  property bool openedFromMenu: false
  property string currentTab: "overview"
  readonly property color themeAccent: typeof Color.accent !== "undefined" ? Color.accent : "#00e699"

  // ── Live system state ──
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  property int currentBrightness: 50
  property var diagnosticsData: ({})
  
  property int pendingLimit: 100
  BatteryTracker {
    id: tracker
    onLimitChanged: root.pendingLimit = limit
    onLimitSyncRequired: function(l) { root.pendingLimit = l }
  }

  // ── Config state ──
  property var config: Model.defaultConfig()
  property var editConfig: Model.defaultConfig()
  property bool configDirty: JSON.stringify(config) !== JSON.stringify(editConfig) || (tracker.supported && root.pendingLimit !== tracker.limit)

  // ── UPower convenience ──
  readonly property var upowerStates: ({ Charging: 1, Discharging: 2, FullyCharged: 4, PendingCharge: 3 })
  readonly property bool discharging: {
    var d = UPower.displayDevice
    return !!(d && d.isPresent && UPower.onBattery)
  }
  readonly property real batteryFrac: Model.batteryFraction(UPower.displayDevice)
  readonly property bool fullyCharged: {
    var d = UPower.displayDevice
    return d && d.isPresent && d.state === 4 && !Model.chargeThresholdActive(d, discharging, upowerStates)
  }
  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !fullyCharged
  }
  readonly property var chargingPhrases: [
    "Hoarding electrons",
    "Sucking watts",
    "Drinking juice",
    "Stockpiling volts",
    "Gulping amps",
    "Inhaling power",
    "Consuming energy"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  
  property int phraseIndex: 0
  
  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    onTriggered: root.phraseIndex++
  }

  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return "Charging"
  }
  readonly property color batteryFillColor: root.bar ? root.bar.foreground : Color.foreground

  // ── Config helpers ──
  function getVal(key, def) {
    if (!editConfig) return def
    var parts = key.split('.')
    var obj = editConfig
    for (var i = 0; i < parts.length; i++) {
      if (!obj || obj[parts[i]] === undefined) return def
      obj = obj[parts[i]]
    }
    return obj
  }

  function setVal(key, value) {
    var c = JSON.parse(JSON.stringify(editConfig))
    var parts = key.split('.')
    var obj = c
    for (var i = 0; i < parts.length - 1; i++) {
      if (!obj[parts[i]] || typeof obj[parts[i]] !== 'object') obj[parts[i]] = {}
      obj = obj[parts[i]]
    }
    obj[parts[parts.length - 1]] = value
    editConfig = c
  }

  // ── Profile control ──
  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
  }

  function setSystemProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", discharging ? "battery" : "ac", profile]
    actionProc.running = true
    activeProfile = profile
  }

  // ── Lifecycle ──
  Component.onCompleted: configReadProc.running = true

  onOpenedChanged: {
    if (opened) {
      currentTab = "overview"
      root.editConfig = JSON.parse(JSON.stringify(root.config))
      refresh()
      refreshTimer.restart()
    } else {
      refreshTimer.stop()
    }
  }

  function refresh() {
    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
    if (!brightnessReadProc.running) brightnessReadProc.running = true
  }

  // ── Native Idle Suspend ──
  readonly property string currentStateKey: root.discharging ? (root.batteryFrac <= (root.getVal("batteryThreshold", 30)/100.0) ? "batteryLow" : "batteryHigh") : "ac"
  readonly property int idleSleepMins: root.getVal("idle." + currentStateKey + ".sleepAfterMinutes", 0)
  readonly property string idleAction: root.getVal("idle." + currentStateKey + ".afterSleep", "ignore")

  property bool wasIdle: false
  property int idleCountdown: 0
  Process {
    id: idleStatusProc
    command: ["sh", "-c", "WAYLAND_DISPLAY= echo \"$(qs ipc --any-display -p /usr/share/omarchy/shell call idle status 2>/dev/null)\" \"|||\" \"$(qs ipc --any-display -p /usr/share/omarchy/shell call lock status 2>/dev/null)\""]
    stdout: SplitParser {
      onRead: function(line) {
        var res = String(line).trim()
        if (res !== "" && res.indexOf("|||") !== -1) {
          try {
            var parts = res.split("|||")
            var idleSt = JSON.parse(parts[0].trim())
            var lockSt = JSON.parse(parts[1].trim())
            
            var isSleepable = (idleSt.inIdleCycle === true || lockSt.locked === true);
            var isTyping = (lockSt.locked === true && (lockSt.authenticating || lockSt.unlocking || lockSt.previewTyped > 0));
            
            if (isSleepable) {
              if (!root.wasIdle) {
                root.wasIdle = true
                var elapsed = 0;
                if (lockSt.locked) elapsed = idleSt.lock;
                else if (idleSt.inIdleCycle) elapsed = idleSt.screensaver;
                
                root.idleCountdown = (root.idleSleepMins * 60) - elapsed;
                
                // CRITICAL: If they set sleep to 1 min (60s) and elapsed is 60s, it would be 0.
                // Always ensure at least 60 seconds of countdown upon waking up so it doesn't loop.
                if (root.idleCountdown < 60) root.idleCountdown = 60;
                
                console.log("IDLE: System is sleepable. Starting countdown:", root.idleCountdown)
              } else {
                if (isTyping) {
                  root.idleCountdown = 60; // pause and give 60s to type password
                } else {
                  root.idleCountdown -= 5;
                }
                
                if (root.idleCountdown <= 0) {
                  console.log("IDLE: SLEEPING NOW!")
                  var cmd = ""
                  if (root.idleAction === "suspend") cmd = "systemctl suspend"
                  else if (root.idleAction === "hibernate") cmd = "systemctl hibernate"
                  else if (root.idleAction === "suspend-then-hibernate") cmd = "systemctl suspend-then-hibernate"
                  else if (root.idleAction === "hybrid-sleep") cmd = "systemctl hybrid-sleep"
                  else if (root.idleAction === "poweroff") cmd = "systemctl poweroff"
                  if (cmd !== "") {
                    console.log("IDLE EXECUTING:", cmd)
                    idleActionProc.command = ["bash", "-c", cmd]
                    idleActionProc.running = true
                  }
                  
                  // Reset properly so it evaluates their custom timeout dynamically next time!
                  root.wasIdle = false
                }
              }
            } else {
              if (root.wasIdle) console.log("IDLE: Canceled by user activity")
              root.wasIdle = false
            }
          } catch(e) {}
        }
      }
    }
  }

  Timer {
    id: pluginIdleTimer
    running: !!root.bar && root.getVal("enabled", true) && root.idleSleepMins > 0 && root.idleAction !== "ignore"
    repeat: true
    interval: 5000
    onTriggered: { console.log("IDLE DEBUG - State:", root.currentStateKey, "Mins:", root.idleSleepMins, "Countdown:", root.idleCountdown); idleStatusProc.running = true }
  }

  Process { id: idleActionProc }

  // ── IPC handlers ──
  IpcHandler {
    target: "power-manager"
    function open() { root.openedFromMenu = true; root.open() }
    function toggle() { root.openedFromMenu = true; root.toggle() }
  }

  // ── Processes ──
  Process {
    id: configReadProc
    command: ["bash", "-c", "cat $HOME/.config/onlyvishesh.power-manager.json 2>/dev/null || echo '{}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          var merged = Model.mergeWithDefaults(parsed)
          root.config = merged
          root.editConfig = JSON.parse(JSON.stringify(merged))
        } catch(e) {}
      }
    }
  }

  property string pendingWrite: ""
  Process {
    id: configWriteProc
    command: ["sh", "-c", "echo \"$1\" | base64 -d > \"$HOME/.config/onlyvishesh.power-manager.json\"", "sh", root.pendingWrite]
    onExited: {
      root.config = JSON.parse(JSON.stringify(root.editConfig))
      applyProc.running = true
    }
  }

  Process {
    id: applyProc
    command: ["pkexec", "/usr/local/libexec/omarchy-power-manager/power-manager-apply"]
    onExited: function(code, status) {
      diagnosticsProc.running = true
      profilesProc.running = true
      if (code === 0 && tracker.supported && root.pendingLimit !== tracker.limit) {
        tracker.setLimit(root.pendingLimit)
      }
    }
  }

  Process {
    id: actionProc
    onExited: { if (!profilesProc.running) profilesProc.running = true }
  }

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) root.batteryInfo = next
      }
    }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) root.systemInfo = next
      }
    }
  }

  Process {
    id: brightnessReadProc
    command: ["omarchy-brightness-display", "--no-osd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var val = parseInt(String(text).trim())
        if (!isNaN(val) && val >= 1 && val <= 100) root.currentBrightness = val
      }
    }
  }

  Process {
    id: brightnessSetProc
    onExited: { if (!brightnessReadProc.running) brightnessReadProc.running = true }
  }

  Process {
    id: diagnosticsProc
    command: ["bash", "-c", "\"$HOME/.config/omarchy/plugins/onlyvishesh.power-manager/scripts/power-manager-diagnostics\" --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (parsed && typeof parsed === 'object') root.diagnosticsData = parsed
        } catch(e) {}
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: 3000
    repeat: true
    running: false
    onTriggered: root.refresh()
  }

  property var actionOptions: ["ignore", "suspend", "hybrid-sleep", "hibernate", "suspend-then-hibernate", "poweroff"]
  property var profileOptions: ["power-saver", "balanced", "performance"]
  property var tabOptions: [
    { value: "overview", label: "Overview", icon: "󰂄" },
    { value: "profiles", label: "Profiles", icon: "󰓅" },
    { value: "advanced", label: "Advanced", icon: "󰒓" },
    { value: "diagnostics", label: "Diag.", icon: "󰋽" }
  ]

  // ── Bar button ──
  WidgetButton {
    id: barBtn
    anchors.fill: parent
    bar: root.bar
    fontSize: Style.bar.iconFont
    horizontalMargin: (root.config && root.config.appearance && root.config.appearance.showPercentage !== false) ? 6.0 : 8.5
    text: ((root.config && root.config.appearance && root.config.appearance.showPercentage !== false && UPower.displayDevice.percentage * 100 > 0) ? Math.round(UPower.displayDevice.percentage * 100) + "% " : "") + (Model.batteryIcon(UPower.displayDevice, UPower.onBattery, root.upowerStates) || "󰂄")
    onPressed: function(btn) { root.openedFromMenu = false; root.toggle() }
  }

  // ── Shared UI content ──
  Component {
    id: panelContent
    Column {
      id: contentCol
      width: parent.width
      spacing: Style.space(12)

      // Tab bar
      Rectangle {
        width: parent.width
        height: Style.space(40)
        color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.04)
        radius: Style.space(10)
        border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.05)
        
        Row {
          anchors.fill: parent
          anchors.margins: Style.space(4)
          spacing: Style.space(4)
          
          Repeater {
            model: root.tabOptions
            delegate: MouseArea {
              width: (parent.width - parent.spacing * (root.tabOptions.length - 1)) / root.tabOptions.length
              height: parent.height
              hoverEnabled: true
              onClicked: {
                root.editConfig = JSON.parse(JSON.stringify(root.config));
                root.refreshUi();
                root.currentTab = modelData.value;
              }
              Rectangle {
                anchors.fill: parent
                radius: Style.space(7)
                color: root.currentTab === modelData.value 
                  ? Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1) 
                  : (parent.containsMouse ? Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.05) : "transparent")
                border.color: root.currentTab === modelData.value 
                  ? Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1) 
                  : "transparent"
              }
              Row {
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  text: modelData.icon
                  color: root.currentTab === modelData.value ? root.themeAccent : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.6)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: modelData.label
                  color: root.currentTab === modelData.value ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.6)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.weight: root.currentTab === modelData.value ? Font.Bold : Font.Medium
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }
        }
      }

      // ═══════════ OVERVIEW TAB ═══════════
      Loader {
        width: parent.width
        active: root.currentTab === "overview"
        visible: active
        sourceComponent: Column {
          spacing: Style.space(14)

        // Battery Header
        Row {
          width: parent.width
          spacing: Style.space(14)
          
          Rectangle {
            width: Style.space(44)
            height: Style.space(44)
            radius: Style.space(10)
            color: Qt.rgba(root.themeAccent.r, root.themeAccent.g, root.themeAccent.b, 0.12)
            border.color: Qt.rgba(root.themeAccent.r, root.themeAccent.g, root.themeAccent.b, 0.25)
            
            Text {
              anchors.centerIn: parent
              text: Model.batteryIcon(UPower.displayDevice, UPower.onBattery, root.upowerStates) || "󰂄"
              color: root.themeAccent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
            }
          }
          
          Column {
            width: parent.width - Style.space(148)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "Battery"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: root.heroStatusText.toUpperCase()
              color: root.themeAccent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall - 2
              font.bold: true
              font.letterSpacing: 1.5
            }
          }
          
          Rectangle {
            width: Style.space(64)
            height: Style.space(28)
            radius: Style.space(8)
            color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.08)
            border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1)
            anchors.verticalCenter: parent.verticalCenter
            
            Text {
              anchors.centerIn: parent
              text: root.batteryInfo.percentage || (Math.round(root.batteryFrac * 100) + "%")
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
        }

        // Battery bar (Progress)
        Item {
          width: parent.width
          implicitHeight: Style.space(10)
          Rectangle {
            id: batTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.12)
            border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.04)
          }
          Rectangle {
            anchors.left: batTrack.left
            anchors.verticalCenter: batTrack.verticalCenter
            height: batTrack.height
            radius: batTrack.radius
            color: root.themeAccent
            width: Math.max(batTrack.height, batTrack.width * root.batteryFrac)
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            SequentialAnimation on opacity {
              running: root.charging && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // Metrics Grid
        Rectangle {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          height: metricsGrid.implicitHeight + Style.space(28)
          radius: Style.space(12)
          color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.03)
          border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.05)
          
          Grid {
            id: metricsGrid
            anchors.centerIn: parent
            width: parent.width - Style.space(36)
            columns: 2
            rowSpacing: Style.space(12)
            columnSpacing: Style.space(24)
            
            InfoPair { width: (parent.width - parent.columnSpacing) / 2; label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { width: (parent.width - parent.columnSpacing) / 2; label: root.discharging ? "Time left" : (root.fullyCharged ? "Status" : "Time to full"); value: root.fullyCharged ? "Full" : (root.batteryInfo.time || "—") }
            InfoPair { width: (parent.width - parent.columnSpacing) / 2; label: root.discharging ? "Discharging" : "Charging"; value: root.fullyCharged ? "—" : (root.batteryInfo.rate || "") }
            InfoPair { width: (parent.width - parent.columnSpacing) / 2; label: "Charge cycles"; value: tracker.cycleCount > 0 ? tracker.cycleCount : (tracker.cycleCount === 0 ? "0*" : "—") }
            InfoPair { width: (parent.width - parent.columnSpacing) / 2; label: "Battery Health"; value: tracker.healthPct > 0 ? tracker.healthPct.toFixed(0) + "%" : "—" }
            Item {
              width: (parent.width - parent.columnSpacing) / 2
              height: Style.space(24)
              visible: tracker.cycleCount !== 0
            }
            Text {
              width: (parent.width - parent.columnSpacing) / 2
              height: Style.space(24)
              text: "*Not tracked by hardware"
              visible: tracker.cycleCount === 0
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.4
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              verticalAlignment: Text.AlignVCenter
            }
          }
        }
        
        // History Chart
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: true

          PanelSectionHeader {
            text: "BATTERY HEALTH HISTORY"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Canvas {
            width: parent.width
            height: Style.space(56)
            visible: tracker.healthHistory.length >= 2
            property var pts: tracker.healthHistory
            property color lineColor: root.themeAccent
            onPtsChanged: requestPaint()
            onLineColorChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var h = pts
              if (h.length < 2) return
              var lo = h[0].health, hi = h[0].health
              for (var j = 1; j < h.length; j++) {
                if (h[j].health < lo) lo = h[j].health
                if (h[j].health > hi) hi = h[j].health
              }
              lo -= 0.5; hi += 0.5
              var t0 = Date.parse(h[0].date)
              var t1 = Date.parse(h[h.length - 1].date)
              var dt = Math.max(1, t1 - t0)
              ctx.strokeStyle = String(lineColor)
              ctx.lineWidth = 2
              ctx.lineJoin = "round"
              ctx.beginPath()
              for (var k = 0; k < h.length; k++) {
                var x = (Date.parse(h[k].date) - t0) / dt * (width - 4) + 2
                var y = height - 3 - (h[k].health - lo) / (hi - lo) * (height - 6)
                if (k === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
              }
              ctx.stroke()
            }
          }
          
          Text {
            width: parent.width
            visible: tracker.healthHistory.length < 2
            text: tracker.healthHistory.length === 1 ? "History log started today. It will take a few days of usage to build a trend." : "Waiting for first health log..."
            color: root.bar ? root.bar.foreground : Color.foreground
            opacity: 0.6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
          
          Text {
            width: parent.width
            text: {
              if (tracker.healthHistory.length < 2) return ""
              var h = tracker.healthHistory
              var a = h[0], b = h[h.length - 1]
              var dh = b.health - a.health
              var span = Math.round((Date.parse(b.date) - Date.parse(a.date)) / 86400000)
              var s = (dh >= 0 ? "+" : "") + dh.toFixed(1) + "% health over " + span + " day" + (span === 1 ? "" : "s")
              if (a.cycles >= 0 && b.cycles >= a.cycles) s += " · +" + (b.cycles - a.cycles) + " cycles"
              return s
            }
            color: root.bar ? root.bar.foreground : Color.foreground
            opacity: 0.6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }
        
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            text: "Show battery percentage in panel"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - batPctToggle.width - parent.spacing
          }
          CustomToggle {
            id: batPctToggle
            anchors.verticalCenter: parent.verticalCenter
            checked: root.config.appearance && root.config.appearance.showPercentage !== false
            onToggled: {
              root.editConfig = JSON.parse(JSON.stringify(root.config));
              if (!root.editConfig.appearance) root.editConfig.appearance = {};
              root.editConfig.appearance.showPercentage = !checked;
              root.config = JSON.parse(JSON.stringify(root.editConfig));
              root.pendingWrite = Qt.btoa(JSON.stringify(root.editConfig, null, 2));
              configWriteProc.running = true;
            }
          }
        }
        


        // Brightness
        Column {
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader {
            text: "BRIGHTNESS"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              text: "󰃠"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }
            CustomSlider {
              id: brightnessSlider
              width: parent.width - Style.space(80)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 1
              maximum: 100
              value: root.currentBrightness
              onMoved: function(val) {
                var pct = Math.round(val)
                brightnessSetProc.command = ["omarchy-brightness-display", "--no-osd", pct + "%"]
                brightnessSetProc.running = true
              }
              onReleased: function(val) {
                brightnessReadProc.running = true
              }
            }
            Text {
              text: root.currentBrightness + "%"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(36)
            }
          }
        }
        


        // Profile picker
        Column {
          width: parent.width
          spacing: Style.space(10)
          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length : 0
            Repeater {
              model: root.profiles
              CustomProfileButton {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: Model.profileIcon(String(modelData))
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                active: root.activeProfile === modelData
                onClicked: { root.setSystemProfile(modelData) }
              }
            }
          }
        }
      }

      }

      // ═══════════ PROFILES TAB ═══════════
      Loader {
        width: parent.width
        active: root.currentTab === "profiles"
        visible: active
        sourceComponent: Column {
          spacing: Style.space(14)

        PanelSectionHeader {
          text: "ACTIVE PROFILE"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        Row {
          id: profileRow2
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: root.profiles.length > 0
            ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length : 0
          Repeater {
            model: root.profiles
            CustomProfileButton {
              required property var modelData
              required property int index
              width: profileRow2.cellWidth
              iconText: Model.profileIcon(String(modelData))
              text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
              active: root.activeProfile === modelData
              onClicked: { root.setSystemProfile(modelData) }
            }
          }
        }
        


        PanelSectionHeader {
          text: "AUTOMATIC PROFILE RULES"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        SettingRow { label: "When on AC power"; widgetType: "dropdown"; options: root.profileOptions; configKey: "profiles.ac" }
        SettingRow { label: "Battery High"; widgetType: "dropdown"; options: root.profileOptions; configKey: "profiles.batteryHigh" }
        SettingRow { label: "Battery Low"; widgetType: "dropdown"; options: root.profileOptions; configKey: "profiles.batteryLow" }
        SettingRow { label: "Low battery threshold (%)"; widgetType: "number"; configKey: "batteryThreshold" }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        PanelSectionHeader {
          text: "AUTOMATIC BRIGHTNESS"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        SettingRow { label: "Auto-adjust brightness"; widgetType: "toggle"; configKey: "brightness.auto" }
        SettingRow { label: "AC power (% or 0 for skip)"; widgetType: "number"; configKey: "brightness.ac" }
        SettingRow { label: "Battery High (% or 0 for skip)"; widgetType: "number"; configKey: "brightness.batteryHigh" }
        SettingRow { label: "Battery Low (% or 0 for skip)"; widgetType: "number"; configKey: "brightness.batteryLow" }

        CustomButton {
          width: parent.width
          text: "Apply Rules"
          active: root.configDirty
          onClicked: { root.forceActiveFocus(); root.pendingWrite = Qt.btoa(JSON.stringify(root.editConfig, null, 2)); configWriteProc.running = true }
        }
      }

      }

      // ═══════════ ADVANCED TAB ═══════════
      Loader {
        width: parent.width
        active: root.currentTab === "advanced"
        visible: active
        sourceComponent: Column {
          spacing: Style.space(12)

        SettingRow { label: "Enable automatic management"; widgetType: "toggle"; configKey: "enabled" }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground; visible: tracker.supported }

        // Battery Protection
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: tracker.supported

          PanelSectionHeader {
            text: "BATTERY PROTECTION"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Prevent battery degradation"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width * 0.6
              wrapMode: Text.Wrap
            }
            Item {
              width: parent.width * 0.4 - parent.spacing
              height: Style.space(28)
              anchors.verticalCenter: parent.verticalCenter
              CustomToggle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.pendingLimit < 100
                onToggled: { root.pendingLimit = checked ? 100 : 80 }
              }
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.pendingLimit < 100
            Text {
              text: "Charge cut-off (%)"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width * 0.6
              wrapMode: Text.Wrap
            }
            Item {
              width: parent.width * 0.4 - parent.spacing
              height: Style.space(28)
              anchors.verticalCenter: parent.verticalCenter
              CustomNumberField {
                width: parent.width
                anchors.verticalCenter: parent.verticalCenter
                value: root.pendingLimit
                onModified: function(val) {
                  if (val >= 50 && val <= 100) {
                    root.pendingLimit = val
                  }
                }
                onAccepted: {
                  if (root.configDirty) {
                    root.forceActiveFocus();
                    root.pendingWrite = Qt.btoa(JSON.stringify(root.editConfig, null, 2));
                    configWriteProc.running = true;
                  }
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        // Idle AC
        PanelSectionHeader {
          text: "SLEEP AFTER INACTIVITY (AC)"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        SettingRow { label: "Minutes before sleep"; widgetType: "number"; configKey: "idle.ac.sleepAfterMinutes" }
        SettingRow { label: "Action on idle"; widgetType: "dropdown"; options: root.actionOptions; configKey: "idle.ac.afterSleep" }
        SettingRow { label: "Hibernate after (min)"; widgetType: "number"; configKey: "idle.ac.hibernateAfterMinutes" }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        // Idle Battery High
        PanelSectionHeader {
          text: "SLEEP AFTER INACTIVITY (BATTERY HIGH)"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        SettingRow { label: "Minutes before sleep"; widgetType: "number"; configKey: "idle.batteryHigh.sleepAfterMinutes" }
        SettingRow { label: "Action on idle"; widgetType: "dropdown"; options: root.actionOptions; configKey: "idle.batteryHigh.afterSleep" }
        SettingRow { label: "Hibernate after (min)"; widgetType: "number"; configKey: "idle.batteryHigh.hibernateAfterMinutes" }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        // Idle Battery Low
        PanelSectionHeader {
          text: "SLEEP AFTER INACTIVITY (BATTERY LOW)"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        SettingRow { label: "Minutes before sleep"; widgetType: "number"; configKey: "idle.batteryLow.sleepAfterMinutes" }
        SettingRow { label: "Action on idle"; widgetType: "dropdown"; options: root.actionOptions; configKey: "idle.batteryLow.afterSleep" }
        SettingRow { label: "Hibernate after (min)"; widgetType: "number"; configKey: "idle.batteryLow.hibernateAfterMinutes" }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        // Lid
        PanelSectionHeader {
          text: "WHEN LAPTOP LID CLOSES"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        SettingRow { label: "Ignore lid close"; widgetType: "toggle"; configKey: "lid.ignoreLidClose" }
        SettingRow { label: "On AC power"; widgetType: "dropdown"; options: root.actionOptions; configKey: "lid.ac.action" }
        SettingRow { label: "Battery High"; widgetType: "dropdown"; options: root.actionOptions; configKey: "lid.batteryHigh.action" }
        SettingRow { label: "Battery Low"; widgetType: "dropdown"; options: root.actionOptions; configKey: "lid.batteryLow.action" }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        CustomButton {
          width: parent.width
          text: "Apply All Settings"
          active: root.configDirty
          onClicked: {
            root.forceActiveFocus();
            root.pendingWrite = Qt.btoa(JSON.stringify(root.editConfig, null, 2));
            configWriteProc.running = true;
          }
        }
      }

      }

      // ═══════════ DIAGNOSTICS TAB ═══════════
      Loader {
        width: parent.width
        active: root.currentTab === "diagnostics"
        visible: active
        sourceComponent: Column {
          spacing: Style.space(12)

        Component.onCompleted: if (root.currentTab === "diagnostics") diagnosticsProc.running = true
        Connections {
          target: root
          function onCurrentTabChanged() { if (root.currentTab === "diagnostics") diagnosticsProc.running = true }
        }

        PanelSectionHeader {
          text: "HIBERNATION READINESS"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Text {
          text: Model.hibernationReady(root.diagnosticsData) ? "✓ READY" : "✗ NOT READY"
          color: Model.hibernationReady(root.diagnosticsData)
            ? (root.bar ? root.bar.foreground : Color.foreground)
            : "#e06c75"
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        // Individual checks
        DiagRow {
          ok: !!(root.diagnosticsData.swap && root.diagnosticsData.swap.adequate_for_hibernate)
          label: "Swap"
          detail: (root.diagnosticsData.swap && root.diagnosticsData.swap.adequate_for_hibernate) ? "Adequate for hibernation" : "Not sufficient"
        }
        DiagRow {
          ok: !!root.diagnosticsData.hibernate_available
          label: "Hibernate service"
          detail: root.diagnosticsData.hibernate_available ? "Available" : "Not available"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.resume && root.diagnosticsData.resume.kernel_cmdline_has_resume)
          label: "Resume parameters"
          detail: (root.diagnosticsData.resume && root.diagnosticsData.resume.kernel_cmdline_has_resume) ? "Configured" : "Missing in kernel cmdline"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.initramfs && root.diagnosticsData.initramfs.resume_hook_present)
          label: "Initramfs resume hook"
          detail: (root.diagnosticsData.initramfs && root.diagnosticsData.initramfs.resume_hook_present) ? "Present" : "Missing"
        }
        DiagRow {
          ok: !!(root.diagnosticsData.initramfs && root.diagnosticsData.initramfs.hook_order_correct)
          label: "Hook order"
          detail: (root.diagnosticsData.initramfs && root.diagnosticsData.initramfs.hook_order_correct) ? "Correct" : "Incorrect"
        }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        PanelSectionHeader {
          text: "SLEEP STATES"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        DiagRow { ok: !!(root.diagnosticsData.sleep_states && root.diagnosticsData.sleep_states.freeze); label: "Freeze (S0)"; detail: "Idle standby" }
        DiagRow { ok: !!(root.diagnosticsData.sleep_states && root.diagnosticsData.sleep_states.mem); label: "Suspend (S3)"; detail: "RAM powered" }
        DiagRow { ok: !!(root.diagnosticsData.sleep_states && root.diagnosticsData.sleep_states.disk); label: "Hibernate (S4)"; detail: "Written to disk" }
        DiagRow { ok: !!root.diagnosticsData.suspend_then_hibernate_available; label: "Suspend-then-hibernate"; detail: "Chained sleep" }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        PanelSectionHeader {
          text: "SYSTEM INFO"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        InfoPair {
          label: "Profile backend"
          value: (root.diagnosticsData.power_profiles && root.diagnosticsData.power_profiles.backend) || "unknown"
        }
        InfoPair {
          label: "Active profile"
          value: (root.diagnosticsData.power_profiles && root.diagnosticsData.power_profiles.active) || "unknown"
        }
        InfoPair {
          label: "Logind lid switch"
          value: (root.diagnosticsData.logind && root.diagnosticsData.logind.handle_lid_switch) || "—"
        }
        InfoPair {
          label: "Logind lid (AC)"
          value: (root.diagnosticsData.logind && root.diagnosticsData.logind.handle_lid_switch_external_power) || "—"
        }
        
        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }
        
        CustomButton {
          width: parent.width
          text: "Reset All Settings to Defaults"
          active: true
          onClicked: {
            root.forceActiveFocus();
            root.editConfig = JSON.parse(JSON.stringify(Model.defaultConfig()));
            root.refreshUi();
            root.pendingWrite = Qt.btoa(JSON.stringify(root.editConfig, null, 2));
            configWriteProc.running = true;
          }
        }
      }

      Item { width: 1; height: Style.space(4) }
    }
  }

      }

  // ── Reusable components ──
  component InfoPair: Row {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    Text {
      text: parent.label
      color: root.bar ? root.bar.foreground : Color.foreground
      opacity: 0.6
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      width: parent.width * 0.45
    }
    Text {
      text: parent.value
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      width: parent.width * 0.55 - parent.spacing
      wrapMode: Text.Wrap
      horizontalAlignment: Text.AlignRight
    }
  }

  component DiagRow: Row {
    property bool ok: false
    property string label: ""
    property string detail: ""
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    Text {
      text: parent.ok ? "✓" : "✗"
      color: parent.ok ? "#98c379" : "#e06c75"
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      width: Style.space(16)
    }
    Column {
      width: parent.width - Style.space(24)
      Text {
        text: parent.parent.label
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        width: parent.width
      }
      Text {
        text: parent.parent.detail
        color: root.bar ? root.bar.foreground : Color.foreground
        opacity: 0.6
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        width: parent.width
      }
    }
  }

  component SettingRow: Row {
    property string label: ""
    property string widgetType: "dropdown"
    property var options: []
    property string configKey: ""
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    Text {
      text: parent.label
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * 0.6
      wrapMode: Text.Wrap
    }
    Loader {
      width: parent.width * 0.4 - parent.spacing
      anchors.verticalCenter: parent.verticalCenter
      sourceComponent: {
        if (parent.widgetType === "toggle") return toggleComp
        if (parent.widgetType === "number") return numberComp
        return dropdownComp
      }
      property string _key: parent.configKey
      property var _opts: parent.options
    }
  }

  Component {
    id: toggleComp
    CustomToggle {
      checked: { var _ = root.editConfig; return ! !root.getVal(parent._key, false) }
      onToggled: { root.setVal(parent._key, !checked) }
    }
  }

  Component {
    id: numberComp
    CustomNumberField {
      value: { var _ = root.editConfig; return root.getVal(parent._key, 0) }
      onModified: function(val) { root.setVal(parent._key, val) }
      onAccepted: {
        if (root.configDirty) {
          root.forceActiveFocus();
          root.pendingWrite = Qt.btoa(JSON.stringify(root.editConfig, null, 2));
          configWriteProc.running = true;
        }
      }
    }
  }

  Component {
    id: dropdownComp
    CustomDropdown {
      options: parent._opts || []
      value: { var _ = root.editConfig; return String(root.getVal(parent._key, "")) }
      onChanged: function(val) { root.setVal(parent._key, val) }
    }
  }

  // ── Bar popup mode ──
  KeyboardPanel {
    id: popupPanel
    anchorItem: barBtn
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popupPanel.fittedContentWidth(Style.space(480))
    contentHeight: popupPanel.fittedContentHeight(popupFlick.contentHeight + Style.space(32))

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: popupFlick
        anchors.fill: parent
        anchors.margins: Style.space(16)
        contentHeight: popupLoader.item ? popupLoader.item.implicitHeight : 0
        contentWidth: width
        clip: true

        Loader {
          id: popupLoader
          sourceComponent: panelContent
          width: parent.width
        }
      }
    }
  }

  // ── Standalone app window mode ──
  PanelWindow {
    id: windowPanel
    visible: root.opened && root.openedFromMenu
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-power-manager"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    MouseArea { anchors.fill: parent; onClicked: root.close() }

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(Style.space(480), windowPanel.width - Style.space(32))
      height: Math.min(windowLoader.item ? windowLoader.item.implicitHeight + Style.space(32) : Style.space(400), windowPanel.height - Style.space(64))
      color: Color.popups.background
      radius: Style.cornerRadius
      border.color: Color.popups.border
      border.width: 1

      MouseArea { anchors.fill: parent }

      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        contentHeight: windowLoader.item ? windowLoader.item.implicitHeight : 0
        contentWidth: width
        clip: true

        Loader {
          id: windowLoader
          sourceComponent: panelContent
          width: parent.width
        }
      }
    }
  }

  // ── Custom UI Components ──
  component CustomToggle: Item {
    id: customToggleRoot
    property bool checked: false
    signal toggled()
    
    implicitWidth: Style.space(44)
    implicitHeight: Style.space(24)
    
    Rectangle {
      width: Style.space(44)
      height: Style.space(24)
      radius: height / 2
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      color: customToggleRoot.checked ? root.themeAccent : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.2)
      border.color: customToggleRoot.checked ? Qt.rgba(root.themeAccent.r, root.themeAccent.g, root.themeAccent.b, 0.5) : "transparent"
      
      Rectangle {
        width: Style.space(18)
        height: Style.space(18)
        radius: width / 2
        color: customToggleRoot.checked ? (root.bar ? root.bar.background : Color.background) : (root.bar ? root.bar.foreground : Color.foreground)
        anchors.verticalCenter: parent.verticalCenter
        x: customToggleRoot.checked ? parent.width - width - Style.space(3) : Style.space(3)
        Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
      }
    }
    
    MouseArea {
      anchors.fill: parent
      onClicked: {
        customToggleRoot.toggled()
      }
    }
  }

  component CustomSlider: Item {
    id: sliderRoot
    property int minimum: 0
    property int maximum: 100
    property int value: 50
    signal moved(int val)
    signal released(int val)
    
    height: Style.space(24)
    
    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: Style.space(6)
      radius: height / 2
      color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1)
      
      Rectangle {
        width: Math.max(0, Math.min(parent.width, (sliderRoot.value - sliderRoot.minimum) / (sliderRoot.maximum - sliderRoot.minimum) * parent.width))
        height: parent.height
        radius: parent.radius
        color: root.themeAccent
      }
    }
    
    Rectangle {
      width: Style.space(16)
      height: Style.space(16)
      radius: width / 2
      color: root.themeAccent
      anchors.verticalCenter: parent.verticalCenter
      x: Math.max(0, Math.min(sliderRoot.width - width, (sliderRoot.value - sliderRoot.minimum) / (sliderRoot.maximum - sliderRoot.minimum) * sliderRoot.width - width/2))
    }
    
    MouseArea {
      anchors.fill: parent
      onPressed: function(mouse) {
        var pct = Math.max(0, Math.min(1, mouse.x / width));
        sliderRoot.value = sliderRoot.minimum + pct * (sliderRoot.maximum - sliderRoot.minimum);
        sliderRoot.moved(sliderRoot.value);
      }
      onPositionChanged: function(mouse) {
        if (pressed) {
          var pct = Math.max(0, Math.min(1, mouse.x / width));
          sliderRoot.value = sliderRoot.minimum + pct * (sliderRoot.maximum - sliderRoot.minimum);
          sliderRoot.moved(sliderRoot.value);
        }
      }
      onReleased: function(mouse) {
        sliderRoot.released(sliderRoot.value);
      }
    }
  }

  component CustomProfileButton: Rectangle {
    id: profileBtnRoot
    property string text: ""
    property string iconText: ""
    property bool active: false
    signal clicked()
    
    height: Style.space(36)
    radius: Style.space(8)
    color: active 
      ? Qt.rgba(root.themeAccent.r, root.themeAccent.g, root.themeAccent.b, 0.15)
      : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.05)
    border.color: active ? root.themeAccent : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1)
    
    Row {
      anchors.centerIn: parent
      spacing: Style.space(6)
      Text {
        text: profileBtnRoot.iconText
        color: profileBtnRoot.active ? root.themeAccent : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.7)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: profileBtnRoot.text
        color: profileBtnRoot.active ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.7)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.weight: profileBtnRoot.active ? Font.Bold : Font.Medium
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea {
      anchors.fill: parent
      onClicked: profileBtnRoot.clicked()
    }
  }

  component CustomButton: Rectangle {
    id: btnRoot
    property string text: ""
    property bool active: false
    signal clicked()
    
    height: Style.space(36)
    radius: Style.space(8)
    color: active 
      ? Qt.rgba(root.themeAccent.r, root.themeAccent.g, root.themeAccent.b, 0.15)
      : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.05)
    border.color: active ? root.themeAccent : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1)
    
    Text {
      anchors.centerIn: parent
      text: btnRoot.text
      color: btnRoot.active ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.5)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.weight: btnRoot.active ? Font.Bold : Font.Medium
    }
    
    MouseArea {
      anchors.fill: parent
      onClicked: if (btnRoot.active) btnRoot.clicked()
    }
  }

  component CustomNumberField: Rectangle {
    property int value: 0
    signal modified(int val)
    signal accepted()
    width: parent ? parent.width : Style.space(60)
    height: Style.space(28)
    radius: Style.space(6)
    color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.05)
    border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1)
    
    TextInput {
      anchors.fill: parent
      anchors.margins: Style.space(4)
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      text: parent.value.toString()
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      validator: IntValidator {}
      onEditingFinished: {
        var val = parseInt(text);
        if (!isNaN(val)) parent.modified(val);
      }
      onTextEdited: {
        var val = parseInt(text);
        if (!isNaN(val)) parent.modified(val);
      }
      onAccepted: {
        parent.accepted();
      }
    }
  }

  component CustomDropdown: Item {
    id: dropdownRoot
    property var options: [] 
    property string value: ""
    signal changed(string val)
    
    width: parent ? parent.width : Style.space(120)
    height: Style.space(28)
    
    function getLabel() {
      for (var i = 0; i < options.length; i++) {
        if (options[i].value === value) return options[i].label || options[i].value;
        if (typeof options[i] === "string" && options[i] === value) return options[i];
      }
      return value;
    }
    
    Rectangle {
      id: bgRect
      anchors.fill: parent
      radius: Style.space(6)
      color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.05)
      border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1)
      
      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(12)
        anchors.right: iconArrow.left
        anchors.verticalCenter: parent.verticalCenter
        text: dropdownRoot.getLabel()
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        id: iconArrow
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: menuPopup.opened ? "▲" : "▼"
        color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.5)
        font.pixelSize: Style.font.bodySmall - 4
      }
      MouseArea {
        anchors.fill: parent
        onClicked: {
          if (menuPopup.opened) menuPopup.close();
          else menuPopup.open();
        }
      }
    }
    
    QQC2.Popup {
      id: menuPopup
      // A QQC2.Popup can only draw inside this panel's own window, so a list that
      // runs past the window edge is cut off — which is what the last dropdowns of
      // the Advanced tab hit (e.g. "Battery Low" under "When laptop lid closes").
      // The placement must be computed when the list opens: mapToItem() is not a
      // tracked dependency, so a binding over it goes stale as soon as the panel's
      // scroll position changes. Flip up when there is no room below, clamp to the
      // room that is left, and let the list scroll so every option stays reachable.
      property real roomBelow: naturalHeight
      property real roomAbove: 0
      readonly property real rowHeight: Style.space(28)
      readonly property real listHeight: dropdownRoot.options.length * rowHeight
      readonly property real naturalHeight: listHeight + 2 * padding + 2
      readonly property bool flipUp: naturalHeight > roomBelow && roomAbove > roomBelow

      function updatePlacement() {
        var win = dropdownRoot.Window.window;
        if (!win) {
          roomAbove = 0;
          roomBelow = naturalHeight;
          return;
        }
        roomAbove = dropdownRoot.mapToItem(null, 0, 0).y - Style.space(8);
        roomBelow = win.height - dropdownRoot.mapToItem(null, 0, dropdownRoot.height).y - Style.space(8);
      }

      onOpened: updatePlacement()
      y: flipUp ? -(height + Style.space(4)) : dropdownRoot.height + Style.space(4)
      width: dropdownRoot.width
      height: Math.max(rowHeight, Math.min(naturalHeight, flipUp ? roomAbove : roomBelow))
      padding: Style.space(4)
      background: Rectangle {
        color: Qt.rgba(root.bar ? root.bar.background.r : Color.background.r, root.bar ? root.bar.background.g : Color.background.g, root.bar ? root.bar.background.b : Color.background.b, 1.0)
        border.color: Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.15)
        radius: Style.space(6)
      }
      contentItem: Flickable {
        id: listFlick
        clip: true
        implicitHeight: menuPopup.listHeight
        contentHeight: menuPopup.listHeight
        contentWidth: width
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          width: listFlick.width
          spacing: 0
          Repeater {
            model: dropdownRoot.options
            delegate: Rectangle {
              width: dropdownRoot.width - Style.space(8)
              height: Style.space(28)
              color: mouseArea.containsMouse ? Qt.rgba(root.bar ? root.bar.foreground.r : Color.foreground.r, root.bar ? root.bar.foreground.g : Color.foreground.g, root.bar ? root.bar.foreground.b : Color.foreground.b, 0.1) : "transparent"
              radius: Style.space(4)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                width: parent.width - Style.space(16)
                elide: Text.ElideRight
                text: typeof modelData === "string" ? modelData : (modelData.label || modelData.value)
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                  var val = typeof modelData === "string" ? modelData : modelData.value;
                  dropdownRoot.changed(val);
                  menuPopup.close();
                }
              }
            }
          }
        }
      }
    }
  }
}
