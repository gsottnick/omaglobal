import QtQuick
import qs.Commons

QtObject {
  id: bar

  property string position: "top"
  property int barSize: Style.bar.sizeHorizontal
  property bool vertical: false
  property color foreground: Color.foreground
  property color background: Color.background
  property color barForeground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool foregroundAnimationEnabled: false
  property var activePopout: null
  property var writes: []
  property QtObject shell: QtObject {
    function updateEntryInline(moduleName, entry) {
      bar.writes = bar.writes.concat([entry])
      return true
    }
  }

  function requestPopout(key) { activePopout = key }
  function releasePopout(key) { if (activePopout === key) activePopout = null }
  function targetBelongsToWindow(target, window) { return true }
  function switchPanelFrom(panel, direction) { return false }
  function showTooltip(owner, text) {}
  function hideTooltip(owner) {}
  function moduleWidgets(moduleName) { return [] }
}
