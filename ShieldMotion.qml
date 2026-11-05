// SPDX-License-Identifier: MIT
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "."
import "shieldColors.js" as ShieldColors

// One timeline for every shield on every monitor, so the bar and the dropdown
// move as one. A view only renders these values; a dropdown opened partway
// through a transition joins it instead of restarting it.
//
// Every value is animated from wherever it is now, so a change of mood midway
// flows on from that exact frame. Nothing here runs at rest.
Singleton {
  id: motion

  // ready: nothing to report, inviting input. off: a VPN is chosen and down.
  readonly property string mood: {
    var screen = OmaStore.screen
    if (OmaStore.askPassword)
      return "ready"
    if (screen === "installing")
      return "busy"
    if (screen === "installFailed")
      return "fail"
    if (OmaStore.attempting)
      return "busy"
    if (OmaStore.phase === "connected")
      return "on"
    if (OmaStore.phase === "failed")
      return "fail"
    return screen === "main" || screen === "editor" ? "off" : "ready"
  }

  readonly property color quietTint: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.6)
  // The shell has no success color (bar.active defaults to urgent), so these
  // come from the theme's palette, followed live when the theme changes.
  property var palette: []
  readonly property color okTint: ShieldColors.pick(palette, 140, 50, Color.accent)
  readonly property color busyTint: ShieldColors.pick(palette, 38, 26, Color.accent)
  readonly property color failTint: ShieldColors.pick(palette, 0, 25, Color.urgent)

  property color tint: quietTint // Shield, state word and bar text all follow this.
  property real fill: 0 // Solid body, growing from the center.
  property real check: 0 // Tick drawn across the solid body.
  property real cross: 0 // X drawn inside the outline.
  property real busy: 0 // Fades the tracing line in and out.
  property real kick: 0 // Sideways shake on a failure, in shield units.
  property real pop: 1 // Scale punch on arrival.
  property real ring: 1 // Expanding outline; 1 is finished and hidden.
  property real trace: 0 // Tracing line position, 0 to 1 around the outline.
  property real breath: 0 // Inner glow while busy.

  readonly property var settleCurve: Style.easeOut // The shell's own landing curve.
  readonly property var flowCurve: [0.65, 0, 0.35, 1, 1, 1] // Even ease for a change of color.

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: motion.palette = ShieldColors.palette(text())
    onFileChanged: reload()
  }

  // A theme swap repoints a directory, which a file watch does not see.
  Connections {
    target: Color
    function onAccentChanged() { themeColors.reload() }
    function onForegroundChanged() { themeColors.reload() }
  }

  onMoodChanged: {
    if (mood === "on" || mood === "fail")
      arrival.restart()
    if (mood === "fail")
      shake.restart()
  }

  StateGroup {
    state: motion.mood
    states: [
      State {
        name: "ready"
        PropertyChanges { target: motion; tint: Color.accent }
      },
      State {
        name: "off"
      },
      State {
        name: "busy"
        PropertyChanges { target: motion; tint: motion.busyTint; busy: 1 }
      },
      State {
        name: "on"
        PropertyChanges { target: motion; tint: motion.okTint; fill: 1; check: 1 }
      },
      State {
        name: "fail"
        PropertyChanges { target: motion; tint: motion.failTint; cross: 1 }
      }
    ]
    transitions: [
      Transition {
        to: "on"
        SequentialAnimation {
          ParallelAnimation {
            ColorAnimation { target: motion; property: "tint"; duration: Style.duration(420); easing.type: Easing.Bezier; easing.bezierCurve: motion.flowCurve }
            NumberAnimation { target: motion; property: "fill"; duration: Style.duration(460); easing.type: Easing.Bezier; easing.bezierCurve: motion.settleCurve }
            NumberAnimation { target: motion; property: "busy"; duration: Style.duration(240) }
            NumberAnimation { target: motion; property: "cross"; duration: Style.duration(160) }
          }
          NumberAnimation { target: motion; property: "check"; duration: Style.duration(300); easing.type: Easing.Bezier; easing.bezierCurve: motion.settleCurve }
        }
      },
      Transition {
        to: "fail"
        ParallelAnimation {
          ColorAnimation { target: motion; property: "tint"; duration: Style.duration(300); easing.type: Easing.Bezier; easing.bezierCurve: motion.flowCurve }
          NumberAnimation { target: motion; property: "fill"; duration: Style.duration(260); easing.type: Easing.Bezier; easing.bezierCurve: motion.flowCurve }
          NumberAnimation { target: motion; property: "check"; duration: Style.duration(120) }
          NumberAnimation { target: motion; property: "busy"; duration: Style.duration(220) }
          NumberAnimation { target: motion; property: "cross"; duration: Style.duration(380); easing.type: Easing.Bezier; easing.bezierCurve: motion.settleCurve }
        }
      },
      Transition {
        // Back to rest: the mark lifts off first, then the body drains away.
        SequentialAnimation {
          ParallelAnimation {
            NumberAnimation { target: motion; property: "check"; duration: Style.duration(160) }
            NumberAnimation { target: motion; property: "cross"; duration: Style.duration(160) }
          }
          ParallelAnimation {
            NumberAnimation { target: motion; property: "fill"; duration: Style.duration(420); easing.type: Easing.Bezier; easing.bezierCurve: motion.flowCurve }
            ColorAnimation { target: motion; property: "tint"; duration: Style.duration(420); easing.type: Easing.Bezier; easing.bezierCurve: motion.flowCurve }
            NumberAnimation { target: motion; property: "busy"; duration: Style.duration(320) }
          }
        }
      }
    ]
  }

  // The tracing line. Runs only while it can be seen.
  NumberAnimation {
    target: motion
    property: "trace"
    from: 0
    to: 1
    duration: 1500
    loops: Animation.Infinite
    running: motion.busy > 0 && !Style.reduceMotion
  }

  SequentialAnimation {
    loops: Animation.Infinite
    running: motion.busy > 0 && !Style.reduceMotion
    NumberAnimation { target: motion; property: "breath"; from: 0; to: 1; duration: 750; easing.type: Easing.InOutSine }
    NumberAnimation { target: motion; property: "breath"; from: 1; to: 0; duration: 750; easing.type: Easing.InOutSine }
  }

  ParallelAnimation {
    id: arrival
    SequentialAnimation {
      NumberAnimation { target: motion; property: "pop"; to: 1.08; duration: Style.duration(150); easing.type: Easing.OutQuad }
      NumberAnimation { target: motion; property: "pop"; to: 1; duration: Style.duration(380); easing.type: Easing.Bezier; easing.bezierCurve: motion.settleCurve }
    }
    NumberAnimation { target: motion; property: "ring"; from: 0; to: 1; duration: Style.duration(720); easing.type: Easing.OutCubic }
  }

  // A short, decaying head shake.
  SequentialAnimation {
    id: shake
    NumberAnimation { target: motion; property: "kick"; to: -7; duration: Style.duration(60); easing.type: Easing.OutQuad }
    NumberAnimation { target: motion; property: "kick"; to: 6; duration: Style.duration(90); easing.type: Easing.InOutQuad }
    NumberAnimation { target: motion; property: "kick"; to: -3; duration: Style.duration(80); easing.type: Easing.InOutQuad }
    NumberAnimation { target: motion; property: "kick"; to: 0; duration: Style.duration(90); easing.type: Easing.OutQuad }
  }
}
