import QtQuick
import Quickshell
import "Plugin" as Plugin

// Opens the panel against a fake service, walks every section and the
// main actions, and prints PANEL_SMOKE_OK (or the failures).
ShellRoot {
  id: root
  property string failures: ""
  property int phase: 0
  function expect(condition, label) {
    if (!condition) failures += (failures === "" ? "" : ", ") + label
  }

  QtObject {
    id: fake
    property bool statusKnown: true
    property bool daemonActive: true
    property bool autoStartKnown: true
    property bool autoStartEnabled: true
    property string recState: "idle"
    readonly property bool recording: recState === "recording"
    readonly property bool transcribing: recState === "transcribing"
    readonly property bool busy: recording || transcribing
    property real recordingStartedAt: Date.now() - 7000
    property bool serverKnown: true
    property bool serverReachable: true
    property int serverPingMs: 42
    property string serverHost: "gpu-box"
    readonly property bool problem: daemonActive && serverKnown && !serverReachable
    property var terms: ["Omarchy", "Hyprland"]
    property var replacements: ({ "a Marche": "Omarchy" })
    property string language: "en"
    property string indicator: "capsule"
    property bool pauseMedia: true
    property string autoSubmit: "off"
    property int maxDurationSecs: 120
    property int remoteTimeoutSecs: 10
    property bool historyEnabled: true
    property bool escapeCancels: true
    property string holdKey: ""
    property bool hookInstalled: true
    property string postProcessCommand: "/x/post_process.sh"
    property string defaultSourceLabel: "USB Webcam"
    property string defaultSource: "cam"
    property var sources: [{ name: "builtin", description: "Built-in Audio Analog Stereo" }, { name: "cam", description: "USB Webcam Analog Stereo" }]
    property var history: [
      { line: "2026-11-18T20:00:00\tHello there", time: Date.now() - 60000, text: "Hello there", words: 2 },
      { line: "2026-11-18T19:00:00\tSecond one here", time: Date.now() - 3600000, text: "Second one here", words: 3 }
    ]
    readonly property var lastEntry: history.length ? history[0] : null
    property var stats: ({ wordsToday: 5, wordsWeek: 5, wordsAll: 5, dictations: 2, wpm: 120, medianLatencyMs: 150, timed: 2 })
    property string error: ""
    property string actionMessage: ""
    property string tooltipText: "Voxtype: Ready"
    property int refreshCount: 0
    property int toggles: 0
    property var calls: []
    signal openPanelRequested()
    function log(name) { var c = calls; c.push(name); calls = c }
    function refresh() { refreshCount++ }
    function refreshHistory() { log("refreshHistory") }
    function toggleDaemon() { toggles++; return true }
    function setAutoStart(v) { log("autostart:" + v) }
    function cycleSource(s) { log("source:" + s) }
    function setDefaultSource(n) { log("setSource:" + n) }
    function setLanguage(c) { log("setLanguage:" + c) }
    function setIndicator(i) { log("setIndicator:" + i) }
    function setMaxDuration(n) { log("setMax:" + n) }
    function setRemoteTimeout(n) { log("setTimeout:" + n) }
    function cycleLanguage(s) { log("language:" + s) }
    function cycleIndicator(s) { log("indicator:" + s) }
    function cycleMaxDuration(s) { log("max:" + s) }
    function cycleTimeout(s) { log("timeout:" + s) }
    function copyText(t) { log("copy:" + t) }
    function removeTerm(t) { log("removeTerm:" + t) }
    function addTerm(t) { log("addTerm:" + t); return true }
    function removeReplacement(t) { log("removeRep:" + t) }
    function addReplacement(a, b) { log("addRep:" + a + ">" + b); return true }
    function deleteHistoryLine(l) { log("deleteHist") }
    function clearHistory() { log("clearHist") }
    function setHistoryEnabled(v) { log("history:" + v) }
    function setEscapeCancels(v) { log("escape:" + v) }
    function setPauseMedia(v) { log("pause:" + v) }
    function setAutoSubmit(m) { log("enter:" + m) }
    function setHoldKey(k) { log("hold:" + k); return true }
    function installHook() { log("installHook") }
    function openConfig() { log("openConfig") }
  }

  QtObject {
    id: fakeBar
    property color barForeground: "white"
    property color urgent: "red"
    property string fontFamily: "sans-serif"
    function switchPanelFrom(owner, direction) { return true }
  }

  Item { id: anchor; width: 20; height: 20 }

  Plugin.Panel {
    id: panel
    bar: fakeBar
    anchorItem: anchor
    service: fake
    settings: ({})
  }

  Component.onCompleted: panel.open()

  Timer {
    interval: 30
    repeat: true
    running: true
    onTriggered: {
      if (root.phase === 0) {
        if (!panel.opened) return
        root.expect(fake.refreshCount >= 1, "refresh on open")
        root.expect(panel.headerStatus === "Ready · gpu-box · 42 ms", "header: " + panel.headerStatus)
        root.expect(panel.cursorIndex === panel.homeLast, "rests on last dictation")
        panel.activateCursor()
        root.expect(fake.calls.indexOf("copy:Hello there") >= 0, "copy last")
        // Microphone: Enter opens the list on the current mic; up + Enter picks.
        panel.moveCursor(0, 1)
        panel.activateCursor()
        root.expect(panel.pickerRow === panel.homeMic && panel.pickerIndex === 1, "mic list opens on current")
        panel.moveCursor(0, -1)
        panel.activateCursor()
        root.expect(!panel.picking && fake.calls.indexOf("setSource:builtin") >= 0, "pick mic")
        // Indicator: picking the current value writes nothing; Esc closes.
        panel.cursorIndex = panel.homeIndicator
        panel.activateCursor()
        root.expect(panel.pickerIndex === 2, "indicator list on capsule")
        panel.activateCursor()
        root.expect(fake.calls.join(",").indexOf("setIndicator") < 0, "current value not rewritten")
        panel.activateCursor()
        panel.moveCursor(0, 2)
        panel.moveCursor(1, 0)
        root.expect(panel.section === 0 && panel.picking, "left/right ignored while picking")
        panel.activateCursor()
        root.expect(fake.calls.indexOf("setIndicator:halo") >= 0, "pick halo")
        panel.cursorIndex = panel.homeLanguage
        panel.activateCursor()
        panel.closePicker()
        root.expect(fake.calls.join(",").indexOf("setLanguage") < 0, "closing writes nothing")
        panel.moveCursor(0, -20)
        panel.activateCursor()
        root.expect(fake.toggles === 1, "power toggle")
        fake.recState = "recording"
        root.expect(panel.headerStatus.indexOf("Recording · 0:0") === 0, "recording header: " + panel.headerStatus)
        fake.recState = "idle"
        fake.serverReachable = false
        root.expect(panel.headerStatus === "gpu-box unreachable", "unreachable header")
        fake.serverReachable = true

        panel.setSection(1)
        root.expect(panel.vocabAddTerm === 4 && panel.vocabAddRep === 6, "vocab indices")
        panel.cursorIndex = 2
        panel.deleteAtCursor()
        root.expect(panel.confirmKey === "term:Omarchy", "asks before removing")
        panel.deleteAtCursor()
        root.expect(fake.calls.indexOf("removeTerm:Omarchy") >= 0, "removes on second press")
        panel.cursorIndex = panel.vocabRepBase
        panel.activateCursor(); panel.activateCursor()
        root.expect(fake.calls.indexOf("removeRep:a Marche") >= 0, "remove replacement")

        panel.setSection(2)
        root.expect(fake.calls.indexOf("refreshHistory") >= 0, "history refresh")
        panel.cursorIndex = panel.histBase + 1
        panel.activateCursor()
        root.expect(fake.calls.indexOf("copy:Second one here") >= 0, "copy history")
        panel.cursorIndex = panel.histClear
        panel.activateCursor()
        root.expect(fake.calls.indexOf("clearHist") < 0, "clear asks first")
        panel.activateCursor()
        root.expect(fake.calls.indexOf("clearHist") >= 0, "clear all")

        panel.setSection(3)
        root.expect(panel.maxCursorIndex === 1, "stats has no rows")

        panel.setSection(4)
        panel.cursorIndex = panel.setHistory
        panel.activateCursor()
        root.expect(fake.calls.indexOf("history:false") >= 0, "history toggle")
        panel.cursorIndex = panel.setEnter
        panel.activateCursor()
        root.expect(panel.pickerRow === panel.setEnter && panel.pickerIndex === 0, "enter list on Off")
        panel.moveCursor(0, 1)
        panel.activateCursor()
        root.expect(fake.calls.indexOf("enter:always") >= 0, "pick always")
        panel.cursorIndex = panel.setMax
        panel.activateCursor()
        panel.moveCursor(0, 1)
        panel.activateCursor()
        root.expect(fake.calls.indexOf("setMax:300") >= 0, "pick max")
        panel.cursorIndex = panel.setConfig
        panel.activateCursor()
        root.expect(fake.calls.indexOf("openConfig") >= 0, "open config")
        panel.moveCursor(1, 0)
        root.expect(panel.section === 4, "no section past the end")
        panel.close()
        root.phase = 1
        return
      }
      if (root.phase === 1 && !panel.opened) {
        console.log(root.failures === "" ? "PANEL_SMOKE_OK" : "PANEL_SMOKE_FAIL: " + root.failures)
        Qt.quit()
      }
    }
  }
}
