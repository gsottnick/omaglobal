// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Ui
import "."

// Every screen of the dropdown, top to bottom. Which Column shows is the
// store's `screen`; this file holds no logic the store should own.
Column {
  id: root
  spacing: Style.space(10)
  clip: true

  // ---- Small shared pieces ---------------------------------------------

  // Three accent dots orbiting a thin ring. Runs only while visible and
  // motion is allowed.
  component Orbit: Item {
    id: orbitItem
    width: Style.space(52)
    height: Style.space(52)
    readonly property bool spinning: orbitItem.visible && !Style.reduceMotion
    RotationAnimation on rotation {
      running: orbitItem.spinning
      loops: Animation.Infinite
      from: 0
      to: 360
      duration: 1500
    }
    Rectangle {
      anchors.centerIn: parent
      width: Style.space(40)
      height: Style.space(40)
      radius: width / 2
      color: "transparent"
      border.color: Color.muted
      border.width: 2
      opacity: 0.35
    }
    Repeater {
      model: 3
      Rectangle {
        required property int index
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        color: Color.accent
        x: parent.width / 2 - width / 2
        y: Style.space(2)
        transform: Rotation {
          origin.x: parent.width / 2 - x
          origin.y: parent.height / 2 - y
          angle: index * 120
        }
      }
    }
  }

  component RowCaption: Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  component ChoiceRow: Row {
    id: choice
    property string value: ""
    property var options: []
    signal picked(string value)
    spacing: Style.space(6)
    Repeater {
      model: choice.options
      Button {
        required property var modelData
        text: modelData.label
        active: choice.value === modelData.value
        fontSize: Style.font.bodySmall
        verticalPadding: Style.space(4)
        onClicked: choice.picked(modelData.value)
      }
    }
  }

  // One advanced option: control on top, one-line explanation under it.
  // The explanation RowCaption sits under each control inline.

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

  readonly property bool connecting: OmaStore.stepText !== "" && OmaStore.phase !== "connected"

  // ---- Editor state -----------------------------------------------------

  property var edit: ({})
  property bool advancedOpen: false
  property bool askPassword: false

  function beginEdit(name) {
    var entry = null
    var profiles = OmaStore.profiles
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i] && profiles[i].name === name)
        entry = profiles[i]
    }
    edit = {
      name: entry ? String(entry.name) : "",
      portal: entry ? String(entry.portal || "") : "",
      username: entry ? String(entry.username || "") : "",
      authMethod: entry ? String(entry.authMethod || "sso") : "sso",
      interface: entry ? String(entry.interface || "gateway") : "gateway",
      os: entry && entry.os ? String(entry.os) : "",
      useragent: entry && entry.useragent ? String(entry.useragent) : "",
      csdWrapper: entry && entry.csdWrapper ? String(entry.csdWrapper) : "",
      servercert: entry && entry.servercert ? String(entry.servercert) : "",
      cafile: entry && entry.cafile ? String(entry.cafile) : "",
      certificate: entry && entry.certificate ? String(entry.certificate) : "",
      sslkey: entry && entry.sslkey ? String(entry.sslkey) : "",
      baseMtu: entry && entry.baseMtu ? String(entry.baseMtu) : "",
      noDtls: entry ? entry.noDtls === true : false,
      reconnectTimeout: entry && entry.reconnectTimeout ? String(entry.reconnectTimeout) : "",
      vpncScript: entry && entry.vpncScript ? String(entry.vpncScript) : ""
    }
    advancedOpen = false
    // The editor stays instantiated between opens; push the values in.
    editNameField.text = String(edit.name || "")
    editPortalField.text = String(edit.portal || "")
    editUserField.text = String(edit.username || "")
    editUaField.text = String(edit.useragent || "")
    editCsdField.text = String(edit.csdWrapper || "")
    editCertPinField.text = String(edit.servercert || "")
    editCaField.text = String(edit.cafile || "")
    editClientCertField.text = String(edit.certificate || "")
    editClientKeyField.text = String(edit.sslkey || "")
    editMtuField.text = String(edit.baseMtu || "")
    editReconnectField.text = String(edit.reconnectTimeout || "")
    editVpncField.text = String(edit.vpncScript || "")
    OmaStore.openEditor(name || "")
  }

  function saveEdit() {
    OmaStore.saveEditor(edit)
    edit = {}
  }

  // ---- 1. Checking ------------------------------------------------------

  Column {
    objectName: "checkingCard"
    visible: OmaStore.screen === "checking"
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader { text: "OmaGlobal" }

    Row {
      spacing: Style.space(10)
      Orbit { anchors.verticalCenter: parent.verticalCenter }
      RowCaption {
        width: parent.parent.width - Style.space(62)
        anchors.verticalCenter: parent.verticalCenter
        text: "Checking what this computer already has."
      }
    }
  }

  // ---- 2. Setup ---------------------------------------------------------

  Column {
    objectName: "setupCard"
    visible: OmaStore.screen === "setup"
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader { text: "Welcome to OmaGlobal" }

    RowCaption {
      text: "A company VPN you can run from this bar. One install step needs your password, then connecting is a single click."
    }

    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: root.installedItems.length > 0

      PanelSectionHeader { text: "Already on this computer" }

      Repeater {
        model: root.installedItems
        RowCaption { objectName: "installedDep"; text: modelData.name + " — " + modelData.purpose }
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(2)
      visible: root.missingItems.length > 0

      PanelSectionHeader { text: "Ready to add" }

      Repeater {
        model: root.missingItems
        RowCaption {
          objectName: "missingDep"
          color: Color.foreground
          text: modelData.name + " — " + modelData.purpose
        }
      }
    }

    Button {
      objectName: "installSetup"
      width: parent.width
      visible: root.missingItems.length > 0
      text: "Install"
      iconText: ""
      bordered: true
      verticalPadding: Style.space(8)
      onClicked: OmaStore.installSetup()
    }
  }

  // ---- 3. Installing ----------------------------------------------------

  Column {
    objectName: "installingCard"
    visible: OmaStore.screen === "installing"
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader { text: "Installing" }

    Row {
      spacing: Style.space(10)
      Orbit { anchors.verticalCenter: parent.verticalCenter }
      Column {
        width: parent.parent.width - Style.space(62)
        spacing: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          text: OmaStore.installDetail !== "" ? OmaStore.installDetail : "Working."
        }
        RowCaption {
          text: "The terminal asks for your password once. Keep it open until it says setup finished."
        }
      }
    }
  }

  // ---- 4. Install failed ------------------------------------------------

  Column {
    objectName: "installFailedCard"
    visible: OmaStore.screen === "installFailed"
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader { text: "Install did not finish" }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: OmaStore.installError !== "" ? OmaStore.installError : "Something went wrong."
    }

    RowCaption {
      text: "Fix the problem it mentions, then try again."
    }

    Button {
      objectName: "installRetry"
      width: parent.width
      text: "Try again"
      bordered: true
      verticalPadding: Style.space(8)
      onClicked: OmaStore.installSetup()
    }
  }

  // ---- 5. Welcome -------------------------------------------------------

  Column {
    objectName: "welcomeCard"
    visible: OmaStore.screen === "welcome"
    width: parent.width
    spacing: Style.space(10)

    PanelHero {
      title: "OmaGlobal"
      meta: "Company VPN"
      fontFamily: Style.font.family
    }

    RowCaption {
      text: "This connects you to your company's GlobalProtect VPN. Type the portal address below, press Connect, and sign in when the window appears."
    }

    Text {
      objectName: "portalHint"
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Not sure what to type? Ask your IT team for the \u201cGlobalProtect portal address\u201d."
    }

    TextField {
      id: portalField
      objectName: "portalField"
      width: parent.width
      placeholderText: "vpn.yourcompany.com"
      onAccepted: OmaStore.saveAndConnect(text, usernameField.text)
    }

    Column {
      width: parent.width
      spacing: Style.space(2)

      Button {
        objectName: "advancedToggle"
        width: parent.width
        leftAlign: true
        bordered: true
        text: "Advanced"
        fontSize: Style.font.bodySmall
        onClicked: advancedRevealed.visible = !advancedRevealed.visible
      }

      Column {
        id: advancedRevealed
        visible: false
        width: parent.width
        spacing: Style.space(4)

        TextField {
          id: usernameField
          objectName: "usernameField"
          width: parent.width
          placeholderText: "Username (usually not needed)"
        }

        RowCaption {
          text: "The sign-in window knows your account. Only set this if IT gave you a separate VPN username."
        }
      }
    }

    Button {
      objectName: "connectButton"
      width: parent.width
      bordered: true
      active: OmaStore.phase === "connected"
      enabled: !OmaStore.profileSaving
      verticalPadding: Style.space(8)
      text: OmaStore.profileSaving ? "Saving..." : "Connect"
      onClicked: OmaStore.saveAndConnect(portalField.text, usernameField.text)
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

  // ---- 6. Main ----------------------------------------------------------

  Column {
    objectName: "sessionCard"
    visible: OmaStore.screen === "main"
    width: parent.width
    spacing: Style.space(10)

    // Connecting: the orbit plus where the connection is.
    Column {
      objectName: "connectingCard"
      visible: root.connecting
      width: parent.width
      spacing: Style.space(8)

      Orbit {
        anchors.horizontalCenter: parent.horizontalCenter
      }

      Text {
        objectName: "stepLine"
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: OmaStore.stepText
      }

      RowCaption {
        text: OmaStore.activeAuthMethod === "password"
          ? "Using the saved password for " + OmaStore.activeProfile + "."
          : "A sign-in window opens the first time. Keep it open until it finishes."
      }
    }

    // Password prompt for password profiles, once per attempt.
    Column {
      objectName: "passwordCard"
      visible: root.askPassword
      width: parent.width
      spacing: Style.space(6)

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Password for " + OmaStore.activeProfile
      }

      TextField {
        id: passwordField
        objectName: "passwordField"
        width: parent.width
        password: true
        placeholderText: "VPN password"
        onAccepted: { root.askPassword = false; OmaStore.preparePassword(text); text = "" }
      }

      RowCaption {
        text: "It is sent only to the VPN service on this computer."
      }
    }

    // Connected.
    Column {
      objectName: "sessionFacts"
      visible: OmaStore.phase === "connected"
      width: parent.width
      spacing: Style.space(2)

      // One quiet transition when the tunnel lands.
      opacity: OmaStore.phase === "connected" ? 1 : 0
      scale: OmaStore.phase === "connected" ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: Style.duration(220) } }
      Behavior on scale { NumberAnimation { duration: Style.duration(220) } }

      PanelSectionHeader { text: "Connected" }

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
        objectName: "vpnUpFor"
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Up for  " + OmaStore.upFor()
      }
      Text {
        objectName: "vpnGateway"
        width: parent.width
        elide: Text.ElideRight
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
      Text {
        objectName: "vpnTraffic"
        visible: OmaStore.iface !== ""
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: "Data  " + OmaStore.humanBytes(OmaStore.rxBytes) + " down  " + OmaStore.humanBytes(OmaStore.txBytes) + " up"
      }
    }

    Text {
      objectName: "statusLine"
      visible: OmaStore.phase !== "connected" && !root.connecting && OmaStore.phase !== "failed"
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: OmaStore.phase === "failed" ? Color.urgent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: OmaStore.statusLine
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
      text: OmaStore.message + "  Check the portal address and try again."
    }

    Button {
      objectName: "vpnConnectButton"
      width: parent.width
      bordered: true
      active: OmaStore.phase === "connected"
      verticalPadding: Style.space(8)
      text: OmaStore.phase === "connected" ? "Disconnect"
        : (root.connecting ? "Cancel" : "Connect")
      onClicked: {
        if (OmaStore.phase === "connected")
          OmaStore.disconnect()
        else if (root.connecting) {
          root.askPassword = false
          OmaStore.disconnect()
        } else if (OmaStore.activeAuthMethod === "password")
          root.askPassword = true
        else
          OmaStore.connect()
      }
    }

    Button {
      objectName: "reconnectButton"
      width: parent.width
      visible: OmaStore.phase === "connected"
      bordered: true
      verticalPadding: Style.space(8)
      text: "Reconnect"
      onClicked: OmaStore.reconnect()
    }

    PanelSectionHeader { text: "Your VPNs" }

    Repeater {
      model: OmaStore.profiles
      Row {
        required property var modelData
        width: parent.width
        spacing: Style.space(6)
        Button {
          objectName: "profileButton"
          width: parent.width - Style.space(58)
          bordered: true
          leftAlign: true
          text: modelData.name
          active: modelData.name === OmaStore.activeProfile
          onClicked: OmaStore.switchTo(modelData.name)
        }
        Button {
          objectName: "profileEditButton"
          width: Style.space(52)
          bordered: true
          text: "Edit"
          fontSize: Style.font.bodySmall
          onClicked: root.beginEdit(modelData.name)
        }
      }
    }

    Button {
      objectName: "addVpn"
      width: parent.width
      bordered: true
      leftAlign: true
      text: "Add a VPN"
      fontSize: Style.font.bodySmall
      onClicked: root.beginEdit("")
    }
  }

  // ---- 7. Editor --------------------------------------------------------

  Item {
    objectName: "editorCard"
    visible: OmaStore.screen === "editor"
    width: parent.width
    height: visible ? Style.space(430) : 0

    PanelSectionHeader {
      id: editorHeader
      text: OmaStore.editorName === "" ? "Add a VPN" : "Edit " + OmaStore.editorName
      width: parent.width
    }

    Flickable {
      anchors.top: editorHeader.bottom
      anchors.topMargin: Style.space(8)
      width: parent.width
      height: parent.height - editorHeader.implicitHeight - Style.space(8)
      clip: true
      contentHeight: editorBody.implicitHeight
      interactive: contentHeight > height

      Column {
        id: editorBody
        width: parent.width
        spacing: Style.space(8)

        Column {
          id: editorTop
          objectName: "editorTop"
          width: parent.width
          spacing: Style.space(8)

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Name"
    }
    TextField {
      id: editNameField
      objectName: "editorName"
      width: parent.width
      placeholderText: "Work VPN"
      onTextChanged: root.edit.name = text
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Portal address"
    }
    TextField {
      id: editPortalField
      objectName: "editorPortal"
      width: parent.width
      placeholderText: "vpn.yourcompany.com"
      onTextChanged: root.edit.portal = text
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Sign in with"
    }
    ChoiceRow {
      objectName: "editorAuth"
      width: parent.width
      value: root.edit.authMethod || "sso"
      options: [
        { label: "SSO (browser)", value: "sso" },
        { label: "Password", value: "password" }
      ]
      onPicked: function (value) { root.edit.authMethod = value }
    }
    RowCaption {
      text: root.edit.authMethod === "password"
        ? "You type the password each time you connect."
        : "A browser-style window signs you in, SSO and two-factor included."
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Username"
    }
    TextField {
      id: editUserField
      objectName: "editorUsername"
      width: parent.width
      placeholderText: "Usually filled in by signing in"
      onTextChanged: root.edit.username = text
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Where to connect"
    }
    ChoiceRow {
      objectName: "editorInterface"
      width: parent.width
      value: root.edit.interface || "gateway"
      options: [
        { label: "Portal (normal)", value: "portal" },
        { label: "Gateway directly", value: "gateway" }
      ]
      onPicked: function (value) { root.edit.interface = value }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Gateway"
    }
    Button {
      objectName: "gatewayAuto"
      width: parent.width
      bordered: true
      leftAlign: true
      fontSize: Style.font.bodySmall
      text: "Automatic — the VPN picks the best one"
      active: (root.edit.gatewayName || "") === "" && (root.edit.gateway || "") === ""
      onClicked: {
        root.edit.gateway = ""
        root.edit.gatewayName = ""
        OmaStore.chooseGateway("", "")
      }
    }
    Repeater {
      model: root.gatewayModel
      Button {
        objectName: "gatewayButton"
        width: parent.width
        bordered: true
        leftAlign: true
        fontSize: Style.font.bodySmall
        text: modelData.name || modelData.host || ""
        active: root.edit.gatewayName === (modelData.name || "")
        onClicked: {
          root.edit.gatewayName = String(modelData.name || "")
          root.edit.gateway = String(modelData.host || "")
          OmaStore.chooseGateway(modelData.name || "", modelData.host || "")
        }
      }
    }

        }

    Button {
      objectName: "editorAdvancedToggle"
      width: parent.width
      bordered: true
      leftAlign: true
      fontSize: Style.font.bodySmall
      text: root.advancedOpen ? "Hide advanced options" : "Advanced options"
      onClicked: root.advancedOpen = !root.advancedOpen
    }

    Column {
      objectName: "editorAdvanced"
      visible: root.advancedOpen
      width: parent.width
      spacing: Style.space(8)

        // --- reported OS ---
        RowCaption { text: "System type reported to the VPN" }
        ChoiceRow {
          objectName: "editorOs"
          width: parent.width
          value: root.edit.os || ""
          options: [
            { label: "Auto", value: "" },
            { label: "Windows", value: "win" },
            { label: "macOS", value: "mac-intel" },
            { label: "Linux", value: "linux-64" }
          ]
          onPicked: function (value) { root.edit.os = value }
        }
        RowCaption { text: "Only change this if IT says the VPN expects a different system." }

        // --- user agent ---
        RowCaption { text: "Browser identity sent at sign-in" }
        TextField {
          id: editUaField
          objectName: "editorUseragent"
          width: parent.width
          placeholderText: "Default — PAN GlobalProtect"
          onTextChanged: root.edit.useragent = text
        }
        RowCaption { text: "Leave blank unless IT gives you a specific one." }

        // --- HIP / csd wrapper ---
        RowCaption { text: "Security check script (HIP)" }
        TextField {
          id: editCsdField
          objectName: "editorCsdWrapper"
          width: parent.width
          placeholderText: "/path/to/check/script"
          onTextChanged: root.edit.csdWrapper = text
        }
        RowCaption { text: "Some gateways demand a Host Information Policy report. This runs the script your IT provides. Off unless required." }

        // --- servercert pin ---
        RowCaption { text: "Server certificate fingerprint" }
        TextField {
          id: editCertPinField
          objectName: "editorServercert"
          width: parent.width
          placeholderText: "40 hex characters"
          onTextChanged: root.edit.servercert = text
        }
        RowCaption { text: "Connects only when the VPN shows exactly this certificate." }

        // --- cafile ---
        RowCaption { text: "Custom certificate authority file" }
        TextField {
          id: editCaField
          objectName: "editorCafile"
          width: parent.width
          placeholderText: "/path/to/company-ca.pem"
          onTextChanged: root.edit.cafile = text
        }
        RowCaption { text: "For VPNs that use a company-issued certificate authority." }

        // --- client cert/key ---
        RowCaption { text: "Client certificate and key" }
        TextField {
          id: editClientCertField
          objectName: "editorCertificate"
          width: parent.width
          placeholderText: "/path/to/client-cert.pem"
          onTextChanged: root.edit.certificate = text
        }
        TextField {
          id: editClientKeyField
          objectName: "editorSslkey"
          width: parent.width
          placeholderText: "/path/to/client-key.pem (if separate)"
          onTextChanged: root.edit.sslkey = text
        }
        RowCaption { text: "For VPNs that identify you by certificate instead of a password." }

        // --- MTU ---
        RowCaption { text: "Tunnel packet size (MTU)" }
        TextField {
          id: editMtuField
          objectName: "editorBaseMtu"
          width: parent.width
          placeholderText: "Default — negotiated automatically"
          onTextChanged: root.edit.baseMtu = text
        }
        RowCaption { text: "Smaller values help on flaky links. Leave blank unless IT says otherwise." }

        // --- no dtls ---
        RowCaption { text: "Use TLS only" }
        Row {
          width: parent.width
          ToggleSwitch {
            objectName: "editorNoDtls"
            checked: root.edit.noDtls === true
            onToggled: root.edit.noDtls = !root.edit.noDtls
          }
          RowCaption {
            width: parent.width - Style.space(60)
            anchors.verticalCenter: parent.verticalCenter
            text: "Turns off the fast UDP path. Slower, but works on networks that block it."
          }
        }

        // --- reconnect timeout ---
        RowCaption { text: "Reconnect patience, in seconds" }
        TextField {
          id: editReconnectField
          objectName: "editorReconnectTimeout"
          width: parent.width
          placeholderText: "Default — 300 seconds"
          onTextChanged: root.edit.reconnectTimeout = text
        }
        RowCaption { text: "How long the tunnel keeps trying before giving up after a drop." }

        // --- vpnc script ---
        RowCaption { text: "Custom routing script" }
        TextField {
          id: editVpncField
          objectName: "editorVpncScript"
          width: parent.width
          placeholderText: "/path/to/vpnc-script"
          onTextChanged: root.edit.vpncScript = text
        }
        RowCaption { text: "Manages which traffic goes through the VPN. Only if you run your own routing rules." }
    }

    Button {
      objectName: "editorSave"
      width: parent.width
      bordered: true
      verticalPadding: Style.space(8)
      text: "Save"
      onClicked: root.saveEdit()
    }

    Button {
      objectName: "editorBack"
      width: parent.width
      bordered: true
      verticalPadding: Style.space(8)
      text: "Back"
      onClicked: OmaStore.closeEditor()
    }

    Button {
      objectName: "editorForget"
      visible: OmaStore.editorName !== ""
      width: parent.width
      bordered: true
      leftAlign: true
      fontSize: Style.font.bodySmall
      text: "Forget saved sign-in"
      onClicked: OmaStore.forgetSignIn(OmaStore.editorName)
    }
    RowCaption {
      visible: OmaStore.editorName !== ""
      text: "Deletes the remembered sign-in on this computer. The next connect asks you to sign in again."
    }

    Button {
      objectName: "editorRemove"
      visible: OmaStore.editorName !== ""
      width: parent.width
      bordered: true
      fontSize: Style.font.bodySmall
      text: "Remove this VPN"
      onClicked: OmaStore.removeProfile(OmaStore.editorName)
    }
  }
    }
  }
}
