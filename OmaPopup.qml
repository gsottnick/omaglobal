// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Ui
import "."

// Dropdown. With the daemon socket absent this is only the setup card.
Column {
  id: root
  spacing: Style.space(10)

  readonly property string fontFamily: OmaStore.pluginRoot ? Style.font.family : Style.font.family

  readonly property var activeEntry: {
    var profiles = OmaStore.profiles
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i] && profiles[i].name === OmaStore.activeProfile)
        return profiles[i]
    }
    return null
  }

  readonly property var installedItems: {
    var out = []
    var items = OmaStore.deps || []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].present)
        out.push(items[i])
    }
    return out
  }

  readonly property var missingItems: {
    var out = []
    var items = OmaStore.deps || []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && !items[i].present)
        out.push(items[i])
    }
    return out
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
    // A machine that already has the tunnel, the login window, and the
    // service is ready: the connect controls show and this card does not.
    visible: !OmaStore.ready || root.missingItems.length > 0
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader {
      text: "Setup"
      width: parent.width
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: OmaStore.depsLoaded
        ? "OmaGlobal needs a VPN tunnel, a login window, and a background service. Install adds only what is missing and asks for your password in a terminal."
        : "Checking what's installed."
    }

    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: root.installedItems.length > 0

      PanelSectionHeader { text: "Installed" }

      Repeater {
        model: root.installedItems
        Text {
          objectName: "installedDep"
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          text: modelData.name + " — " + modelData.purpose
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: root.missingItems.length > 0

      PanelSectionHeader { text: "Will install" }

      Repeater {
        model: root.missingItems
        Text {
          objectName: "missingDep"
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          text: modelData.name + " — " + modelData.purpose
        }
      }
    }

    Button {
      objectName: "installSetup"
      width: parent.width
      visible: root.missingItems.length > 0
      text: OmaStore.installRunning ? "Installing..." : "Install"
      bordered: true
      active: !OmaStore.installRunning
      enabled: !OmaStore.installRunning
      verticalPadding: Style.space(8)
      onClicked: OmaStore.installSetup()
    }
  }

  Column {
    objectName: "sessionCard"
    visible: OmaStore.socketUp
    width: parent.width
    spacing: Style.space(10)

    Column {
      id: profileForm
      objectName: "profileForm"
      visible: OmaStore.profiles.length === 0
      width: parent.width
      spacing: Style.space(4)

      PanelSectionHeader { text: "Profile" }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: "Enter the portal address and the username you sign in with."
      }

      TextField {
        id: portalField
        objectName: "portalField"
        width: parent.width
        placeholderText: "Portal address"
        onAccepted: usernameField.forceActiveFocus()
      }

      TextField {
        id: usernameField
        objectName: "usernameField"
        width: parent.width
        placeholderText: "Username"
        onAccepted: OmaStore.saveAndConnect(portalField.text, usernameField.text)
      }
    }

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

    Button {
      objectName: "connectButton"
      width: parent.width
      bordered: true
      active: OmaStore.phase === "connected"
      verticalPadding: Style.space(8)
      enabled: !OmaStore.profileSaving
      text: {
        if (OmaStore.profileSaving)
          return "Saving..."
        if (OmaStore.phase === "connected" || OmaStore.phase === "auth" || OmaStore.phase === "connecting")
          return "Disconnect"
        return "Connect"
      }
      onClicked: {
        if (OmaStore.phase === "connected" || OmaStore.phase === "auth" || OmaStore.phase === "connecting")
          OmaStore.disconnect()
        else if (OmaStore.profiles.length === 0)
          OmaStore.saveAndConnect(portalField.text, usernameField.text)
        else
          OmaStore.connect()
      }
    }

    Column {
      visible: OmaStore.profiles.length > 0
      width: parent.width
      spacing: Style.space(4)

      PanelSectionHeader { text: "Profile" }

      Repeater {
        model: OmaStore.profiles
        Button {
          objectName: "profileButton"
          width: parent.width
          bordered: true
          leftAlign: true
          text: modelData.name
          active: modelData.name === OmaStore.activeProfile
          onClicked: OmaStore.chooseProfile(modelData.name)
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      PanelSectionHeader { text: "Gateway" }

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

      Button {
        objectName: "gatewayAuto"
        visible: root.gatewayModel.length > 0
        width: parent.width
        bordered: true
        leftAlign: true
        text: "Automatic"
        active: root.activeEntry === null || !root.activeEntry.gateway
        onClicked: OmaStore.chooseGateway("", "")
      }

      Repeater {
        model: root.gatewayModel
        Button {
          objectName: "gatewayButton"
          width: parent.width
          bordered: true
          leftAlign: true
          text: modelData.name || modelData.host || ""
          active: root.activeEntry !== null && root.activeEntry.gatewayName === (modelData.name || "")
          onClicked: OmaStore.chooseGateway(modelData.name || "", modelData.host || "")
        }
      }
    }

    Column {
      objectName: "sessionFacts"
      visible: OmaStore.phase === "connected"
      width: parent.width
      spacing: Style.space(2)

      PanelSectionHeader { text: "Session" }

      Text {
        objectName: "vpnIp"
        width: parent.width
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Address  " + OmaStore.ip
      }
      Text {
        objectName: "vpnGateway"
        width: parent.width
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Gateway  " + OmaStore.gateway
      }
      Text {
        objectName: "vpnExpires"
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: "Expires  " + OmaStore.expires
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
