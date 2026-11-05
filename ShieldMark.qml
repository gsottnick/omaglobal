// SPDX-License-Identifier: MIT
import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import "."

// The shield, drawn from ShieldMotion. All sizes are in a 100 by 116 box. Moving
// layers only change scale or opacity, which redraws nothing; only the tracing
// line and the two marks touch geometry, and only while they animate.
Item {
  id: mark

  readonly property string mood: ShieldMotion.mood
  property real size: 64
  property bool ripple: true
  // Thin lines need a floor at bar size.
  readonly property real unit: size / 100
  readonly property real line: Math.max(1.3, 5 * unit)
  readonly property real strong: Math.max(1.8, 9 * unit)

  implicitWidth: size
  implicitHeight: size * 1.16

  // Lengths the dash patterns need, measured from the paths below.
  readonly property real outlineLength: 313.8 * unit
  readonly property real checkLength: 60.41 * unit
  readonly property real crossLength: 42.52 * unit
  readonly property string outlinePath: "M 50 4 L 92 18 L 92 56 C 92 84 72 104 50 112 C 28 104 8 84 8 56 L 8 18 Z"

  component Outline: Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    default property alias pathData: path.pathElements
    property alias strokeColor: path.strokeColor
    property alias strokeWidth: path.strokeWidth
    property alias fillColor: path.fillColor
    property alias strokeStyle: path.strokeStyle
    property alias dashPattern: path.dashPattern
    property alias dashOffset: path.dashOffset
    property alias capStyle: path.capStyle
    ShapePath {
      id: path
      strokeColor: "transparent"
      fillColor: "transparent"
      joinStyle: ShapePath.MiterJoin
      capStyle: ShapePath.FlatCap
      scale: Qt.size(mark.unit, mark.unit)
    }
  }

  // Arrival ring: the outline itself, leaving.
  Outline {
    visible: mark.ripple && ShieldMotion.ring < 1
    opacity: (1 - ShieldMotion.ring) * 0.7
    scale: 1 + ShieldMotion.ring * 0.62
    strokeColor: ShieldMotion.tint
    strokeWidth: mark.line
    PathSvg { path: mark.outlinePath }
  }

  Item {
    anchors.fill: parent
    scale: ShieldMotion.pop
    transform: Translate { x: ShieldMotion.kick * mark.unit }

    // Soft inner glow while busy.
    Outline {
      visible: ShieldMotion.busy > 0
      opacity: ShieldMotion.busy * (0.1 + ShieldMotion.breath * 0.22)
      scale: 0.5 + ShieldMotion.breath * 0.16
      fillColor: ShieldMotion.tint
      PathSvg { path: mark.outlinePath }
    }

    // The solid body.
    Outline {
      visible: ShieldMotion.fill > 0.001
      scale: ShieldMotion.fill
      fillColor: ShieldMotion.tint
      PathSvg { path: mark.outlinePath }
    }

    Outline {
      strokeColor: ShieldMotion.tint
      strokeWidth: mark.line
      opacity: 1 - ShieldMotion.busy * 0.72
      PathSvg { path: mark.outlinePath }
    }

    // The tracing line: one bright run around the outline. The pattern's period is
    // the outline's exact length, so the loop has no seam.
    Outline {
      visible: ShieldMotion.busy > 0
      opacity: ShieldMotion.busy
      strokeColor: ShieldMotion.tint
      strokeWidth: mark.line * 1.25
      capStyle: ShapePath.RoundCap
      strokeStyle: ShapePath.DashLine
      dashPattern: [mark.outlineLength * 0.3 / strokeWidth, mark.outlineLength * 0.7 / strokeWidth]
      dashOffset: -ShieldMotion.trace * mark.outlineLength / strokeWidth
      PathSvg { path: mark.outlinePath }
    }

    // The tick, knocked out of the solid body.
    Outline {
      visible: ShieldMotion.check > 0.001
      strokeColor: Commons.Color.background
      strokeWidth: mark.strong
      strokeStyle: ShapePath.DashLine
      dashPattern: [mark.checkLength / strokeWidth, mark.checkLength / strokeWidth]
      dashOffset: mark.checkLength * (1 - ShieldMotion.check) / strokeWidth
      PathSvg { path: "M 31 58 L 45 72 L 70 40" }
    }

    // The X inside the outline, one stroke after the other.
    Outline {
      visible: ShieldMotion.cross > 0.001
      strokeColor: ShieldMotion.tint
      strokeWidth: mark.strong
      strokeStyle: ShapePath.DashLine
      dashPattern: [mark.crossLength / strokeWidth, mark.crossLength / strokeWidth]
      dashOffset: mark.crossLength * (1 - Math.min(1, ShieldMotion.cross * 2)) / strokeWidth
      PathSvg { path: "M 36 42 L 64 74" }
    }
    Outline {
      visible: ShieldMotion.cross > 0.5
      strokeColor: ShieldMotion.tint
      strokeWidth: mark.strong
      strokeStyle: ShapePath.DashLine
      dashPattern: [mark.crossLength / strokeWidth, mark.crossLength / strokeWidth]
      dashOffset: mark.crossLength * (2 - ShieldMotion.cross * 2) / strokeWidth
      PathSvg { path: "M 64 42 L 36 74" }
    }
  }
}
