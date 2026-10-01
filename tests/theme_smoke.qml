import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: test
  property var panel: null
  property var card: null
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
    function moduleWidgets(name) { return [test.panel] }
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
    panel = component.createObject(test, {bar: fakeBar, manageIpc: false})
    if (!panel) throw new Error(component.errorString())
  }
  Timer {
    interval: 1000
    running: true
    onTriggered: {
      if (!test.panel || test.panel.config.enabled !== false) throw new Error("Fixture was not loaded")
      Style.cornerRadius = 0
      test.panel.openedFromMenu = true
      test.panel.open()
      for (var i = 0; i < test.panel.data.length; i++) {
        var object = test.panel.data[i]
        if ("visible" in object && "screen" in object && !("anchorItem" in object))
          test.card = object.contentItem.children[1]
      }
      if (!test.card) throw new Error("Standalone card was not created")
      renderCheck.start()
    }
  }
  function checkControls(item) {
    var count = 0
    var name = item.toString()
    if (/CustomButton|ProfileButton|CustomNumberField|CustomDropdown/.test(name) && "radius" in item) {
      if (item.radius !== 0) throw new Error("Control ignores square theme: " + name)
      count++
    }
    if (item.children) {
      for (var i = 0; i < item.children.length; i++) count += checkControls(item.children[i])
    }
    return count
  }
  Timer {
    id: renderCheck
    interval: 400
    onTriggered: {
      var count = test.checkControls(test.card)
      if (test.card.radius !== 0 || count < 3) throw new Error("Square-theme controls were not verified: " + count)
      console.log("Verified square-theme controls:", count)
      if (!Quickshell.env("POWER_MANAGER_SCREENSHOT")) {
        test.panel.close()
        console.log("POWER_MANAGER_QML_SMOKE_PASS")
        Qt.quit()
        return
      }
      test.card.grabToImage(function(result) {
        if (!result.saveToFile(Quickshell.env("POWER_MANAGER_SCREENSHOT"))) throw new Error("Screenshot failed")
        test.panel.close()
        console.log("POWER_MANAGER_QML_SMOKE_PASS")
        Qt.quit()
      })
    }
  }
}
