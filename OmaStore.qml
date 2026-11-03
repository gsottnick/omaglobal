// SPDX-License-Identifier: MIT
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// One socket and one state machine for every monitor. The panel is a view.
// Events arrive on the socket; nothing here polls. The only secret the
// daemon knows (the prelogin cookie) never enters this process.
Singleton {
  id: root

  readonly property string setupCommand: "tools/setup.sh"
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

  property bool autoConnect: false
  property bool notifyConnect: true
  property bool notifyDrop: true
  property bool showIpInBar: false
  property bool showUsername: false
  property bool autoTried: false
  property bool userAskedDisconnect: false
  property bool profilesLoaded: false
  property bool keepActive: false
  property bool socketSeen: false
  property int socketRetries: 0
  property bool socketRetrying: false
  property var gatewayQueue: []
  property int notifyConnectCount: 0
  property int notifyDisconnectCount: 0
  property int notifyDropCount: 0

  function redact(value) {
    return String(value || "").replace(/[A-Za-z0-9+/=]{40,}/g, "[redacted]")
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
    if (phase !== "off" && phase !== "failed")
      return
    autoTried = true
    connect()
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
    ip = redact(obj.ip || "")
    gateway = redact(obj.gateway || "")
    expires = redact(obj.expires || "")
    userName = String(obj.user || "")
    message = redact(obj.message || "")
    gateways = obj.gateways || []
    refreshStatus()
    if (visual === "connected" && prev !== "connected")
      notify("connect")
    if (visual === "off" && userAskedDisconnect && prev !== "off") {
      userAskedDisconnect = false
      notify("disconnect")
    }
    if (visual === "failed" && prev !== "failed" && (prev === "connected" || next === "dropped"))
      notify("drop")
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
    connectProc.running = false
    connectProc.running = true
  }

  function disconnect() {
    userAskedDisconnect = true
    sock.write('{"cmd":"disconnect"}\n')
    sock.flush()
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
    gatewayQueue = [
      [helper, "profile", "set", activeProfile, "gateway", String(host || "")],
      [helper, "profile", "set", activeProfile, "gatewayName", String(name || "")]
    ]
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

  function scheduleRetry() {
    // A missing socket means setup has not been run. Retry only after this
    // bar has already talked to a daemon, so a restart does not look like
    // a missing install.
    if (!socketSeen || socketRetries >= 8 || retryTimer.running || socketRetrying)
      return
    retryTimer.start()
  }

  function copySetup() {
    copyProc.stdinEnabled = true
    copyProc.running = true
    copyProc.write(setupCommand)
    copyProc.stdinEnabled = false
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

  Component.onCompleted: reloadProfiles()

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

  Timer {
    id: retryTimer
    interval: 2000
    repeat: false
    onTriggered: {
      root.socketRetries += 1
      root.socketRetrying = true
      sock.connected = false
      sock.connected = true
      root.socketRetrying = false
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
    id: connectProc
    command: [root.helper, "connect", "--profile", root.activeProfile]
    onExited: function (code) { root.reloadProfiles() }
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
    id: copyProc
    command: ["wl-copy"]
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
