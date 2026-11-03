// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Ui
import "."

// Dropdown. With the daemon socket absent this is only the setup card.
Column {
  id: root
  spacing: Style.spacing.sm

  readonly property string fontFamily: OmaStore.pluginRoot ? Style.font.family : Style.font.family

  readonly property var activeEntry: {
    var profiles = OmaStore.profiles
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i] && profiles[i].name === OmaStore.activeProfile)
        return profiles[i]
    }
    return null
  }

  readonly property var gatewayModel: {
    var list = []
    if (activeEntry && activeEntry.gateways && activeEntry.gateways.length)
      list = activeEntry.gateways
    if (list.length === 0)
      list = OmaStore.gateways || []
    return list
  }

  Column {
    objectName: "setupCard"
    visible: !OmaStore.socketUp
    width: parent.width
    spacing: Style.spacing.xs

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: "OmaGlobal needs a one-time setup before it can connect. Run this in a terminal:"
    }

    Text {
      objectName: "setupCommand"
      width: parent.width
      textFormat: Text.PlainText
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: OmaStore.setupCommand
    }

    WidgetButton {
      objectName: "copySetup"
      text: "Copy"
      onPressed: function (button) { OmaStore.copySetup() }
    }
  }

  Column {
    objectName: "sessionCard"
    visible: OmaStore.socketUp
    width: parent.width
    spacing: Style.spacing.xs

    Text {
      objectName: "statusLine"
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: OmaStore.phase === "failed" ? Color.urgent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: OmaStore.statusLine
    }

    WidgetButton {
      objectName: "connectButton"
      text: (OmaStore.phase === "connected" || OmaStore.phase === "auth" || OmaStore.phase === "connecting") ? "Disconnect" : "Connect"
      onPressed: function (button) {
        if (OmaStore.phase === "off" || OmaStore.phase === "failed")
          OmaStore.connect()
        else
          OmaStore.disconnect()
      }
    }

    Text {
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Profile"
    }

    Repeater {
      model: OmaStore.profiles
      WidgetButton {
        objectName: "profileButton"
        text: modelData.name
        active: modelData.name === OmaStore.activeProfile
        onPressed: function (button) { OmaStore.chooseProfile(modelData.name) }
      }
    }

    Text {
      visible: OmaStore.profiles.length === 0
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Add a profile with gpvpn profile add"
    }

    Text {
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Gateway"
    }

    Text {
      objectName: "gatewayEmpty"
      visible: root.gatewayModel.length === 0
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Connect once and the portal's gateways show up here."
    }

    WidgetButton {
      objectName: "gatewayAuto"
      visible: root.gatewayModel.length > 0
      text: "Automatic"
      active: root.activeEntry === null || !root.activeEntry.gateway
      onPressed: function (button) { OmaStore.chooseGateway("", "") }
    }

    Repeater {
      model: root.gatewayModel
      WidgetButton {
        objectName: "gatewayButton"
        text: modelData.name || modelData.host || ""
        active: root.activeEntry !== null && root.activeEntry.gatewayName === (modelData.name || "")
        onPressed: function (button) { OmaStore.chooseGateway(modelData.name || "", modelData.host || "") }
      }
    }

    Column {
      objectName: "sessionFacts"
      visible: OmaStore.phase === "connected"
      width: parent.width
      spacing: Style.spacing.xxs

      Text {
        objectName: "vpnIp"
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: OmaStore.ip
      }
      Text {
        objectName: "vpnGateway"
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: OmaStore.gateway
      }
      Text {
        objectName: "vpnExpires"
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: OmaStore.expires
      }
    }

    Text {
      objectName: "errorLine"
      visible: OmaStore.phase === "failed" && OmaStore.message !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: OmaStore.message
    }
  }
}
