import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: test
  property var first: null
  property var second: null
  property var standalone: null
  QtObject {
    id: fakeBar
    property color foreground: "white"
    property color barForeground: "white"
    property color background: "black"
    property color urgent: "red"
    property bool foregroundAnimationEnabled: false
    property string fontFamily: "sans-serif"
    property string position: "top"
    property bool vertical: false
    property int barSize: 32
    property var activePopout: null
    function moduleWidgets(name) { return [test.first, test.second] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { activePopout = null }
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
  }
  Component.onCompleted: {
    var component = Qt.createComponent(Quickshell.env("POWER_MANAGER_PANEL"))
    if (component.status !== Component.Ready) throw new Error(component.errorString())
    first = component.createObject(test, {bar: fakeBar, manageIpc: false})
    second = component.createObject(test, {bar: fakeBar, manageIpc: false})
    if (!first || !second) throw new Error(component.errorString())
  }
  Timer {
    interval: 1000
    running: true
    onTriggered: {
      if (!test.first || test.first.config.enabled !== false) throw new Error("Fixture was not loaded")
      test.first.openedFromMenu = true
      test.first.open()
      var popup = null
      for (var i = 0; i < test.first.data.length; i++) {
        var object = test.first.data[i]
        if ("anchorItem" in object && "open" in object) popup = object
        if ("visible" in object && "screen" in object && !("anchorItem" in object)) test.standalone = object
      }
      if (!popup || !test.standalone || popup.open || !test.standalone.visible)
        throw new Error("Menu opened a duplicate bar popup")
      renderCheck.start()
    }
  }
  Timer {
    id: renderCheck
    interval: 400
    onTriggered: {
      if (!Quickshell.env("POWER_MANAGER_SCREENSHOT")) {
        test.first.close()
        console.log("POWER_MANAGER_QML_SMOKE_PASS")
        Qt.quit()
        return
      }
      test.standalone.contentItem.children[1].grabToImage(function(result) {
        if (!result.saveToFile(Quickshell.env("POWER_MANAGER_SCREENSHOT"))) throw new Error("Screenshot failed")
        test.first.close()
        console.log("POWER_MANAGER_QML_SMOKE_PASS")
        Qt.quit()
      })
    }
  }
}
