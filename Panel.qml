// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "."

// Bar button only. dimmed stays on the inner BarIconButton; the Panel root
// is an Item and rejects that property (the harness proves it).
Panel {
  id: root
  moduleName: "io.github.gsottnick.omaglobal"
  ipcTarget: "io.github.gsottnick.omaglobal"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color toneAmber: Qt.hsla(0.11, 0.75, 0.52, 1)
  readonly property color toneGreen: Qt.hsla(0.36, 0.62, 0.42, 1)
  readonly property string phase: OmaStore.phase
  readonly property string iconRole: {
    if (OmaStore.phase === "connected")
      return "green"
    if (OmaStore.phase === "auth" || OmaStore.phase === "connecting")
      return "amber"
    if (OmaStore.phase === "failed")
      return "urgent"
    return "dim"
  }
  readonly property color iconColor: {
    if (iconRole === "green")
      return toneGreen
    if (iconRole === "amber")
      return toneAmber
    if (iconRole === "urgent")
      return Color.urgent
    return barForeground
  }
  readonly property bool iconDimmed: OmaStore.phase === "off"
  readonly property bool setupVisible: !OmaStore.socketUp
  readonly property string setupCommand: OmaStore.setupCommand
  readonly property bool socketUp: OmaStore.socketUp
  readonly property bool autoConnect: OmaStore.autoConnect
  readonly property bool notifyConnect: OmaStore.notifyConnect
  readonly property bool notifyDrop: OmaStore.notifyDrop
  readonly property bool showIpInBar: OmaStore.showIpInBar
  readonly property bool showUsername: OmaStore.showUsername
  readonly property bool autoTried: OmaStore.autoTried
  readonly property int notifyConnectCount: OmaStore.notifyConnectCount
  readonly property int notifyDisconnectCount: OmaStore.notifyDisconnectCount
  readonly property int notifyDropCount: OmaStore.notifyDropCount
  readonly property string vpnIp: OmaStore.ip
  readonly property string vpnGateway: OmaStore.gateway
  readonly property string vpnExpires: OmaStore.expires
  readonly property string activeProfile: OmaStore.activeProfile
  property bool pulseOn: true

  function requestDisconnect() { OmaStore.disconnect() }
  function chooseProfile(name) { OmaStore.chooseProfile(name) }

  function onOff(value, fallback) {
    if (value === true || value === "On" || value === "on")
      return true
    if (value === false || value === "Off" || value === "off")
      return false
    return fallback
  }

  function applySettings() {
    OmaStore.applySettings({
      activeProfile: String(setting("activeProfile", "Default")),
      autoConnect: onOff(setting("autoConnect", "Off"), false),
      notifyConnect: onOff(setting("notifyConnect", "On"), true),
      notifyDrop: onOff(setting("notifyDrop", "On"), true),
      showIpInBar: onOff(setting("showIpInBar", "Off"), false),
      showUsername: onOff(setting("showUsername", "Off"), false)
    })
  }

  Component.onCompleted: applySettings()
  onSettingsChanged: applySettings()

  // The only timer in the plugin: the auth-phase pulse. It does not poll.
  Timer {
    id: authPulse
    interval: 700
    repeat: true
    running: OmaStore.phase === "auth"
    onTriggered: root.pulseOn = !root.pulseOn
  }

  FontMetrics {
    id: ipMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  readonly property string barIp: (OmaStore.showIpInBar && OmaStore.phase === "connected") ? OmaStore.ip : ""
  readonly property real ipWidth: barIp === "" ? 0 : ipMetrics.advanceWidth(barIp)

  BarIconButton {
    id: button
    objectName: "barButton"
    anchors.fill: parent
    bar: root.bar
    dimmed: root.iconDimmed
    tooltipText: OmaStore.tooltipText()
    slotSize: Style.bar.iconSlot + (root.ipWidth > 0 ? root.ipWidth + Style.space(4) : 0)
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(4)
          Text {
            objectName: "barGlyph"
            anchors.verticalCenter: parent.verticalCenter
            text: OmaStore.phase === "connected" ? "\u{f09c}" : "\u{f023}"
            textFormat: Text.PlainText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: root.iconColor
            opacity: OmaStore.phase === "auth" && !root.pulseOn ? 0.35 : 1
          }
          Text {
            objectName: "barIp"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.barIp !== ""
            text: root.barIp
            textFormat: Text.PlainText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering
            color: root.iconColor
          }
        }
      }
    }
    onPressed: function (buttonCode) { root.toggle() }
  }

  onOpenedChanged: if (root.opened) OmaStore.refreshDeps()

  KeyboardPanel {
    id: card
    objectName: "vpnPanel"
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: Style.space(300)
    contentHeight: card.fittedContentHeight(popup.implicitHeight, Style.space(520))

    OmaPopup {
      id: popup
      objectName: "vpnPopup"
      width: parent.width
    }
  }
}
