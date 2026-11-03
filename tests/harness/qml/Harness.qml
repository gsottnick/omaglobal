import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../../../" as Plugin

QtObject {
  id: harness

  property url pluginUrl
  property var pluginSettings: ({})
  readonly property var plugin: pluginLoader.item
  readonly property var store: Plugin.OmaStore
  property FakeBar fakeBar: FakeBar {}

  function openPanel() { if (plugin) plugin.open() }
  function closePanel() { if (plugin) plugin.close() }

  property var barWindow: PanelWindow {
    id: barWindow
    color: Color.background
    visible: true
    height: Style.bar.sizeHorizontal

    anchors {
      top: true
      left: true
      right: true
    }

    Loader {
      id: pluginLoader
      anchors.verticalCenter: parent.verticalCenter
      Component.onCompleted: setSource(harness.pluginUrl, { bar: harness.fakeBar, settings: harness.pluginSettings })
    }
  }
}
