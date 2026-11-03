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
