// SPDX-License-Identifier: MIT
import QtQuick
import QtQuick.Controls
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

  // Body text. Explanations read as normal foreground; only titles and
  // state words take accent, so nothing looks like an error by default.
  component RowCaption: Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  // The shell's popups color secondary text as the normal foreground at
  // reduced opacity (network Panel.qml InfoLabel); follow that exactly.
  component HintCaption: Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: Color.foreground
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
    property bool connected: false
    property bool failed: false
    property int connectStep: 0 // 1 sign-in, 2 gateway, 3 tunnel

    // One shield glyph (the font has exactly one); state is carried by
    // color and weight of the dimming instead of a separate outline cut.
    readonly property string iconGlyph: "\u{f132}"
    readonly property color iconColor: connected ? Color.accent
      : (failed ? Color.urgent : Color.foreground)
    readonly property real iconOpacity: connected ? 1.0
      : (failed ? 0.9 : 0.55)

    Item {
      id: visual
      width: Style.space(72)
      height: Style.space(72)
      anchors.horizontalCenter: parent.horizontalCenter
      opacity: hero.failed ? 0.75 : 1
      Behavior on opacity {
        NumberAnimation { duration: Style.duration(300) }
      }

      Text {
        anchors.centerIn: parent
        text: hero.iconGlyph
        textFormat: Text.PlainText
        font.family: Style.font.family
        font.pixelSize: Style.font.display * 1.6
        renderType: Text.NativeRendering
        color: hero.iconColor
        opacity: hero.iconOpacity
      }

      // Connected: one soft ring expanding out of the shield.
      Rectangle {
        anchors.centerIn: parent
        width: Style.space(64)
        height: width
        radius: width / 2
        color: "transparent"
        border.color: Color.accent
        border.width: 2
        opacity: connected && progress < 1 ? 0.6 * (1 - progress) : 0
        scale: 0.6 + 0.9 * progress
        property real progress: 1
        NumberAnimation on progress {
          from: 0
          to: 1
          duration: Style.duration(650)
          running: hero.connected && !Style.reduceMotion
        }
      }

      // Connecting: three dots orbiting the shield.
      Repeater {
        model: hero.connecting && !Style.reduceMotion ? 3 : 0
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
          RotationAnimation on rotation {
            running: hero.connecting && !Style.reduceMotion
            loops: Animation.Infinite
            from: 0
            to: 360
            duration: 1600
          }
        }
      }
    }

    Text {
      id: stateLine
      objectName: "heroState"
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      color: hero.connected ? Color.accent : (hero.failed ? Color.urgent : Color.foreground)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: hero.stateWord
    }

    Text {
      id: whoLine
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: hero.who !== ""
      textFormat: Text.PlainText
      color: Color.foreground
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
      color: Color.accent
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
      color: Color.foreground
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
        why: "Logs you in with your company account",
        ready: present["webkit2gtk-4.1"] === true && present["gp-saml-gui"] === true
      },
      {
        label: "Background service",
        why: "Starts and stops the tunnel from the bar",
        ready: present["gp-vpn.socket"] === true
      }
    ]
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
  readonly property int connectStep: {
    if (OmaStore.phase === "auth")
      return 1
    if (OmaStore.phase === "connecting")
      return (OmaStore.gateways || []).length === 0 ? 2 : 3
    return 0
  }
  // Each connecting step explains itself.
  readonly property string stepHint: {
    if (OmaStore.phase === "auth")
      return "A sign-in window opens the first time. Keep it open until it finishes."
    if (OmaStore.phase === "connecting")
      return "The VPN picks the best gateway and brings the tunnel up."
    return ""
  }

  // ---- Editor state -----------------------------------------------------

  // The harness (and any future caller) scrolls the editor by setting this;
  // the assignment happens here in QML rather than being poked from outside.
  property real editorScrollTo: 0
  onEditorScrollToChanged: editorScroll.contentY = Math.max(0,
    Math.min(editorScroll.contentHeight - editorScroll.height, editorScrollTo))

  property var edit: ({})
  property bool advancedOpen: false
  property bool askPassword: false
  property bool removeArmed: false

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
      // Bring the confirm row above the pinned footer into view.
      editorScrollTo = 999999
    }
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
      stateWord: "Set up OmaGlobal"
      who: ""
    }

    RowCaption {
      text: "A company VPN you can run from this bar. One install step needs your password, then connecting is a single click."
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
            color: modelData.ready ? Color.accent : Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Column {
            width: parent.width - Style.space(20)
            spacing: Style.space(1)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              text: modelData.label + (modelData.ready ? " — ready" : " — will be added")
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
      text: "Install"
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
      failed: true
      who: ""
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.urgent
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
      who: "Company VPN"
    }

    RowCaption {
      text: "This connects you to your company's GlobalProtect VPN. Type the portal address below, press Connect, and sign in when the window appears."
    }

    HintCaption {
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

        HintCaption {
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

    StateHero {
      stateWord: root.askPassword ? "Sign in to " + OmaStore.activeProfile
        : (OmaStore.phase === "connected" ? "Connected"
        : (OmaStore.phase === "failed" ? (OmaStore.rawState === "dropped" ? "Dropped" : "Failed")
        : (root.connecting ? "Connecting" : "Disconnected")))
      who: root.askPassword ? "" : OmaStore.activeProfile
      connecting: root.connecting
      connected: OmaStore.phase === "connected" && !root.askPassword
      failed: OmaStore.phase === "failed" && !root.askPassword
      connectStep: root.connectStep
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
        text: "Expires  " + OmaStore.expiresText()
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

    // Switching VPNs: the old tunnel comes down first.
    Text {
      objectName: "switchingLine"
      visible: OmaStore.switchingName !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      text: "Switching to " + OmaStore.switchingName + "…"
    }

    Text {
      objectName: "errorLine"
      visible: OmaStore.phase === "failed" && !root.askPassword && OmaStore.message !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: OmaStore.message
    }

    HintCaption {
      objectName: "errorAdvice"
      visible: OmaStore.phase === "failed" && !root.askPassword && OmaStore.message !== ""
      text: "Once the problem is fixed, press the button below to try again."
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
          color: Color.muted
          opacity: editorScroll.contentHeight > editorScroll.height ? 0.7 : 0
        }
        background: null
      }

      Column {
        id: editorBody
        width: parent.width - Style.space(10)
        spacing: Style.space(8)
        bottomPadding: Style.space(14)

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
            placeholderText: "Work VPN"
            onTextChanged: root.edit.name = text
          }

          RowCaption { text: "Portal address" }
          TextField {
            id: editPortalField
            objectName: "editorPortal"
            width: parent.width
            placeholderText: "vpn.yourcompany.com"
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
            onPicked: function (value) { root.edit.authMethod = value }
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
            placeholderText: "Usually filled in by signing in"
            onTextChanged: root.edit.username = text
          }

          RowCaption { text: "Where to connect" }
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
            onPicked: function (value) { root.edit.os = value }
          }
          HintCaption { text: "Only change this if IT says the VPN expects a different system." }

          // --- user agent ---
          RowCaption { text: "Browser identity sent at sign-in" }
          TextField {
            id: editUaField
            objectName: "editorUseragent"
            width: parent.width
            placeholderText: "Default — PAN GlobalProtect"
            onTextChanged: root.edit.useragent = text
          }
          HintCaption { text: "Leave blank unless IT gives you a specific one." }

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
            text: "Some gateways demand a Host Information Policy report. The script must be installed by an admin; it runs as your user. Off unless required."
          }

          // --- servercert pin ---
          RowCaption { text: "Server certificate fingerprint" }
          TextField {
            id: editCertPinField
            objectName: "editorServercert"
            width: parent.width
            placeholderText: "40 hex characters"
            onTextChanged: root.edit.servercert = text
          }
          HintCaption { text: "Connects only when the VPN shows exactly this certificate." }

          // --- cafile ---
          RowCaption { text: "Custom certificate authority file" }
          TextField {
            id: editCaField
            objectName: "editorCafile"
            width: parent.width
            placeholderText: "/path/to/company-ca.pem"
            onTextChanged: root.edit.cafile = text
          }
          HintCaption { text: "For VPNs that use a company-issued certificate authority." }

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
          HintCaption { text: "Smaller values help on flaky links. Leave blank unless IT says otherwise." }

          // --- no dtls ---
          RowCaption { text: "Use TLS only" }
          Row {
            width: parent.width
            spacing: Style.space(8)
            ToggleSwitch {
              objectName: "editorNoDtls"
              checked: root.edit.noDtls === true
              onToggled: root.edit.noDtls = !root.edit.noDtls
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

        PanelSectionHeader { text: "Manage" }

        Button {
          objectName: "editorDefault"
          visible: OmaStore.editorName !== ""
          width: parent.width
          bordered: true
          leftAlign: true
          fontSize: Style.font.bodySmall
          text: "Set as default"
          active: OmaStore.editorName !== "" && OmaStore.editorName === OmaStore.activeProfile
          onClicked: {
            if (OmaStore.editorName !== "")
              OmaStore.chooseProfile(OmaStore.editorName)
          }
        }
        HintCaption {
          visible: OmaStore.editorName !== ""
          text: "The default VPN connects at login (with auto-connect on) and keeps the accent color."
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

    // Pinned actions: always visible regardless of scroll position.
    Row {
      id: editorFooter
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
