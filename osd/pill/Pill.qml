import QtQuick

// My Voxtype "Pill" OSD style. Loaded by Voxtype's Quickshell OSD host into a
// full-screen, click-through overlay on the focused output; the pill itself
// sits at the bottom centre.
//
// Recording: nine bars follow your voice, tallest in the middle.
// Transcribing: the bars settle into a slow travelling wave.
Item {
  id: root
  anchors.fill: parent

  property string daemonState: "idle"
  property var audio: null
  property var theme: null
  property var recipe: null
  property var session: null
  property var outcome: null
  property string assetRoot: ""

  property real level: 0.0
  property real target: 0.0
  property real phase: 0.0
  property int _themeRev: 0
  // Recent levels, newest last; bar i shows one of them.
  property var history: [0, 0, 0, 0, 0, 0, 0, 0, 0]

  readonly property bool transcribing: daemonState === "transcribing"
  readonly property color accent: { _themeRev; return color("accent", "#7aa2f7") }
  readonly property color foreground: { _themeRev; return color("foreground", "#c0caf5") }
  readonly property color background: { _themeRev; return color("background", "#1a1b26") }
  readonly property int barCount: 9

  function color(role, fallback) {
    return theme && theme.color ? theme.color(role, fallback) : fallback
  }
  function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Bar heights 0..1. Recording: the newest level in the middle, older ones
  // spreading outwards, shaped so the centre stands tallest.
  function barValue(i) {
    var mid = (barCount - 1) / 2
    var dist = Math.abs(i - mid)
    var shape = 1.0 - dist / (mid + 1.5)
    if (transcribing) {
      var wave = 0.5 + 0.5 * Math.sin((phase * 2 * Math.PI) - i * 0.7)
      return 0.18 + 0.32 * wave * shape
    }
    var h = history[history.length - 1 - Math.round(dist)] || 0
    return Math.max(0.12, Math.min(1, h * shape * 1.25))
  }

  Connections {
    target: root.theme
    ignoreUnknownSignals: true
    function onConfigChanged() { root._themeRev++ }
  }
  Connections {
    target: root.audio
    ignoreUnknownSignals: true
    function onFrameReceived(framePeak, frameRms, vad, tsMs) {
      root.target = Math.max(0, Math.min(1, frameRms * 4.0 + framePeak * 0.6))
    }
  }

  Timer {
    interval: 33
    repeat: true
    running: root.visible
    onTriggered: {
      var k = root.target > root.level ? 0.5 : 0.15
      root.level += (root.target - root.level) * k
      root.target *= 0.9
      var h = root.history.slice(1)
      h.push(root.level)
      root.history = h
      root.phase = (root.phase + 0.02) % 1.0
    }
  }

  Rectangle {
    id: pill
    width: 96
    height: 48
    radius: height / 2
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 28
    color: root.withAlpha(root.background, 0.94)
    border.width: 1.5
    border.color: root.withAlpha(root.accent, root.transcribing ? 0.45 : 0.75)

    Row {
      anchors.centerIn: parent
      spacing: 3
      Repeater {
        model: root.barCount
        delegate: Rectangle {
          required property int index
          readonly property real value: { root.history; root.phase; return root.barValue(index) }
          anchors.verticalCenter: parent.verticalCenter
          width: 3
          height: Math.round(4 + 16 * value)
          radius: width / 2
          color: root.withAlpha(root.foreground, root.transcribing ? 0.55 : 0.9)
          Behavior on height { NumberAnimation { duration: 60 } }
        }
      }
    }
  }
}
