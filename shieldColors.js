// SPDX-License-Identifier: MIT
.pragma library

// Themes number their palette freely, so color2 can be red. Pick by what a
// color is: its hue, among the ones vivid enough to read as a signal.
function hsl(hex) {
  var value = parseInt(String(hex).replace("#", ""), 16)
  var r = (value >> 16 & 255) / 255
  var g = (value >> 8 & 255) / 255
  var b = (value & 255) / 255
  var max = Math.max(r, g, b)
  var min = Math.min(r, g, b)
  var delta = max - min
  var light = (max + min) / 2
  if (delta === 0)
    return { hue: 0, sat: 0, light: light }
  var sat = delta / (1 - Math.abs(2 * light - 1))
  var hue = max === r ? ((g - b) / delta + 6) % 6
    : max === g ? (b - r) / delta + 2
    : (r - g) / delta + 4
  return { hue: hue * 60, sat: sat, light: light }
}

function pick(palette, hue, tolerance, fallback) {
  var best = fallback
  var bestGap = tolerance
  for (var i = 0; i < palette.length; i++) {
    var color = hsl(palette[i])
    if (color.sat < 0.35 || color.light < 0.3 || color.light > 0.85)
      continue
    var gap = Math.abs(color.hue - hue)
    gap = Math.min(gap, 360 - gap)
    if (gap < bestGap) {
      bestGap = gap
      best = palette[i]
    }
  }
  return best
}

// "accent = "#BE3F50"" lines from a theme's colors.toml.
function palette(text) {
  var found = []
  var pattern = /^\s*(?:color\d+|accent|red|green|yellow|orange)\s*=\s*["']?(#[0-9A-Fa-f]{6})/gm
  var match
  while ((match = pattern.exec(String(text || ""))) !== null)
    found.push(match[1])
  return found
}
