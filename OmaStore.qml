// SPDX-License-Identifier: MIT
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// One socket and one state machine for every monitor. The panel is a view.
// Events arrive on the socket; nothing here polls. The only secret the
// daemon knows (the prelogin cookie) never enters this process. Install
// progress arrives through a watched file, not a timer.
Singleton {
  id: root

  readonly property string setupCommand: pluginRoot + "tools/setup.sh"
  property bool installRunning: false
  property bool depsLoaded: false
  property bool ready: false
  property var deps: []
  property string installStatus: ""
  property string installStep: ""
  property string installDetail: ""
  property string installError: ""
  readonly property string installPath: {
    var base = String(Quickshell.env("XDG_STATE_HOME") || "")
    if (base.length === 0)
      base = Quickshell.env("HOME") + "/.local/state"
    return base + "/gp-vpn/install.json"
  }
  readonly property string pluginRoot: {
    var s = String(Qt.resolvedUrl("."))
    if (s.indexOf("file://") === 0)
      s = s.substring(7)
    if (s.charAt(s.length - 1) !== "/")
      s += "/"
    return decodeURIComponent(s)
  }
  readonly property string helper: pluginRoot + "bin/gpvpn"
  readonly property string socketPath: {
    var env = String(Quickshell.env("GPVPN_SOCKET") || "")
    return env.length > 0 ? env : "/run/gp-vpn/ctrl.sock"
  }

  property bool socketUp: false
  property string phase: "off"
  property string rawState: "idle"
  property string ip: ""
  property string gateway: ""
  property string expires: ""
  property string userName: ""
  property string message: ""
  property string statusLine: "Not set up"
  property var profiles: []
  property var gateways: []
  property string activeProfile: "Default"
  property int rxBytes: 0
  property int txBytes: 0
  property string iface: ""
  property int since: 0
  property int nowSec: 0

  property bool autoConnect: false
  property bool notifyConnect: true
  property bool notifyDrop: true
  property bool showIpInBar: false
  property bool showUsername: false
  property bool autoTried: false
  property bool userAskedDisconnect: false
  property bool profilesLoaded: false
  property bool profileSaving: false
  property bool connectAfterSave: false
  property bool keepActive: false
  property bool socketSeen: false
  property int socketRetries: 0
  property bool socketRetrying: false
  property var gatewayQueue: []
  property int notifyConnectCount: 0
  property int notifyDisconnectCount: 0
  property int notifyDropCount: 0
  property bool connectPending: false
  property bool connectHeard: false
  property int connectCode: -1
  property string connectError: ""
  // One-click switching and reconnect: wait for the tunnel to come down,
  // then bring the next one up.
  property bool switchPending: false
  property bool reconnectPending: false
  // Shown while the old tunnel comes down for the next one.
  property string switchingName: ""
  // The per-profile editor. A null name means "add a new VPN".
  property bool editorOpen: false
  property string editorName: ""
  // Advanced fields saved together with a brand-new profile: applied right
  // after the profile exists (they name the profile, too).
  property var pendingPairs: []

  // Which card the dropdown shows. Derived only; the views read this.
  readonly property string screen: {
    if (!depsLoaded)
      return "checking"
    if (!ready) {
      if (installStatus === "failed" && !installRunning)
        return "installFailed"
      if (installRunning || installStatus === "running")
        return "installing"
      return "setup"
    }
    if (editorOpen)
      return "editor"
    if (profiles.length === 0)
      return "welcome"
    return "main"
  }

  // Connecting animation caption. Empty means nothing is in flight.
  // procRunning guards the startup order: this binding can evaluate before
  // the Process children exist.
  function procRunning() {
    return connectProc !== null && connectProc.running === true
  }
  readonly property string stepText: {
    if (phase === "auth")
      return "Signing in"
    if (phase === "connecting")
      return "Starting tunnel"
    if (procRunning() && phase === "off")
      return "Opening sign-in"
    return ""
  }

  function redact(value) {
    return String(value || "").replace(/[A-Za-z0-9+/=]{40,}/g, "[redacted]")
  }

  function humanDuration(totalSeconds) {
    // Grows to the largest sensible unit so nothing ever gets truncated.
    var n = Math.max(0, Number(totalSeconds) || 0)
    if (n < 60)
      return n + " s"
    if (n < 3600)
      return Math.floor(n / 60) + " min"
    if (n < 86400) {
      var hours = Math.floor(n / 3600)
      var minutes = Math.floor((n % 3600) / 60)
      return minutes > 0 ? hours + " h " + minutes + " m" : hours + " h"
    }
    if (n < 86400 * 365)
      return Math.floor(n / 86400) + " days"
    return Math.round(n / (86400 * 365) * 10) / 10 + " years"
  }

  function expiresText() {
    var raw = String(expires || "")
    if (!raw)
      return ""
    var stamp = new Date(raw)
    if (isNaN(stamp.getTime()))
      return raw
    var seconds = Math.floor((stamp.getTime() - Date.now()) / 1000)
    var relative = seconds > 0 ? "in " + humanDuration(seconds) : "already passed"
    return Qt.formatDateTime(stamp, "yyyy-MM-dd HH:mm") + " (" + relative + ")"
  }

  function upFor() {
    if (since <= 0 || phase !== "connected")
      return ""
    return humanDuration(nowSec - since)
  }

  function humanBytes(value) {
    var n = Number(value) || 0
    if (n < 1024)
      return n + " B"
    var units = ["KB", "MB", "GB", "TB"]
    for (var i = 0; i < units.length; i++) {
      n = n / 1024
      if (n < 1024 || i === units.length - 1)
        return (Math.round(n * 10) / 10) + " " + units[i]
    }
    return n + " TB"
  }

  function applySettings(settings) {
    // "Default" here is the widget's unset value, not a saved choice.
    // profiles.json is what the next start connects, once list returns.
    if (!profilesLoaded && !keepActive)
      activeProfile = String(settings.activeProfile || "Default")
    autoConnect = settings.autoConnect === true
    notifyConnect = settings.notifyConnect === true
    notifyDrop = settings.notifyDrop === true
    showIpInBar = settings.showIpInBar === true
    showUsername = settings.showUsername === true
    maybeAutoConnect()
  }

  function maybeAutoConnect() {
    if (!profilesLoaded || !autoConnect || autoTried || !socketUp)
      return
    if (!profiles.length || profileSaving || connectAfterSave || connectProc.running)
      return
    if (phase !== "off" && phase !== "failed")
      return
    autoTried = true
    connect()
  }

  // The portal address doubles as the profile name until the user renames it.
  function portalName(portal) {
    var name = String(portal || "").trim()
    name = name.replace(/^\w+:\/\//, "").split("/")[0].trim()
    return name || "VPN"
  }

  function saveAndConnect(portal, username) {
    var portalText = String(portal || "").trim()
    var userText = String(username || "").trim()
    if (!portalText) {
      fail("Enter your VPN portal address.")
      return
    }
    var name = portalName(portalText)
    if (addProc.running)
      return
    activeProfile = name
    connectAfterSave = true
    profileSaving = true
    addProc.command = [helper, "profile", "add", "--name", name, "--portal", portalText]
    if (userText)
      addProc.command.push("--username", userText)
    addProc.running = true
  }

  function fail(text) {
    phase = "failed"
    rawState = "failed"
    message = redact(String(text || "")).trim()
    refreshStatus()
  }

  function tooltipText() {
    var tip = "OmaGlobal: " + statusLine
    if (phase === "connected" && gateway)
      tip += "\n" + gateway
    if (showIpInBar && phase === "connected" && ip)
      tip += "\n" + ip
    return redact(tip)
  }

  function refreshStatus() {
    if (!socketUp) {
      statusLine = "Not set up"
      return
    }
    if (phase === "auth")
      statusLine = "Waiting for sign-in"
    else if (phase === "connecting")
      statusLine = "Connecting"
    else if (phase === "connected")
      statusLine = "Connected"
    else if (phase === "failed")
      statusLine = message || (rawState === "dropped" ? "Tunnel dropped" : "Connection failed")
    else
      statusLine = "Disconnected"
    statusLine = redact(statusLine)
  }

  function notify(kind) {
    var summary = "VPN disconnected"
    if (kind === "connect") {
      if (!notifyConnect)
        return
      summary = "VPN connected"
      notifyConnectCount += 1
    } else if (kind === "drop") {
      if (!notifyDrop)
        return
      summary = "VPN dropped"
      notifyDropCount += 1
    } else {
      notifyDisconnectCount += 1
    }
    var body = summary
    if (showUsername && userName && kind !== "disconnect")
      body = summary + " (" + redact(userName) + ")"
    body = redact(body)
    summary = redact(summary)
    notifyProc.stdinEnabled = true
    notifyProc.running = true
    notifyProc.write(JSON.stringify({ summary: summary, body: body }) + "\n")
    notifyProc.stdinEnabled = false
  }

  function ingest(line) {
    var obj
    try {
      obj = JSON.parse(line)
    } catch (error) {
      return
    }
    if (!obj || !obj.type)
      return
    if (obj.type === "log")
      return
    if (obj.type === "error") {
      message = redact(obj.message || "")
      refreshStatus()
      return
    }
    if (obj.type !== "state" && obj.type !== "accepted")
      return
    // This attempt already has a daemon phase. Do not replace it with helper stderr.
    if (connectPending)
      connectHeard = true
    var next = String(obj.state || "idle")
    var visual = "off"
    if (next === "auth")
      visual = "auth"
    else if (next === "connecting")
      visual = "connecting"
    else if (next === "connected")
      visual = "connected"
    else if (next === "failed" || next === "dropped")
      visual = "failed"
    var prev = phase
    phase = visual
    rawState = next
    if (visual !== "connected") {
      since = 0
      rxBytes = 0
      txBytes = 0
      iface = ""
    }
    ip = redact(obj.ip || "")
    gateway = redact(obj.gateway || "")
    expires = redact(obj.expires || "")
    userName = String(obj.user || "")
    message = redact(obj.message || "")
    gateways = obj.gateways || []
    rxBytes = Number(obj.rxBytes) || 0
    txBytes = Number(obj.txBytes) || 0
    iface = String(obj.iface || "")
    if (Number(obj.since) > 0)
      since = Number(obj.since)
    refreshStatus()
    if (visual === "connected" && prev !== "connected")
      notify("connect")
    if (visual === "connected" || visual === "failed")
      switchingName = ""
    if (visual === "off" && prev !== "off") {
      if (userAskedDisconnect) {
        userAskedDisconnect = false
        notify("disconnect")
      }
      if (switchPending) {
        switchPending = false
        connect()
      } else if (reconnectPending) {
        reconnectPending = false
        connect()
      }
    }
    if (visual === "failed" && prev !== "failed" && (prev === "connected" || next === "dropped")) {
      if (switchPending) {
        switchPending = false
        connect()
      } else if (reconnectPending) {
        reconnectPending = false
        connect()
      } else {
        notify("drop")
      }
    }
    if (visual === "connected" && gateways.length > 0)
      cacheGateways()
  }

  function cacheGateways() {
    // Remember the portal's list. Never overwrite a manual gateway override.
    cacheProc.command = [helper, "profile", "set", activeProfile, "gateways", JSON.stringify(gateways)]
    cacheProc.running = true
  }

  function connect() {
    if (phase === "auth" || phase === "connecting" || phase === "connected")
      return
    userAskedDisconnect = false
    connectPending = true
    connectHeard = false
    connectCode = -1
    connectError = ""
    // A new attempt starts with a clean slate: no stale failure text.
    message = ""
    phase = "off"
    rawState = "idle"
    refreshStatus()
    connectProc.running = false
    connectProc.running = true
  }

  function settleConnect() {
    if (!connectPending || connectHeard || connectCode < 0)
      return
    if (connectCode === 0) {
      connectPending = false
      return
    }
    // The helper quit before the daemon spoke. Same failed status as a daemon failure.
    fail(connectError || "Could not start the connection.")
  }

  function disconnect() {
    userAskedDisconnect = true
    switchPending = false
    reconnectPending = false
    sock.write('{"cmd":"disconnect"}\n')
    sock.flush()
  }

  // Take the current tunnel down and bring this profile up. One click.
  function switchTo(name) {
    chooseProfile(name)
    if (phase === "auth" || phase === "connecting" || phase === "connected") {
      userAskedDisconnect = false
      reconnectPending = false
      switchPending = true
      switchingName = String(name || "")
      message = ""
      refreshStatus()
      sock.write('{"cmd":"disconnect"}\n')
      sock.flush()
      return
    }
    connect()
  }

  function reconnect() {
    if (phase === "connected") {
      userAskedDisconnect = false
      switchPending = false
      reconnectPending = true
      sock.write('{"cmd":"disconnect"}\n')
      sock.flush()
      return
    }
    connect()
  }

  function chooseProfile(name) {
    activeProfile = String(name || "Default")
    keepActive = true
    activeProc.running = false
    activeProc.command = [helper, "profile", "set", activeProfile, "active", "yes"]
    activeProc.running = true
  }

  function chooseGateway(name, host) {
    // Empty name and host clear the override and let the portal choose.
    setProfileFields([
      ["gateway", String(host || "")],
      ["gatewayName", String(name || "")]
    ])
  }

  // Queue of [key, value] pairs applied one `profile set` at a time, then
  // the list is reloaded. The queue keeps the single shared Process busy-free.
  function setProfileFields(pairs) {
    gatewayQueue = pairs.map(function (pair) {
      return [helper, "profile", "set", activeProfile, pair[0], String(pair[1])]
    })
    if (!gatewayProc.running)
      runGatewayQueue()
  }

  function runGatewayQueue() {
    if (gatewayProc.running || gatewayQueue.length === 0)
      return
    var next = gatewayQueue[0]
    gatewayQueue = gatewayQueue.slice(1)
    gatewayProc.command = next
    gatewayProc.running = true
  }

  // Editor lifecycle. name === "" means a brand-new VPN.
  function openEditor(name) {
    editorName = String(name || "")
    editorOpen = true
  }

  function closeEditor() {
    editorOpen = false
    editorName = ""
  }

  function saveEditor(fields) {
    // fields: {name, portal, username, authMethod, interface, os, useragent,
    // csdWrapper, servercert, cafile, certificate, sslkey, baseMtu,
    // noDtls, reconnectTimeout, vpncScript}
    var name = String(fields.name || "").trim() || portalName(fields.portal)
    var isNew = editorName === ""
    var target = isNew ? name : editorName
    var pairs = []
    if (isNew) {
      if (addProc.running)
        return
      addProc.command = [helper, "profile", "add", "--name", name, "--portal", String(fields.portal || "").trim()]
      var user = String(fields.username || "").trim()
      if (user)
        addProc.command.push("--username", user)
      addProc.running = true
    } else if (String(fields.name || "").trim() && String(fields.name).trim() !== editorName) {
      pairs.push(["name", String(fields.name).trim()])
    }
    var plain = ["portal", "username", "authMethod", "interface", "os", "useragent",
                 "csdWrapper", "servercert", "cafile", "certificate", "sslkey", "vpncScript"]
    for (var i = 0; i < plain.length; i++) {
      var key = plain[i]
      if (fields[key] === undefined)
        continue
      pairs.push([key, String(fields[key]).trim()])
    }
    if (fields.noDtls !== undefined)
      pairs.push(["noDtls", fields.noDtls === true ? "On" : "Off"])
    if (fields.baseMtu !== undefined && String(fields.baseMtu).trim() !== "")
      pairs.push(["baseMtu", String(parseInt(fields.baseMtu, 10))])
    if (fields.reconnectTimeout !== undefined && String(fields.reconnectTimeout).trim() !== "")
      pairs.push(["reconnectTimeout", String(parseInt(fields.reconnectTimeout, 10))])
    editorOpen = false
    editorName = ""
    if (isNew) {
      // addProc applies the pairs once the profile exists.
      pendingPairs = pairs
      return
    }
    chooseProfile(target)
    setProfileFields(pairs)
  }

  function removeProfile(name) {
    if (removeProc.running)
      return
    editorOpen = false
    editorName = ""
    if (activeProfile === name)
      activeProfile = profiles.length > 1 ? String(profiles[0].name) : "Default"
    removeProc.command = [helper, "profile", "remove", String(name || "")]
    removeProc.running = true
  }

  function forgetSignIn(name) {
    forgetProc.command = [helper, "forget", String(name || activeProfile)]
    forgetProc.running = true
  }

  function scheduleRetry() {
    // A missing socket means setup has not been run. Retry only after this
    // bar has already talked to a daemon, so a restart does not look like
    // a missing install.
    if (!socketSeen || socketRetries >= 8 || retryTimer.running || socketRetrying)
      return
    retryTimer.start()
  }

  function installSetup() {
    // The terminal is where the script asks for a password.
    if (installProc.running)
      return
    installStatus = "running"
    installError = ""
    installProc.command = [
      "xdg-terminal-exec", "--hold",
      "--app-id=io.github.gsottnick.omaglobal",
      "--title=OmaGlobal setup",
      "-e", setupCommand
    ]
    installProc.running = true
  }

  function pokeSocket() {
    socketRetrying = true
    sock.connected = false
    sock.connected = true
    socketRetrying = false
  }

  function refreshDeps() {
    if (!depsProc.running)
      depsProc.running = true
  }

  function applyDeps(text) {
    try {
      var data = JSON.parse(text)
      deps = data.items || []
      ready = data.ready === true
    } catch (error) {
      deps = []
      ready = false
    }
    depsLoaded = true
    if (ready && !socketUp)
      pokeSocket()
  }

  function applyInstall(text) {
    var data
    try {
      data = JSON.parse(String(text || ""))
    } catch (error) {
      return
    }
    if (!data || !data.status)
      return
    installStatus = String(data.status)
    installStep = String(data.step || "")
    installDetail = String(data.detail || "")
    installError = redact(String(data.error || ""))
    if (installStatus === "done") {
      pokeSocket()
      refreshDeps()
    }
  }

  function applyProfiles(text) {
    try {
      var data = JSON.parse(text)
      profiles = data.profiles || []
      if (!keepActive && data.active)
        activeProfile = String(data.active)
    } catch (error) {
      profiles = []
    }
    profilesLoaded = true
    maybeAutoConnect()
  }

  function reloadProfiles() {
    if (!listProc.running)
      listProc.running = true
  }

  Component.onCompleted: {
    reloadProfiles()
    refreshDeps()
  }

  Socket {
    id: sock
    path: root.socketPath
    connected: true
    onConnectedChanged: {
      root.socketUp = connected
      root.refreshStatus()
      if (connected) {
        root.socketSeen = true
        root.socketRetries = 0
        retryTimer.stop()
        write('{"cmd":"status"}\n')
        flush()
        root.maybeAutoConnect()
      }
    }
    onError: function (code) {
      if (root.socketRetrying)
        return
      root.socketUp = false
      root.refreshStatus()
      root.scheduleRetry()
    }
    parser: SplitParser {
      onRead: function (line) { root.ingest(line) }
    }
  }

  // Setup progress. The setup script rewrites this file per step; watching
  // it is event-driven, no timer involved.
  FileView {
    id: installView
    path: root.installPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyInstall(text())
    onFileChanged: root.applyInstall(text())
  }

  // A 1 Hz tick only while connected, so "Up for" stays honest. This is a
  // display clock, not a poll of anything.
  Timer {
    id: clockTimer
    interval: 1000
    repeat: true
    running: root.phase === "connected"
    triggeredOnStart: true
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  Timer {
    id: retryTimer
    interval: 2000
    repeat: false
    onTriggered: {
      root.socketRetries += 1
      root.pokeSocket()
    }
  }

  Process {
    id: listProc
    command: [root.helper, "profile", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProfiles(text)
    }
  }

  Process {
    id: addProc
    stderr: StdioCollector {
      id: addErr
      waitForEnd: true
    }
    onExited: function (code) {
      var start = root.connectAfterSave
      var savedName = root.activeProfile
      if (start) {
        root.profileSaving = false
        root.connectAfterSave = false
      }
      if (code !== 0) {
        root.profileSaving = false
        root.connectAfterSave = false
        root.fail(String(addErr.text || "").trim() || "Could not save that VPN.")
        return
      }
      if (start) {
        // The welcome flow: the profile exists now, sign in.
        root.reloadProfiles()
        root.autoTried = true
        root.connect()
        return
      }
      root.chooseProfile(savedName)
      var pairs = root.pendingPairs
      root.pendingPairs = []
      if (pairs.length > 0)
        root.setProfileFields(pairs)
      else
        root.reloadProfiles()
    }
  }

  Process {
    id: removeProc
    onExited: root.reloadProfiles()
  }

  Process {
    id: forgetProc
    onExited: root.reloadProfiles()
  }

  Process {
    id: connectProc
    command: [root.helper, "connect", "--profile", root.activeProfile]
    stderr: StdioCollector {
      id: connectErr
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "")
        if (next !== "")
          root.connectError = next
        root.settleConnect()
      }
    }
    // Exit is the event. A non-zero exit does not start another connect.
    onExited: function (code) {
      root.connectCode = code
      var live = String(connectErr.text || "")
      if (live !== "")
        root.connectError = live
      root.settleConnect()
      root.reloadProfiles()
    }
    // Password profiles get their secret on stdin, never on the command line.
    onStarted: {
      if (root.activeAuthMethod === "password") {
        write(root.passwordInput + "\n")
        root.passwordInput = ""
      }
      stdinEnabled = false
    }
  }

  // Read from the profile list once it loads; "" means SSO.
  property string passwordInput: ""
  property string activeAuthMethod: ""

  function preparePassword(password) {
    passwordInput = String(password || "")
    connect()
  }

  onProfilesChanged: {
    var entry = null
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i] && profiles[i].name === activeProfile)
        entry = profiles[i]
    }
    activeAuthMethod = String((entry && entry.authMethod) || "sso")
  }
  onActiveProfileChanged: {
    var entry = null
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i] && profiles[i].name === activeProfile)
        entry = profiles[i]
    }
    activeAuthMethod = String((entry && entry.authMethod) || "sso")
  }

  Process {
    id: cacheProc
    command: [root.helper, "profile", "list"]
  }

  Process {
    id: activeProc
    command: [root.helper, "profile", "list"]
  }

  Process {
    id: notifyProc
    command: [root.helper, "notify"]
  }

  Process {
    id: installProc
    onRunningChanged: {
      root.installRunning = running
      if (!running)
        root.pokeSocket()
    }
  }

  Process {
    id: depsProc
    command: [root.helper, "deps"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDeps(text)
    }
  }

  Process {
    id: gatewayProc
    command: [root.helper, "profile", "list"]
    onExited: function (code) {
      if (root.gatewayQueue.length > 0)
        root.runGatewayQueue()
      else {
        listProc.running = false
        listProc.running = true
      }
    }
  }
}
