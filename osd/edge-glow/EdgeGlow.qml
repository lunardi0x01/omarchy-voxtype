import QtQuick
import Quickshell
import Quickshell.Io

// My Voxtype "Edge glow" OSD style. Loaded by Voxtype's Quickshell OSD host
// into a full-screen, click-through overlay on the focused output. The host
// sets daemonState, audio and theme, and fades the whole item in and out.
//
// A soft mist rises from the bottom of the focused window: along the bottom
// edge and a little way up the left and right edges, brightest in the two
// bottom corners, filling the bottom 15% of the window. The zone has a fixed
// height pinned to the window's bottom edge; your voice only changes its
// brightness. While transcribing it dims and a highlight sweeps along the
// bottom edge. With no focused window on this output it uses the screen.
//
// The mist is painted once per geometry/theme change on a Canvas (one smooth
// two-axis gradient, no strips), so voice updates cost only an opacity change.
// The window comes from `hyprctl -j activewindow`, polled while visible;
// Hyprland reports logical (scaled) coordinates, which is what QML uses.
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

  // Focused window in this item's coordinates; `known` false = use the screen.
  property bool known: false
  property real winX: 0
  property real winY: 0
  property real winW: 0
  property real winH: 0
  readonly property real gx: known ? winX : 0
  readonly property real gy: known ? winY : 0
  readonly property real gw: known ? winW : width
  readonly property real gh: known ? winH : height

  readonly property bool transcribing: daemonState === "transcribing"
  readonly property color accent: { _themeRev; return color("accent", "#7aa2f7") }
  // A light, slightly washed-out tint of the accent reads as mist.
  readonly property color mist: Qt.tint(Qt.lighter(accent, 1.25), Qt.rgba(1, 1, 1, 0.25))
  property real drop: 2
  // A U shape: the sides climb about 40% of the window, the bottom band
  // about 12%; the sides are narrow.
  readonly property real zoneHeight: Math.round(Math.max(120, Math.min(gh * 0.4, 560)))
  readonly property real bandHeight: Math.round(Math.max(50, Math.min(gh * 0.12, 170)))
  readonly property real sideDepth: Math.round(Math.max(22, Math.min(gw * 0.035, 60)))
  // Movement with the voice, done on the GPU (no repaint): the U rises a
  // little (stretching up from the bottom edge, which stays put) and
  // brightens. Quiet: 60% of its height at 45% brightness; loud: full.
  readonly property real rise: transcribing ? 0.8 : 0.6 + 0.4 * level
  readonly property real brightness: transcribing ? 0.6 : 0.45 + 0.55 * level
  readonly property string screenName: {
    var w = root.QsWindow.window
    return w && w.screen ? String(w.screen.name || "") : ""
  }

  function color(role, fallback) {
    return theme && theme.color ? theme.color(role, fallback) : fallback
  }
  function rgba(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
      + Math.round(c.b * 255) + "," + a + ")"
  }

  // `hyprctl -j activewindow`, a separator line, then `hyprctl -j monitors`.
  function applyGeometry(text) {
    var parts = String(text || "").split("\n--MONITORS--\n")
    var win = null, mons = []
    try { win = JSON.parse(parts[0]) } catch (e) { win = null }
    try { mons = JSON.parse(parts[1] || "[]") } catch (e2) { mons = [] }
    if (!win || !win.at || !win.size || win.size[0] <= 0) { known = false; return }
    var mon = null
    for (var i = 0; i < mons.length; i++) if (mons[i].id === win.monitor) mon = mons[i]
    if (!mon || (screenName !== "" && mon.name !== screenName)) { known = false; return }
    winX = win.at[0] - mon.x
    winY = win.at[1] - mon.y
    winW = win.size[0]
    winH = win.size[1]
    known = true
  }

  Process {
    id: geometry
    command: ["sh", "-c", "hyprctl -j activewindow; printf '\\n--MONITORS--\\n'; hyprctl -j monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyGeometry(text)
    }
  }
  Timer {
    interval: 120
    repeat: true
    triggeredOnStart: true
    running: root.visible && root.daemonState !== "idle"
    onTriggered: if (!geometry.running) geometry.running = true
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
      root.target = Math.max(0, Math.min(1, frameRms * 6.0 + framePeak * 0.7))
    }
  }

  // Smooth the voice level gently: rise over ~100 ms, fall over ~500 ms.
  Timer {
    interval: 16
    repeat: true
    running: root.visible
    onTriggered: {
      var k = root.target > root.level ? 0.16 : 0.04
      root.level += (root.target - root.level) * k
      root.target *= 0.94
      root.phase = (root.phase + 0.012) % 1.0
    }
  }

  // The glow zone: a fixed-height area pinned to the window's bottom edge.
  Item {
    id: zone
    x: Math.round(root.gx)
    // Down by `drop` so the glow also covers Hyprland's window border, which
    // is drawn just outside the window's reported area (border_size = 2).
    y: Math.round(root.gy + root.gh - height + root.drop)
    width: Math.round(root.gw)
    height: Math.min(root.zoneHeight, Math.round(root.gh))
    clip: true

    Canvas {
      id: mistCanvas
      anchors.fill: parent
      opacity: root.brightness
      transform: Scale {
        origin.x: 0
        origin.y: mistCanvas.height
        yScale: root.rise
      }
      // Repaint only when the shape or colour changes.
      property string key: width + "x" + height + ":" + root.sideDepth + ":" + root.bandHeight + ":" + root.mist
      onKeyChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        var w = width, h = height, d = Math.min(root.sideDepth, w / 2)
        ctx.reset()
        if (w <= 0 || h <= 0) return
        ctx.globalCompositeOperation = "source-over"
        // 1. The sides: narrow, brightest at the edge, fading inwards...
        var left = ctx.createLinearGradient(0, 0, d, 0)
        left.addColorStop(0, root.rgba(root.mist, 0.9))
        left.addColorStop(0.45, root.rgba(root.mist, 0.35))
        left.addColorStop(1, root.rgba(root.mist, 0))
        ctx.fillStyle = left
        ctx.fillRect(0, 0, d, h)
        var right = ctx.createLinearGradient(w - d, 0, w, 0)
        right.addColorStop(0, root.rgba(root.mist, 0))
        right.addColorStop(0.55, root.rgba(root.mist, 0.35))
        right.addColorStop(1, root.rgba(root.mist, 0.9))
        ctx.fillStyle = right
        ctx.fillRect(w - d, 0, d, h)
        // ...and fading out upwards over the full height (eased).
        ctx.globalCompositeOperation = "destination-in"
        var up = ctx.createLinearGradient(0, 0, 0, h)
        up.addColorStop(0.0, "rgba(0,0,0,0)")
        up.addColorStop(0.3, "rgba(0,0,0,0.1)")
        up.addColorStop(0.6, "rgba(0,0,0,0.38)")
        up.addColorStop(0.85, "rgba(0,0,0,0.75)")
        up.addColorStop(1.0, "rgba(0,0,0,1)")
        ctx.fillStyle = up
        ctx.fillRect(0, 0, w, h)
        // 2. The bottom band, on top: a shallow wash fading upwards.
        ctx.globalCompositeOperation = "source-over"
        var b = Math.min(root.bandHeight, h)
        var band = ctx.createLinearGradient(0, h - b, 0, h)
        band.addColorStop(0.0, root.rgba(root.mist, 0))
        band.addColorStop(0.45, root.rgba(root.mist, 0.12))
        band.addColorStop(0.8, root.rgba(root.mist, 0.42))
        band.addColorStop(1.0, root.rgba(root.mist, 0.75))
        ctx.fillStyle = band
        ctx.fillRect(0, h - b, w, b)
        ctx.globalCompositeOperation = "source-over"
      }
    }

    // Transcribing: a highlight sweeping along the bottom edge.
    Rectangle {
      visible: root.transcribing
      width: parent.width * 0.3
      height: 3
      y: parent.height - height
      x: -width + (parent.width + width) * root.phase
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Qt.rgba(root.mist.r, root.mist.g, root.mist.b, 0.0) }
        GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.85) }
        GradientStop { position: 1.0; color: Qt.rgba(root.mist.r, root.mist.g, root.mist.b, 0.0) }
      }
    }
  }
}
