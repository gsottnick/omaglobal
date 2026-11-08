// SPDX-License-Identifier: MIT
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "."

// Every screen of the dropdown, top to bottom. Which Column shows is the
// store's `screen`; this file holds no logic the store should own.
Column {
  id: root
  spacing: Style.space(10)
  clip: true

  // ---- Small shared pieces ---------------------------------------------

  // Body text. Explanations read as normal foreground; only titles and
  // state words take accent, so nothing looks like an error by default.
  component RowCaption: Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  // The shell's popups color secondary text as the normal foreground at
  // reduced opacity (network Panel.qml InfoLabel); follow that exactly.
  component HintCaption: Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: Commons.Color.foreground
    opacity: 0.6
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  // A big status block: state icon, state word, VPN name. Connecting gets
  // dots orbiting the shield; connected gets one ripple; failed fades down.
  // A Column, so the height always covers every line it draws and nothing
  // below the hero can overlap its text.
  component StateHero: Column {
    id: hero
    width: parent.width
    spacing: Style.space(2)

    property string stateWord: "Disconnected"
    property string who: ""
    property bool connecting: false
    property int connectStep: 0 // 1 sign-in, 2 gateway, 3 tunnel
    // A screen title (setup, welcome, sign-in prompt), not a VPN state: never dimmed.
    property bool title: false

    // Room around the shield, so the arrival ring is not cut off.
    Item {
      width: parent.width
      height: heroShield.height + Style.space(22)
      ShieldMark {
        id: heroShield
        objectName: "heroShield"
        anchors.centerIn: parent
        size: Style.space(58)
      }
    }

    Text {
      id: stateLine
      objectName: "heroState"
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      color: hero.title ? Commons.Color.foreground : ShieldMotion.tint
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: hero.stateWord
      // The word changes while it is out of sight, in step with the shield.
      Behavior on text {
        SequentialAnimation {
          NumberAnimation { target: stateLine; property: "opacity"; to: 0; duration: Style.duration(110) }
          PropertyAction { target: stateLine; property: "text" }
          NumberAnimation { target: stateLine; property: "opacity"; to: 1; duration: Style.duration(170) }
        }
      }
    }

    Text {
      id: whoLine
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: hero.who !== ""
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      opacity: 0.6
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: hero.who
    }

    // Three-step indicator while connecting: Sign in → Gateway → Tunnel.
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: hero.connecting && hero.connectStep > 0
      textFormat: Text.PlainText
      color: ShieldMotion.tint
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Step " + hero.connectStep + " of 3 — "
        + ["", "Sign in", "Gateway", "Tunnel"][hero.connectStep]
    }

    Text {
      objectName: "stepHint"
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: hero.connecting
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      opacity: 0.7
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: root.stepHint
    }
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

  // The three things setup actually delivers, each backed by a dep group.
  readonly property var setupGroups: {
    var present = {}
    var items = OmaStore.deps || []
    for (var i = 0; i < items.length; i++) {
      if (items[i])
        present[items[i].name] = items[i].present === true
    }
    return [
      {
        label: "VPN tunnel",
        why: "Builds the encrypted connection",
        ready: present["openconnect"] === true
      },
      {
        label: "Sign-in window",
        why: "Opens the page where you sign in to your VPN",
        ready: present["webkit2gtk-4.1"] === true && present["gp-saml-gui"] === true
      },
      {
        label: "Background service",
        why: "Starts and stops the tunnel from the bar",
        ready: present["gp-vpn.socket"] === true && present["gpvpnd"] === true
      }
    ]
  }

  // The list saved with the VPN being edited, or the live one when it is connected.
  readonly property var gatewayModel: {
    var saved = edit.gateways || []
    if (saved.length === 0 && OmaStore.editorName === OmaStore.activeProfile)
      return OmaStore.gateways || []
    return saved
  }

  readonly property bool connecting: OmaStore.stepText !== "" && OmaStore.phase !== "connected"
  readonly property bool passwordVpn: OmaStore.activeAuthMethod === "password"
  // The daemon only hears about a connect after sign-in, so its "auth" is step 2.
  readonly property int connectStep: {
    if (OmaStore.phase === "connecting")
      return 3
    if (OmaStore.phase === "auth")
      return 2
    return root.connecting ? 1 : 0
  }
  // Each connecting step explains itself.
  readonly property string stepHint: {
    if (connectStep === 1)
      return passwordVpn ? "Checking your details with the VPN."
        : "Finish signing in in the window that opened. If it signs you in by itself, it closes by itself."
    if (connectStep === 2)
      return "Signed in. Contacting the VPN."
    if (connectStep === 3)
      return "The VPN picks the best gateway and brings the tunnel up."
    return ""
  }

  // ---- Editor state -----------------------------------------------------

  // The harness (and any future caller) scrolls the editor by setting this;
  // the assignment happens here in QML rather than being poked from outside.
  property real editorScrollTo: 0
  onEditorScrollToChanged: editorScroll.contentY = Math.max(0,
    Math.min(editorScroll.contentHeight - editorScroll.height, editorScrollTo))

  // Always replace this object: QML does not see a key changing inside it,
  // so a control bound to one would keep showing the old value.
  property var edit: ({})
  property bool advancedOpen: false
  property bool removeArmed: false

  function setEdit(changes) {
    edit = Object.assign({}, edit, changes)
  }

  readonly property bool canSetDefault: OmaStore.editorName !== "" && !OmaStore.busy

  function submitPassword() {
    if (passwordField.text === "") {
      passwordField.forceActiveFocus()
      return
    }
    OmaStore.preparePassword(passwordField.text)
    passwordField.text = ""
  }

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
      interface: entry ? String(entry.interface || "portal") : "portal",
      gateway: entry ? String(entry.gateway || "") : "",
      gatewayName: entry ? String(entry.gatewayName || "") : "",
      gateways: entry && entry.gateways ? entry.gateways : [],
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
    removeArmed = false
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

  onRemoveArmedChanged: {
    if (removeArmed) {
      // Scroll once the layout knows the confirm row's height.
      Qt.callLater(function () { editorScrollTo = 999999 })
    }
  }

  function saveEdit() {
    OmaStore.saveEditor(edit)
  }

  // ---- 1. Checking ------------------------------------------------------

  Column {
    objectName: "checkingCard"
    visible: OmaStore.screen === "checking"
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader { text: "OmaGlobal" }

    RowCaption {
      text: "Checking what this computer already has."
    }
  }

  // ---- 2. Setup ---------------------------------------------------------

  Column {
    objectName: "setupCard"
    visible: OmaStore.screen === "setup"
    width: parent.width
    spacing: Style.space(10)

    StateHero {
      stateWord: OmaStore.updateOnly ? "Update OmaGlobal" : "Set up OmaGlobal"
      title: true
      who: ""
    }

    RowCaption {
      text: OmaStore.updateOnly
        ? "This version comes with a newer background service. Updating asks for your password once, then you are back here."
        : "Connect to any GlobalProtect VPN from this bar. One install step needs your password, then connecting is a single click."
    }

    Column {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.setupGroups
        Row {
          required property var modelData
          width: parent.width
          spacing: Style.space(8)
          Text {
            objectName: "setupGroupIcon"
            text: modelData.ready ? "\u{f00c}" : "\u{f00d}"
            textFormat: Text.PlainText
            color: modelData.ready ? Commons.Color.accent : Commons.Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Column {
            width: parent.width - Style.space(20)
            spacing: Style.space(1)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              text: modelData.label + (modelData.ready ? " — ready"
                : (OmaStore.updateOnly ? " — needs an update" : " — will be added"))
            }
            HintCaption { text: modelData.why }
          }
        }
      }
    }

    Button {
      objectName: "setupDetailsToggle"
      width: parent.width
      leftAlign: true
      bordered: true
      fontSize: Style.font.bodySmall
      text: detailsRevealed.visible ? "Hide details" : "Details"
      onClicked: detailsRevealed.visible = !detailsRevealed.visible
    }

    Column {
      id: detailsRevealed
      visible: false
      width: parent.width
      spacing: Style.space(2)

      PanelSectionHeader { text: "Packages" }

      Repeater {
        model: root.installedItems
        HintCaption { objectName: "installedDep"; text: modelData.name + " — " + modelData.purpose }
      }
      Repeater {
        model: root.missingItems
        HintCaption {
          objectName: "missingDep"
          text: modelData.name + " — " + modelData.purpose
        }
      }
    }

    Button {
      objectName: "installSetup"
      width: parent.width
      text: OmaStore.updateOnly ? "Update" : "Install"
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
    spacing: Style.space(4)

    StateHero {
      stateWord: "Installing"
      connecting: true
      who: ""
    }

    RowCaption {
      text: OmaStore.installDetail !== "" ? OmaStore.installDetail : "Working."
    }

    HintCaption {
      text: "The terminal asks for your password once. Keep it open until it says setup finished."
    }
  }

  // ---- 4. Install failed ------------------------------------------------

  Column {
    objectName: "installFailedCard"
    visible: OmaStore.screen === "installFailed"
    width: parent.width
    spacing: Style.space(10)

    StateHero {
      stateWord: "Install did not finish"
      who: ""
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: OmaStore.installError !== "" ? OmaStore.installError : "Something went wrong."
    }

    HintCaption {
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

    StateHero {
      stateWord: "Welcome"
      title: true
      who: "GlobalProtect VPN"
    }

    RowCaption {
      text: "Connect to any GlobalProtect VPN: work, school, or your own. Type the portal address below, press Connect, and sign in when the window appears."
    }

    HintCaption {
      text: "Not sure what to type? Use the address whoever runs your VPN gave you, often called the \u201cportal address\u201d."
    }

    TextField {
      id: portalField
      objectName: "portalField"
      width: parent.width
      placeholderText: "vpn.example.com"
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

        HintCaption {
          text: "The sign-in window knows your account. Only set this if your VPN uses a separate username."
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
      color: Commons.Color.urgent
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

    StateHero {
      stateWord: OmaStore.askPassword ? "Sign in to " + OmaStore.activeProfile
        : (root.connecting ? "Connecting"
        : (OmaStore.phase === "connected" ? "Connected"
        : (OmaStore.phase === "failed" ? (OmaStore.rawState === "dropped" ? "Dropped" : "Failed")
        : "Disconnected")))
      who: OmaStore.askPassword ? "" : OmaStore.activeProfile
      title: OmaStore.askPassword
      connecting: root.connecting
      connectStep: root.connectStep
    }

    // Password prompt for password profiles, once per attempt.
    Column {
      objectName: "passwordCard"
      visible: OmaStore.askPassword
      width: parent.width
      spacing: Style.space(6)

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        color: Commons.Color.foreground
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
        onAccepted: root.submitPassword()
      }

      HintCaption {
        text: "It is sent only to the VPN service on this computer."
      }
    }

    // Connected facts. The hero already says Connected.
    Column {
      objectName: "sessionFacts"
      visible: OmaStore.phase === "connected"
      width: parent.width
      spacing: Style.space(2)

      opacity: OmaStore.phase === "connected" ? 1 : 0
      scale: OmaStore.phase === "connected" ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: Style.duration(220) } }
      Behavior on scale { NumberAnimation { duration: Style.duration(220) } }

      Text {
        objectName: "vpnIp"
        width: parent.width
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Address  " + OmaStore.ip
      }
      Text {
        objectName: "vpnUpFor"
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Up for  " + OmaStore.upFor()
      }
      Text {
        objectName: "vpnGateway"
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Gateway  " + OmaStore.gateway
      }
      Row {
        objectName: "vpnExpires"
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "Expires"
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          text: OmaStore.expiresText()
          elide: Text.ElideRight
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
      Row {
        objectName: "vpnTraffic"
        visible: OmaStore.iface !== ""
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "Data"
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          text: OmaStore.humanBytes(OmaStore.rxBytes) + " down  " + OmaStore.humanBytes(OmaStore.txBytes) + " up"
          elide: Text.ElideRight
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    // Switching VPNs: the old tunnel comes down first.
    Text {
      objectName: "switchingLine"
      visible: OmaStore.switchingName !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: "Switching to " + OmaStore.switchingName + "…"
    }

    Text {
      objectName: "errorLine"
      visible: OmaStore.phase === "failed" && !OmaStore.askPassword && !root.connecting && OmaStore.message !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: OmaStore.message
    }

    // What actually failed: the tunnel's own last lines, one small click away.
    Button {
      objectName: "failDetailToggle"
      visible: OmaStore.phase === "failed" && !OmaStore.askPassword && !root.connecting && OmaStore.detail !== ""
      width: parent.width
      leftAlign: true
      bordered: true
      fontSize: Style.font.bodySmall
      text: failDetailCard.visible ? "Hide details" : "(see More)"
      onClicked: failDetailCard.visible = !failDetailCard.visible
    }

    Column {
      id: failDetailCard
      objectName: "failDetailCard"
      visible: false
      width: parent.width
      spacing: Style.space(2)

      HintCaption {
        objectName: "failDetailText"
        width: parent.width
        text: OmaStore.detail
      }
    }

    Button {
      objectName: "vpnConnectButton"
      width: parent.width
      bordered: true
      active: OmaStore.phase === "connected"
      verticalPadding: Style.space(8)
      text: OmaStore.phase === "connected" ? "Disconnect"
        : (root.connecting ? "Cancel"
        : "Connect to " + OmaStore.activeProfile)
      onClicked: {
        if (OmaStore.phase === "connected")
          OmaStore.disconnect()
        else if (root.connecting)
          OmaStore.cancel()
        else if (OmaStore.askPassword)
          root.submitPassword()
        else
          OmaStore.connect()
      }
    }

    Button {
      objectName: "passwordCancel"
      width: parent.width
      visible: OmaStore.askPassword
      bordered: true
      verticalPadding: Style.space(8)
      text: "Cancel"
      onClicked: OmaStore.cancel()
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
          text: modelData.name + (String(modelData.portal || "") !== "" ? "\n" + modelData.portal : "")
          fontSize: Style.font.bodySmall
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
      id: editorScroll
      objectName: "editorAdvanced"
      anchors.top: editorHeader.bottom
      anchors.topMargin: Style.space(8)
      width: parent.width
      height: parent.height - editorHeader.implicitHeight - Style.space(8) - Style.space(46)
        - (editorErrorLine.visible ? editorErrorLine.implicitHeight + Style.space(6) : 0)
      clip: true
      contentHeight: editorBody.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      // A plain Flickable ignores mouse wheel events; this makes the editor
      // scroll with the wheel (and lets the harness drive it the same way).
      WheelHandler {
        onWheel: function (event) {
          if (editorScroll.contentHeight <= editorScroll.height) {
            event.accepted = false
            return
          }
          var next = editorScroll.contentY - event.angleDelta.y / 12
          editorScroll.contentY = Math.max(0, Math.min(editorScroll.contentHeight - editorScroll.height, next))
          event.accepted = true
        }
      }

      ScrollBar.vertical: ScrollBar {
        parent: editorScroll.parent
        anchors.top: editorScroll.top
        anchors.bottom: editorScroll.bottom
        anchors.right: editorScroll.right
        anchors.rightMargin: Style.space(1)
        contentItem: Rectangle {
          implicitWidth: Style.space(3)
          radius: width / 2
          color: Commons.Color.muted
          opacity: editorScroll.contentHeight > editorScroll.height ? 0.7 : 0
        }
        background: null
      }

      Column {
        id: editorBody
        width: parent.width - Style.space(10)
        spacing: Style.space(8)
        bottomPadding: Style.space(56)

        Column {
          id: editorTop
          objectName: "editorTop"
          width: parent.width
          spacing: Style.space(8)

          RowCaption { text: "Name" }
          TextField {
            id: editNameField
            objectName: "editorName"
            width: parent.width
            placeholderText: "My VPN"
            onTextChanged: root.edit.name = text
          }

          RowCaption { text: "Portal address" }
          TextField {
            id: editPortalField
            objectName: "editorPortal"
            width: parent.width
            placeholderText: "vpn.example.com"
            onTextChanged: root.edit.portal = text
          }

          RowCaption { text: "Sign in with" }
          ChoiceRow {
            objectName: "editorAuth"
            width: parent.width
            value: root.edit.authMethod || "sso"
            options: [
              { label: "SSO (browser)", value: "sso" },
              { label: "Password", value: "password" }
            ]
            onPicked: function (value) { root.setEdit({ authMethod: value }) }
          }
          HintCaption {
            text: root.edit.authMethod === "password"
              ? "You type the password each time you connect."
              : "A browser-style window signs you in, SSO and two-factor included."
          }

          RowCaption { text: "Username" }
          TextField {
            id: editUserField
            objectName: "editorUsername"
            width: parent.width
            placeholderText: root.edit.authMethod === "password" ? "Needed for password sign-in" : "Usually filled in by signing in"
            onTextChanged: root.edit.username = text
          }

          RowCaption { text: "Where to connect" }
          ChoiceRow {
            objectName: "editorInterface"
            width: parent.width
            value: root.edit.interface || "portal"
            options: [
              { label: "Portal (normal)", value: "portal" },
              { label: "Gateway directly", value: "gateway" }
            ]
            onPicked: function (value) { root.setEdit({ interface: value }) }
          }
          HintCaption {
            text: root.edit.interface === "gateway"
              ? "Skips the portal and signs in to the address above as a gateway. Use this if your VPN provider says so."
              : "The portal picks the gateway for you. This is right for almost everyone."
          }

          RowCaption { text: "Gateway" }
          Button {
            objectName: "gatewayAuto"
            width: parent.width
            bordered: true
            leftAlign: true
            fontSize: Style.font.bodySmall
            text: "Automatic — the VPN picks the best one"
            active: (root.edit.gatewayName || "") === "" && (root.edit.gateway || "") === ""
            onClicked: {
              root.setEdit({ gateway: "", gatewayName: "" })
            }
          }
          Repeater {
            model: root.gatewayModel
            Button {
              required property var modelData
              objectName: "gatewayButton"
              width: parent.width
              bordered: true
              leftAlign: true
              fontSize: Style.font.bodySmall
              text: modelData.name || modelData.host || ""
              active: root.edit.gatewayName === (modelData.name || "")
              onClicked: {
                root.setEdit({ gatewayName: String(modelData.name || ""), gateway: String(modelData.host || "") })
              }
            }
          }
          HintCaption {
            visible: root.gatewayModel.length === 0
            text: "Gateways appear after the first connection."
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
          objectName: "advancedSection"
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
            onPicked: function (value) { root.setEdit({ os: value }) }
          }
          HintCaption { text: "Only change this if your VPN provider says it expects a different system." }

          // --- user agent ---
          RowCaption { text: "Browser identity sent at sign-in" }
          TextField {
            id: editUaField
            objectName: "editorUseragent"
            width: parent.width
            placeholderText: "Default — PAN GlobalProtect"
            onTextChanged: root.edit.useragent = text
          }
          HintCaption { text: "Leave blank unless your VPN provider gives you one." }

          // --- HIP / csd wrapper ---
          RowCaption { text: "Security check script (HIP)" }
          TextField {
            id: editCsdField
            objectName: "editorCsdWrapper"
            width: parent.width
            placeholderText: "/path/to/check/script"
            onTextChanged: root.edit.csdWrapper = text
          }
          HintCaption {
            text: "Some gateways demand a Host Information Policy report. The script must be installed by an admin; it runs as your user. It also needs /proc mounted with hidepid, so other accounts cannot see your VPN cookie. Off unless required."
          }

          // --- servercert pin ---
          RowCaption { text: "Server certificate fingerprint" }
          TextField {
            id: editCertPinField
            objectName: "editorServercert"
            width: parent.width
            placeholderText: "pin-sha256:… or 40 hex characters"
            onTextChanged: root.edit.servercert = text
          }
          HintCaption { text: "Connects only when the VPN shows exactly this certificate." }

          // --- cafile ---
          RowCaption { text: "Custom certificate authority file" }
          TextField {
            id: editCaField
            objectName: "editorCafile"
            width: parent.width
            placeholderText: "/path/to/ca.pem"
            onTextChanged: root.edit.cafile = text
          }
          HintCaption { text: "For VPNs that use their own certificate authority." }

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
          HintCaption { text: "For VPNs that identify you by certificate instead of a password. Both files must be readable by your account." }

          // --- MTU ---
          RowCaption { text: "Tunnel packet size (MTU)" }
          TextField {
            id: editMtuField
            objectName: "editorBaseMtu"
            width: parent.width
            placeholderText: "Default — negotiated automatically"
            onTextChanged: root.edit.baseMtu = text
          }
          HintCaption { text: "Smaller values help on flaky links. Leave blank unless your VPN provider says otherwise." }

          // --- no dtls ---
          RowCaption { text: "Use TLS only" }
          Row {
            width: parent.width
            spacing: Style.space(8)
            ToggleSwitch {
              objectName: "editorNoDtls"
              checked: root.edit.noDtls === true
              onToggled: root.setEdit({ noDtls: root.edit.noDtls !== true })
            }
            HintCaption {
              width: parent.width - Style.space(52)
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
          HintCaption { text: "How long the tunnel keeps trying before giving up after a drop." }

          // --- vpnc script ---
          RowCaption { text: "Custom routing script" }
          TextField {
            id: editVpncField
            objectName: "editorVpncScript"
            width: parent.width
            placeholderText: "/path/to/vpnc-script"
            onTextChanged: root.edit.vpncScript = text
          }
          HintCaption { text: "Manages which traffic goes through the VPN. The script must be installed by an admin. Only if you run your own routing rules." }
        }

        PanelSectionHeader {
          visible: OmaStore.editorName !== ""
          text: "Manage"
        }

        Button {
          objectName: "editorDefault"
          // While a tunnel is up, the selected VPN is the one the card describes.
          visible: root.canSetDefault
          width: parent.width
          bordered: true
          leftAlign: true
          fontSize: Style.font.bodySmall
          text: OmaStore.editorName === OmaStore.activeProfile ? "This is your default VPN" : "Set as default"
          active: OmaStore.editorName !== "" && OmaStore.editorName === OmaStore.activeProfile
          onClicked: {
            if (OmaStore.editorName !== "")
              OmaStore.chooseProfile(OmaStore.editorName)
          }
        }
        HintCaption {
          visible: root.canSetDefault
          text: "The default VPN is the one selected when the bar starts, and the one auto-connect uses."
        }

        Button {
          objectName: "editorForget"
          visible: OmaStore.editorName !== ""
          width: parent.width
          bordered: true
          leftAlign: true
          fontSize: Style.font.bodySmall
          text: OmaStore.forgotName !== "" && OmaStore.forgotName === OmaStore.editorName
            ? "Saved sign-in forgotten" : "Forget saved sign-in"
          onClicked: OmaStore.forgetSignIn(OmaStore.editorName)
        }
        HintCaption {
          visible: OmaStore.editorName !== ""
          text: "Deletes the remembered sign-in on this computer. The next connect asks you to sign in again."
        }

        Button {
          objectName: "editorRemove"
          visible: OmaStore.editorName !== "" && !root.removeArmed
          width: parent.width
          bordered: true
          fontSize: Style.font.bodySmall
          text: "Remove this VPN"
          onClicked: root.removeArmed = true
        }

        Column {
          objectName: "removeConfirm"
          visible: root.removeArmed
          width: parent.width
          spacing: Style.space(4)

          RowCaption { text: "Really remove " + OmaStore.editorName + "?" }

          Row {
            width: parent.width
            spacing: Style.space(6)
            Button {
              objectName: "removeYes"
              width: (parent.width - Style.space(6)) / 2
              bordered: true
              fontSize: Style.font.bodySmall
              text: "Remove"
              onClicked: {
                root.removeArmed = false
                OmaStore.removeProfile(OmaStore.editorName)
              }
            }
            Button {
              objectName: "removeNo"
              width: (parent.width - Style.space(6)) / 2
              bordered: true
              fontSize: Style.font.bodySmall
              text: "Keep it"
              onClicked: root.removeArmed = false
            }
          }
        }
      }
    }

    Text {
      id: editorErrorLine
      objectName: "editorError"
      visible: OmaStore.editorError !== ""
      anchors.bottom: editorFooter.top
      anchors.bottomMargin: Style.space(6)
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: OmaStore.editorError
    }

    // Pinned actions: always visible regardless of scroll position.
    Row {
      id: editorFooter
      objectName: "editorFooter"
      anchors.bottom: parent.bottom
      width: parent.width
      spacing: Style.space(6)
      Button {
        objectName: "editorSave"
        width: (parent.width - Style.space(6)) / 2
        bordered: true
        active: true
        verticalPadding: Style.space(6)
        text: "Save"
        onClicked: root.saveEdit()
      }
      Button {
        objectName: "editorBack"
        width: (parent.width - Style.space(6)) / 2
        bordered: true
        verticalPadding: Style.space(6)
        text: "Back"
        onClicked: OmaStore.closeEditor()
      }
    }
  }
}
