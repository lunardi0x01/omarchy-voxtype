import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Quickshell exposes QProcess signal parameters that qmllint cannot resolve.
// qmllint disable signal-handler-parameters

// All state and commands for My Voxtype. The bar widget owns one instance;
// the panel only reads it and calls its functions.
//
// Sources:
// - Recording state: `voxtype status --follow --format json` (idle /
//   recording / transcribing / stopped), restarted if it exits.
// - Daemon: `systemctl --user is-active / is-enabled voxtype`.
// - Server: an HTTP probe of the remote endpoint's origin, every 30 s, when
//   the panel opens, and when a recording starts.
// - Config: `voxtype config get --json` plus the replacements map from
//   `voxtype config schema --json`.
// - History: ~/.local/share/voxtype/history.tsv (written by post_process.sh)
//   and timings.tsv (written here when a dictation finishes).
QtObject {
  id: root

  property var shell: null
  property var manifest: null

  // Commands, swappable by the tests.
  property string voxtypeCommand: "voxtype"
  property string systemctlCommand: "/usr/bin/systemctl"
  property string curlCommand: "/usr/bin/curl"
  property string pactlCommand: "/usr/bin/pactl"
  property string hyprctlCommand: "hyprctl"
  property string notifySendCommand: "/usr/bin/notify-send"
  property string copyCommand: "wl-copy"
  property bool followStatus: true

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/voxtype"
  readonly property string historyPath: Quickshell.env("VOXTYPE_HISTORY_FILE")
    || (home + "/.local/share/voxtype/history.tsv")
  readonly property string timingsPath: home + "/.local/share/voxtype/timings.tsv"
  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string postProcessPath: pluginDir + "/post_process.sh"

  // ---- Daemon and recording state ----------------------------------------
  property bool statusKnown: false
  property bool daemonActive: false
  property bool autoStartKnown: false
  property bool autoStartEnabled: false
  property string recState: "stopped"        // idle | recording | transcribing | stopped
  property real recordingStartedAt: 0        // ms since epoch
  property real transcribingStartedAt: 0
  property real lastRecordingSecs: 0
  property int lastLatencyMs: 0
  readonly property bool recording: recState === "recording"
  readonly property bool transcribing: recState === "transcribing"
  readonly property bool busy: recording || transcribing

  // ---- Server -------------------------------------------------------------
  property string endpoint: ""
  readonly property string serverOrigin: Model.originOf(endpoint)
  readonly property string serverHost: Model.hostLabel(endpoint)
  property bool serverKnown: false
  property bool serverReachable: false
  property int serverPingMs: -1
  property real serverCheckedAt: 0
  property bool warnedUnreachable: false

  // ---- Config -------------------------------------------------------------
  property bool configKnown: false
  property var config: ({})
  property var replacements: ({})
  readonly property var terms: Model.parseTerms(config["whisper.initial_prompt"])
  readonly property string language: String(config["whisper.language"] || "en")
  readonly property bool osdEnabled: config["osd.enabled"] === true
  readonly property string osdStyle: String(config["osd.style"] || "default")
  readonly property bool pauseMedia: config["audio.pause_media"] === true
  readonly property string autoSubmit: config["output.auto_submit"] === true ? "always"
    : config["text.smart_auto_submit"] === true ? "say" : "off"
  readonly property int maxDurationSecs: Number(config["audio.max_duration_secs"] || 60)
  readonly property int remoteTimeoutSecs: Number(config["whisper.remote_timeout_secs"] || 30)
  readonly property string postProcessCommand: String(config["output.post_process.command"] || "")
  readonly property bool hookInstalled: postProcessCommand === postProcessPath

  // ---- Files the shortcuts and the hook read ------------------------------
  property bool historyEnabled: true
  property bool escapeCancels: true
  property string holdKey: ""

  // ---- Microphones ----------------------------------------------------------
  property var sources: []          // [{ name, description }]
  property string defaultSource: ""
  readonly property string defaultSourceLabel: Model.sourceLabel(sources, defaultSource)

  // ---- History --------------------------------------------------------------
  property var history: []          // newest first: [{ line, time, text, words }]
  property var timings: []          // [{ time, recSecs, latencyMs }]
  readonly property var stats: Model.computeStats(history, timings, Date.now())
  readonly property var lastEntry: history.length > 0 ? history[0] : null

  // ---- Messages -------------------------------------------------------------
  property string error: ""
  property string actionMessage: ""

  readonly property string statusText: !statusKnown ? "Checking"
    : !daemonActive ? "Off"
    : recording ? "Recording"
    : transcribing ? "Transcribing"
    : serverKnown && !serverReachable ? "Server unreachable"
    : "Ready"
  readonly property bool problem: daemonActive && serverKnown && !serverReachable
  readonly property string tooltipText: {
    var lines = ["Voxtype: " + statusText]
    if (daemonActive && serverHost) {
      lines.push(serverKnown
        ? (serverReachable ? serverHost + " · " + serverPingMs + " ms" : serverHost + " unreachable")
        : serverHost)
    }
    return lines.join("\n")
  }

  signal openPanelRequested()

  // ---- Refresh --------------------------------------------------------------

  function refresh() {
    refreshDaemon()
    refreshConfig()
    refreshFlags()
    refreshSources()
    refreshHistory()
    probeServer()
  }

  function refreshDaemon() {
    run(["sh", "-c", "\"$0\" --user is-active voxtype; \"$0\" --user is-enabled voxtype", systemctlCommand],
      function(code, out) {
        var lines = String(out).trim().split("\n")
        root.daemonActive = lines[0] === "active"
        root.autoStartKnown = lines.length > 1
        root.autoStartEnabled = lines.length > 1 && lines[1] === "enabled"
        root.statusKnown = true
        if (!root.daemonActive) root.recState = "stopped"
        else if (root.recState === "stopped") root.recState = "idle"
      })
  }

  function refreshConfig() {
    run(["sh", "-c", "\"$0\" config get --json; echo; \"$0\" config schema --json", voxtypeCommand],
      function(code, out) {
        var parsed = Model.parseConfigOutput(out)
        if (!parsed) {
          root.error = "Couldn't read Voxtype's config."
          return
        }
        var cfg = parsed.config
        for (var k in root.settling)
          if (Object.prototype.hasOwnProperty.call(root.settling, k)) cfg[k] = root.config[k]
        root.config = cfg
        root.replacements = parsed.replacements
        root.endpoint = String(parsed.config["whisper.remote_endpoint"] || "")
        root.configKnown = true
      })
  }

  function refreshFlags() {
    run(["sh", "-c",
      "[ -e \"$0/history-off\" ] && echo history-off; [ -e \"$0/escape-off\" ] && echo escape-off; "
      + "printf 'hold:'; head -n 1 \"$0/hold-key\" 2>/dev/null; echo", configDir],
      function(code, out) {
        var text = String(out)
        root.historyEnabled = text.indexOf("history-off") < 0
        root.escapeCancels = text.indexOf("escape-off") < 0
        var m = text.match(/hold:([^\n]*)/)
        root.holdKey = m ? m[1].trim() : ""
      })
  }

  function refreshSources() {
    run(["sh", "-c", "\"$0\" get-default-source; \"$0\" -f json list sources", pactlCommand],
      function(code, out) {
        var parsed = Model.parseSources(out)
        root.defaultSource = parsed.defaultSource
        root.sources = parsed.sources
      })
  }

  function refreshHistory() {
    run(["sh", "-c", "cat \"$0\" 2>/dev/null; printf '\\n--TIMINGS--\\n'; cat \"$1\" 2>/dev/null",
        historyPath, timingsPath],
      function(code, out) {
        var parts = String(out).split("\n--TIMINGS--\n")
        root.history = Model.parseHistory(parts[0] || "")
        root.timings = Model.parseTimings(parts[1] || "")
      })
  }

  function probeServer() {
    if (!serverOrigin) return
    run([curlCommand, "-s", "-o", "/dev/null", "-w", "%{http_code} %{time_total}",
        "--max-time", "3", serverOrigin + "/"],
      function(code, out) {
        var probe = Model.parseProbe(code, out)
        root.serverReachable = probe.reachable
        root.serverPingMs = probe.ms
        root.serverKnown = true
        root.serverCheckedAt = Date.now()
        if (probe.reachable) root.warnedUnreachable = false
      })
  }

  // ---- State stream -----------------------------------------------------------

  function applyState(next) {
    var prev = recState
    if (next === prev) return
    var now = Date.now()
    if (next === "recording") {
      recordingStartedAt = now
      probeServer()
      if (serverKnown && !serverReachable && !warnedUnreachable) {
        warnedUnreachable = true
        notify("Dictation server unreachable",
          (serverHost || "The server") + " isn't answering, so this recording will fail.")
      }
    } else if (next === "transcribing") {
      transcribingStartedAt = now
      lastRecordingSecs = recordingStartedAt > 0 ? (now - recordingStartedAt) / 1000 : 0
    } else if (next === "idle" && prev === "transcribing") {
      lastLatencyMs = transcribingStartedAt > 0 ? Math.round(now - transcribingStartedAt) : 0
      recordTiming(lastRecordingSecs, lastLatencyMs)
      historyRefreshTimer.restart()
    }
    if (next === "stopped") daemonActive = false
    else if (!daemonActive) refreshDaemon()
    recState = next
  }

  function recordTiming(recSecs, latencyMs) {
    if (recSecs <= 0) return
    run(["sh", "-c", "mkdir -p \"$(dirname \"$0\")\"; umask 077; printf '%s\\t%s\\t%s\\n' \"$(date -Iseconds)\" \"$1\" \"$2\" >> \"$0\"",
      timingsPath, recSecs.toFixed(2), String(latencyMs)], null)
  }

  // ---- Actions ----------------------------------------------------------------

  function toggleDaemon() {
    if (!statusKnown) return false
    var verb = daemonActive ? "stop" : "start"
    run([systemctlCommand, "--user", verb, "voxtype"], function(code, out, err) {
      root.report(code, verb === "start" ? "Voxtype started." : "Voxtype stopped.", err)
      root.refreshDaemon()
    })
    return true
  }

  function setAutoStart(enabled) {
    run([systemctlCommand, "--user", enabled ? "enable" : "disable", "voxtype"], function(code, out, err) {
      root.report(code, enabled ? "Starts at login." : "Doesn't start at login.", err)
      root.refreshDaemon()
    })
  }

  // Config writes. `voxtype config set` rewrites config.toml through a
  // temporary file, so two at once can make one fail ("No such file or
  // directory"). Writes therefore go through a queue, one at a time; the
  // panel's copy of the value changes at once so quick clicks step on from
  // the new value; the daemon restarts (and the config is re-read) once,
  // after the last queued write.
  property var configQueue: []
  property bool configWriting: false
  property bool wroteSinceRestart: false

  function setConfig(key, value) {
    applyLocal(key, value)
    queueConfig([voxtypeCommand, "config", "set", key, String(value)])
  }

  // For values stepped through with ←/→ or repeated clicks: the panel shows
  // each step at once, but only the value left standing for `settleMs` is
  // written (one write, one restart), however many steps it took.
  property var settling: ({})
  property int settleMs: 1000
  function setConfigSettled(key, value) {
    applyLocal(key, value)
    var next = Object.assign({}, settling)
    next[key] = String(value)
    settling = next
    settleTimer.restart()
  }
  function flushSettled() {
    var pending = settling
    settling = ({})
    for (var key in pending)
      if (Object.prototype.hasOwnProperty.call(pending, key))
        queueConfig([voxtypeCommand, "config", "set", key, pending[key]])
  }

  function unsetConfig(key) {
    if (key.indexOf("text.replacements.") === 0) {
      var reps = Object.assign({}, replacements)
      delete reps[key.slice("text.replacements.".length)]
      replacements = reps
    }
    queueConfig([voxtypeCommand, "config", "unset", key])
  }

  function applyLocal(key, value) {
    if (key.indexOf("text.replacements.") === 0) {
      var reps = Object.assign({}, replacements)
      reps[key.slice("text.replacements.".length)] = String(value)
      replacements = reps
      return
    }
    var next = Object.assign({}, config)
    var text = String(value)
    next[key] = text === "true" ? true : text === "false" ? false
      : /^-?\d+(\.\d+)?$/.test(text) ? Number(text) : text
    config = next
  }

  function queueConfig(argv) {
    var q = configQueue.slice()
    q.push(argv)
    configQueue = q
    drainConfig()
  }

  function drainConfig() {
    if (configWriting) return
    if (configQueue.length === 0) {
      if (wroteSinceRestart) {
        wroteSinceRestart = false
        requestRestart()
        refreshConfig()
      }
      return
    }
    var argv = configQueue[0]
    configQueue = configQueue.slice(1)
    configWriting = true
    wroteSinceRestart = true
    run(argv, function(code, out, err) {
      root.configWriting = false
      if (code !== 0) root.report(code, "", err)
      else root.error = ""
      Qt.callLater(root.drainConfig)
    })
  }

  // One restart after a burst of writes. It runs as the last item of the
  // config queue, so it never overlaps a write, waits while a dictation is
  // in progress, and clears systemd's start-rate counter first (five
  // restarts in ten seconds would otherwise leave Voxtype failed).
  property bool restartPending: false
  function requestRestart() {
    restartPending = true
    restartTimer.restart()
  }
  function restartIfIdle() {
    if (!restartPending) return
    if (busy || configWriting || configQueue.length > 0) { restartTimer.restart(); return }
    restartPending = false
    if (!daemonActive) return
    configWriting = true
    run(["sh", "-c", "\"$0\" --user reset-failed voxtype 2>/dev/null; exec \"$0\" --user restart voxtype",
        systemctlCommand], function(code, out, err) {
      root.configWriting = false
      if (code !== 0) root.report(code, "", err)
      root.refreshDaemon()
      Qt.callLater(root.drainConfig)
    })
  }

  function setTerms(list) {
    var value = Model.formatTerms(list)
    if (value === "") unsetConfig("whisper.initial_prompt")
    else setConfig("whisper.initial_prompt", value)
  }
  function addTerm(term) {
    var clean = Model.cleanTerm(term)
    if (clean === "" || Model.hasTerm(terms, clean)) return false
    setTerms(terms.concat([clean]))
    return true
  }
  function removeTerm(term) {
    setTerms(terms.filter(function(t) { return t !== term }))
  }

  function addReplacement(heard, written) {
    var from = Model.cleanPhrase(heard)
    var to = Model.cleanPhrase(written)
    if (from === "" || to === "") return false
    setConfig("text.replacements." + from, to)
    return true
  }
  function removeReplacement(heard) {
    unsetConfig("text.replacements." + heard)
  }

  function setDefaultSource(name) {
    if (!name) return
    run([pactlCommand, "set-default-source", name], function(code, out, err) {
      if (code !== 0) root.report(code, "", err)
      root.refreshSources()
    })
  }
  function cycleSource(step) {
    var next = Model.cycle(sources.map(function(s) { return s.name }), defaultSource, step)
    if (next) setDefaultSource(next)
  }

  function setLanguage(code) { if (code && code !== language) setConfig("whisper.language", code) }
  function setIndicator(id) {
    if (!id || id === indicator) return
    if (id === "off") setConfig("osd.enabled", "false")
    else {
      if (!osdEnabled) setConfig("osd.enabled", "true")
      setConfig("osd.style", id)
    }
  }
  function setMaxDuration(secs) { if (secs && secs !== maxDurationSecs) setConfig("audio.max_duration_secs", secs) }
  function setRemoteTimeout(secs) { if (secs && secs !== remoteTimeoutSecs) setConfig("whisper.remote_timeout_secs", secs) }

  function cycleLanguage(step) {
    setConfigSettled("whisper.language", Model.cycle(Model.LANGUAGES, language, step))
  }

  // Indicator: off, then each OSD style.
  readonly property string indicator: osdEnabled ? osdStyle : "off"
  function cycleIndicator(step) {
    var next = Model.cycle(Model.INDICATORS, indicator, step)
    if (next === "off") setConfigSettled("osd.enabled", "false")
    else {
      setConfigSettled("osd.enabled", "true")
      setConfigSettled("osd.style", next)
    }
  }

  // Both keys are written (one queue, one restart) so only one mode is on.
  function setAutoSubmit(mode) {
    if (!mode || mode === autoSubmit) return
    setConfig("output.auto_submit", mode === "always" ? "true" : "false")
    setConfig("text.smart_auto_submit", mode === "say" ? "true" : "false")
  }

  function setPauseMedia(enabled) { setConfig("audio.pause_media", enabled ? "true" : "false") }
  function cycleMaxDuration(step) {
    setConfigSettled("audio.max_duration_secs", Model.cycle(Model.MAX_DURATIONS, maxDurationSecs, step))
  }
  function cycleTimeout(step) {
    setConfigSettled("whisper.remote_timeout_secs", Model.cycle(Model.TIMEOUTS, remoteTimeoutSecs, step))
  }

  function setFlag(name, on) {
    var path = configDir + "/" + name
    run(on ? ["sh", "-c", "mkdir -p \"$(dirname \"$0\")\" && : > \"$0\"", path] : ["rm", "-f", path],
      function() {
        root.refreshFlags()
        if (name === "escape-off") root.reloadHyprland()
      })
  }
  function setHistoryEnabled(enabled) { setFlag("history-off", !enabled) }
  function setEscapeCancels(enabled) { setFlag("escape-off", !enabled) }

  // Returns false when the chord is not a plausible Hyprland chord.
  function setHoldKey(chord) {
    var clean = Model.cleanChord(chord)
    if (clean === null) return false
    var path = configDir + "/hold-key"
    run(clean === "" ? ["rm", "-f", path]
        : ["sh", "-c", "mkdir -p \"$(dirname \"$0\")\" && printf '%s\\n' \"$1\" > \"$0\"", path, clean],
      function() {
        root.refreshFlags()
        root.reloadHyprland()
        root.actionMessage = clean === "" ? "Hold-to-talk key removed." : "Hold " + clean + " to talk."
        root.actionMessageTimer.restart()
      })
    return true
  }

  function reloadHyprland() { run([hyprctlCommand, "reload"], null) }

  function installHook() { setConfig("output.post_process.command", postProcessPath) }

  function copyText(text) {
    run([copyCommand, "--", String(text)], function(code, out, err) {
      root.report(code, "Copied.", err)
    })
  }

  function deleteHistoryLine(line) {
    run(["sh", "-c", "[ -f \"$0\" ] || exit 0; t=$(mktemp \"$0.XXXXXX\") && "
        + "awk -v L=\"$1\" '$0 != L' \"$0\" > \"$t\" && chmod 600 \"$t\" && mv -f \"$t\" \"$0\"",
        historyPath, line],
      function(code, out, err) {
        if (code !== 0) root.report(code, "", err)
        root.refreshHistory()
      })
  }
  function clearHistory() {
    run(["sh", "-c", "[ -f \"$0\" ] && : > \"$0\"; [ -f \"$1\" ] && : > \"$1\"; exit 0", historyPath, timingsPath],
      function(code, out, err) {
        root.report(code, "History cleared.", err)
        root.refreshHistory()
      })
  }

  function openConfig() {
    run(["sh", "-c", "exec uwsm-app -- xdg-open \"$0\" >/dev/null 2>&1 || exec xdg-open \"$0\"",
      configDir + "/config.toml"], null)
  }

  function notify(title, body) {
    run([notifySendCommand, "-a", "Voxtype", "-u", "normal", "-i", "audio-input-microphone", title, body], null)
  }

  function report(code, okMessage, err) {
    if (code === 0) {
      error = ""
      if (okMessage) {
        actionMessage = okMessage
        actionMessageTimer.restart()
      }
    } else {
      error = Model.boundedDiagnostic(err, "Command failed.")
    }
  }

  // ---- Process plumbing --------------------------------------------------------

  // run(argv, callback(exitCode, stdout, stderr)): one Process per call,
  // destroyed when it exits.
  function run(argv, callback) {
    var proc = runner.createObject(root, { command: argv })
    if (!proc) return
    proc.done = callback
    proc.running = true
  }

  property Component runner: Component {
    Process {
      id: proc
      property var done: null
      running: false
      stdout: StdioCollector { id: procOut; waitForEnd: true }
      stderr: StdioCollector { id: procErr; waitForEnd: true }
      onExited: function(exitCode) {
        if (typeof proc.done === "function") {
          try { proc.done(exitCode, procOut.text, procErr.text) }
          catch (e) { console.warn("lunardi0x01.voxtype: " + e) }
        }
        proc.destroy()
      }
    }
  }

  property Process statusFollower: Process {
    running: root.followStatus
    command: [root.voxtypeCommand, "status", "--follow", "--format", "json"]
    stdout: SplitParser {
      onRead: function(line) {
        var state = Model.parseStatusLine(line)
        if (state) root.applyState(state)
      }
    }
    onExited: function(exitCode) {
      root.applyState("stopped")
      if (root.followStatus) root.followRestart.restart()
    }
  }

  property Timer followRestart: Timer {
    interval: 3000
    onTriggered: if (root.followStatus) root.statusFollower.running = true
  }

  property Timer serverTimer: Timer {
    interval: 30000
    repeat: true
    running: root.daemonActive && root.serverOrigin !== ""
    onTriggered: root.probeServer()
  }

  property Timer daemonTimer: Timer {
    interval: 15000
    repeat: true
    running: true
    onTriggered: root.refreshDaemon()
  }

  property Timer settleTimer: Timer {
    interval: root.settleMs
    onTriggered: root.flushSettled()
  }

  property Timer restartTimer: Timer {
    interval: 600
    onTriggered: root.restartIfIdle()
  }

  // The hook appends to history.tsv after the text is typed; give it a moment.
  property Timer historyRefreshTimer: Timer {
    interval: 400
    onTriggered: root.refreshHistory()
  }

  property Timer actionMessageTimer: Timer {
    interval: 4000
    onTriggered: root.actionMessage = ""
  }

  // The first refresh probes before the config (and so the endpoint) is
  // known; probe again as soon as it is.
  onServerOriginChanged: if (serverOrigin !== "") probeServer()

  // Logged once per service start, so the shell log shows which build is
  // running (the shell caches plugin QML until it restarts).
  readonly property string build: "0.1.0+autosubmit"

  Component.onCompleted: {
    console.info("lunardi0x01.voxtype: service started, build " + build)
    refresh()
  }
}
