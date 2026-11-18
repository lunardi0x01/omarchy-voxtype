pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Model.js" as Model

// Colours come from Commons.Color, never bare `Color`: QtQuick 6.12 exports
// its own Color singleton, which shadows qs.Commons' one.

// My Voxtype panel. Layout follows My Sunshine: a header (glyph, title,
// upper-case status, power switch), then section tabs, then the section.
//
// Cursor order: 0 = power switch, 1 = section tabs, 2.. = the section's rows.
// Keys: up/down (jk) move, left/right (hl) change section, 1-5 pick a
// section, Enter/Space activate (on a setting it opens its list of options;
// Enter picks one, Esc closes the list), x/Delete removes (asks first),
// c copies, Tab moves to the next bar panel, Esc closes.
Ui.Panel {
  id: root
  moduleName: "lunardi0x01.voxtype"
  manageIpc: false

  property var shell: null
  property var manifest: null
  property var service: null
  property var anchorItem: null
  property var hostWidget: null

  property int section: 0
  property int cursorIndex: 0
  property bool cursorActive: false
  property Item activeEditor: null
  // Two-step remove: the row key waiting for confirmation ("term:x",
  // "rep:x", "hist:<line>", "clear").
  property string confirmKey: ""
  property real nowMs: Date.now()
  property var rowItems: ({})
  // Inline option list: the row it belongs to (-1 = closed) and the
  // highlighted option.
  property int pickerRow: -1
  property int pickerIndex: 0
  readonly property bool picking: pickerRow >= 0

  readonly property var sections: ["Home", "Vocabulary", "History", "Stats", "Settings"]
  readonly property var svc: service || (shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor(moduleName) : null)
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color live: accent
  readonly property color onFill: Commons.Color.popups.background
  readonly property color cardFill: Style.normalFillFor(foreground, accent)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.16)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool editing: activeEditor !== null
  readonly property bool ready: !!svc && svc.statusKnown

  readonly property string headerStatus: {
    if (!svc || !svc.statusKnown) return "Checking…"
    if (!svc.daemonActive) return "Off"
    if (svc.recording) return "Recording · " + Model.formatElapsed((nowMs - svc.recordingStartedAt) / 1000)
    if (svc.transcribing) return "Transcribing…"
    if (svc.serverKnown && !svc.serverReachable) return (svc.serverHost || "Server") + " unreachable"
    var parts = ["Ready"]
    if (svc.serverHost) parts.push(svc.serverHost)
    if (svc.serverKnown && svc.serverPingMs >= 0) parts.push(svc.serverPingMs + " ms")
    return parts.join(" · ")
  }
  readonly property color headerStatusColor: !svc || !svc.daemonActive ? dim
    : svc.recording || svc.transcribing ? live
    : svc.problem ? urgent
    : foreground

  // ---- Rows per section --------------------------------------------------------

  readonly property var termList: svc ? svc.terms : []
  readonly property var replacementRows: svc ? Model.replacementList(svc.replacements) : []
  readonly property var historyRows: svc ? Model.limitHistory(svc.history) : []

  // Home: last dictation, microphone, language, indicator, then two footer buttons.
  readonly property int homeLast: 2
  readonly property int homeMic: 3
  readonly property int homeLanguage: 4
  readonly property int homeIndicator: 5
  readonly property int homeAutoStart: 6
  readonly property int homeHistory: 7
  // Vocabulary: terms, the add-term field, replacements, the add-replacement row.
  readonly property int vocabTermBase: 2
  readonly property int vocabAddTerm: vocabTermBase + termList.length
  readonly property int vocabRepBase: vocabAddTerm + 1
  readonly property int vocabAddRep: vocabRepBase + replacementRows.length
  // History: entries, then Clear all.
  readonly property int histBase: 2
  readonly property int histClear: histBase + historyRows.length
  // Settings.
  readonly property int setHistory: 2
  readonly property int setEscape: 3
  readonly property int setPause: 4
  readonly property int setEnter: 5
  readonly property int setHold: 6
  readonly property int setMax: 7
  readonly property int setTimeout: 8
  readonly property int setHook: 9
  readonly property int setConfig: 10

  readonly property int maxCursorIndex: section === 0 ? homeHistory
    : section === 1 ? vocabAddRep
    : section === 2 ? (historyRows.length > 0 ? histClear : 1)
    : section === 3 ? 1
    : setConfig

  function has(index) { return cursorActive && cursorIndex === index }

  function isPickerRow(index) {
    return (section === 0 && (index === homeMic || index === homeLanguage || index === homeIndicator))
      || (section === 4 && (index === setEnter || index === setMax || index === setTimeout))
  }

  // [{ value, label }] for a picker row, and the value currently in use.
  function pickerOptions(index) {
    if (!svc) return []
    if (section === 0 && index === homeMic)
      return svc.sources.map(function(s) { return { value: s.name, label: Model.shortDevice(s.description) } })
    if (section === 0 && index === homeLanguage)
      return Model.LANGUAGES.map(function(c) { return { value: c, label: Model.languageName(c) } })
    if (section === 0 && index === homeIndicator)
      return Model.INDICATORS.map(function(i) { return { value: i, label: Model.indicatorName(i) } })
    if (section === 4 && index === setEnter)
      return Model.AUTO_SUBMIT.map(function(m) { return { value: m, label: Model.autoSubmitName(m) } })
    if (section === 4 && index === setMax)
      return Model.MAX_DURATIONS.map(function(n) { return { value: n, label: n + " s" } })
    if (section === 4 && index === setTimeout)
      return Model.TIMEOUTS.map(function(n) { return { value: n, label: n + " s" } })
    return []
  }
  function pickerCurrent(index) {
    if (!svc) return ""
    if (section === 0 && index === homeMic) return svc.defaultSource
    if (section === 0 && index === homeLanguage) return svc.language
    if (section === 0 && index === homeIndicator) return svc.indicator
    if (section === 4 && index === setEnter) return svc.autoSubmit
    if (section === 4 && index === setMax) return svc.maxDurationSecs
    if (section === 4 && index === setTimeout) return svc.remoteTimeoutSecs
    return ""
  }

  function openPicker(index) {
    var options = pickerOptions(index)
    if (options.length === 0) return
    confirmKey = ""
    cursorIndex = index
    var current = String(pickerCurrent(index))
    pickerIndex = 0
    for (var i = 0; i < options.length; i++) if (String(options[i].value) === current) pickerIndex = i
    pickerRow = index
    Qt.callLater(ensureCursorVisible)
  }
  function closePicker() { pickerRow = -1 }

  // Picking saves once (one write, one restart); picking the current value does nothing.
  function choose(index, value) {
    closePicker()
    if (!svc || String(value) === String(pickerCurrent(index))) return
    if (section === 0 && index === homeMic) svc.setDefaultSource(value)
    else if (section === 0 && index === homeLanguage) svc.setLanguage(value)
    else if (section === 0 && index === homeIndicator) svc.setIndicator(value)
    else if (section === 4 && index === setEnter) svc.setAutoSubmit(value)
    else if (section === 4 && index === setMax) svc.setMaxDuration(value)
    else if (section === 4 && index === setTimeout) svc.setRemoteTimeout(value)
  }

  function resolveHost() {
    if (!bar && shell && shell.bar) bar = shell.bar
    if (!hostWidget && bar && typeof bar.moduleWidgets === "function") {
      const widgets = bar.moduleWidgets(moduleName)
      if (widgets.length > 0) hostWidget = widgets[0]
    }
    if (!anchorItem && hostWidget && hostWidget.panelAnchor) anchorItem = hostWidget.panelAnchor
  }

  function open() {
    resolveHost()
    controller.show()
    if (svc) svc.refresh()
  }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    return bar && typeof bar.switchPanelFrom === "function"
      ? bar.switchPanelFrom(barIdentity, direction) : false
  }

  function setSection(index) {
    var next = Math.max(0, Math.min(sections.length - 1, index))
    if (next === section) return
    leaveEditor()
    closePicker()
    confirmKey = ""
    section = next
    cursorIndex = 1
    flick.contentY = 0
    if (svc && (next === 2 || next === 3)) svc.refreshHistory()
  }

  function moveCursor(dx, dy) {
    if (picking) {
      if (dy !== 0) {
        var count = pickerOptions(pickerRow).length
        pickerIndex = Math.max(0, Math.min(count - 1, pickerIndex + dy))
      }
      return
    }
    if (dy !== 0) {
      cursorActive = true
      confirmKey = ""
      cursorIndex = Math.max(0, Math.min(maxCursorIndex, cursorIndex + dy))
      Qt.callLater(ensureCursorVisible)
      return
    }
    if (dx === 0) return
    cursorActive = true
    setSection(section + dx)
  }

  function activateCursor() {
    if (!svc) return
    if (picking) {
      var options = pickerOptions(pickerRow)
      if (pickerIndex >= 0 && pickerIndex < options.length) choose(pickerRow, options[pickerIndex].value)
      else closePicker()
      return
    }
    var i = cursorIndex
    if (isPickerRow(i)) { openPicker(i); return }
    if (i === 0) { svc.toggleDaemon(); return }
    if (i === 1) { setSection(section + 1 >= sections.length ? 0 : section + 1); return }
    if (section === 0) {
      if (i === homeLast) { if (svc.lastEntry) svc.copyText(svc.lastEntry.text) }
      else if (i === homeAutoStart) { if (svc.autoStartKnown) svc.setAutoStart(!svc.autoStartEnabled) }
      else if (i === homeHistory) setSection(2)
    } else if (section === 1) {
      if (i >= vocabTermBase && i < vocabAddTerm) askOrRemove("term:" + termList[i - vocabTermBase])
      else if (i === vocabAddTerm) focusEditor(addTermField)
      else if (i >= vocabRepBase && i < vocabAddRep) askOrRemove("rep:" + replacementRows[i - vocabRepBase].heard)
      else if (i === vocabAddRep) focusEditor(addHeardField)
    } else if (section === 2) {
      if (i >= histBase && i < histClear) svc.copyText(historyRows[i - histBase].text)
      else if (i === histClear) askOrRemove("clear")
    } else if (section === 4) {
      if (i === setHistory) svc.setHistoryEnabled(!svc.historyEnabled)
      else if (i === setEscape) svc.setEscapeCancels(!svc.escapeCancels)
      else if (i === setPause) svc.setPauseMedia(!svc.pauseMedia)
      else if (i === setHold) focusEditor(holdField)
      else if (i === setHook) { if (!svc.hookInstalled) svc.installHook() }
      else if (i === setConfig) svc.openConfig()
    }
  }

  function deleteAtCursor() {
    var i = cursorIndex
    if (section === 1) {
      if (i >= vocabTermBase && i < vocabAddTerm) askOrRemove("term:" + termList[i - vocabTermBase])
      else if (i >= vocabRepBase && i < vocabAddRep) askOrRemove("rep:" + replacementRows[i - vocabRepBase].heard)
    } else if (section === 2) {
      if (i >= histBase && i < histClear) askOrRemove("hist:" + historyRows[i - histBase].line)
      else if (i === histClear) askOrRemove("clear")
    } else if (section === 4 && i === setHold && svc && svc.holdKey !== "") {
      svc.setHoldKey("")
    }
  }

  // First press asks, the second (on the same row) does it.
  function askOrRemove(key) {
    if (!svc) return
    if (confirmKey !== key) { confirmKey = key; return }
    confirmKey = ""
    if (key.indexOf("term:") === 0) svc.removeTerm(key.slice(5))
    else if (key.indexOf("rep:") === 0) svc.removeReplacement(key.slice(4))
    else if (key.indexOf("hist:") === 0) svc.deleteHistoryLine(key.slice(5))
    else if (key === "clear") svc.clearHistory()
  }

  function copyAtCursor() {
    if (!svc) return
    if (section === 0 && cursorIndex === homeLast && svc.lastEntry) svc.copyText(svc.lastEntry.text)
    else if (section === 2 && cursorIndex >= histBase && cursorIndex < histClear)
      svc.copyText(historyRows[cursorIndex - histBase].text)
  }

  function focusEditor(field) {
    if (!field) return
    confirmKey = ""
    field.forceActiveFocus()
  }

  function noteEditor(item, focused) {
    if (focused) activeEditor = item
    else if (activeEditor === item) activeEditor = null
  }

  function leaveEditor() {
    activeEditor = null
    if (opened) Qt.callLater(keyCatcher.forceActiveFocus)
  }

  function registerRow(index, item) {
    var map = rowItems
    map[index] = item
    rowItems = map
  }

  function ensureCursorVisible() {
    var item = rowItems[cursorIndex]
    if (cursorIndex <= 1) { flick.contentY = 0; return }
    if (!item || !item.visible) return
    var pos = item.mapToItem(flick.contentItem, 0, 0)
    var pad = Style.space(6)
    if (pos.y - pad < flick.contentY) flick.contentY = Math.max(0, pos.y - pad)
    else if (pos.y + item.height + pad > flick.contentY + flick.height)
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height),
        pos.y + item.height + pad - flick.height)
  }

  Component.onCompleted: resolveHost()
  onShellChanged: resolveHost()
  onOpenedChanged: {
    if (opened) {
      cursorIndex = section === 0 ? homeLast : 1
      cursorActive = false
      confirmKey = ""
      nowMs = Date.now()
      if (svc) svc.refresh()
      Qt.callLater(keyCatcher.forceActiveFocus)
    } else {
      leaveEditor()
      closePicker()
      confirmKey = ""
    }
  }
  onMaxCursorIndexChanged: if (cursorIndex > maxCursorIndex) cursorIndex = maxCursorIndex

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && !!root.svc && root.svc.recording
    onTriggered: root.nowMs = Date.now()
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelContent.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteAtCursor()
      onCloseRequested: {
        if (root.picking) root.closePicker()
        else if (root.confirmKey !== "") root.confirmKey = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (/^[1-5]$/.test(text)) {
          root.cursorActive = true
          root.setSection(parseInt(text, 10) - 1)
        } else if (text === "c" || text === "C") root.copyAtCursor()
        else if (text === "r" || text === "R") { if (root.svc) root.svc.refresh() }
      }

      Column {
        id: panelContent
        width: parent.width
        spacing: Style.space(12)

        // ---- Header: glyph, title + status, power switch -------------------
        RowLayout {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: root.svc && root.svc.daemonActive ? "󰍬" : "󰍭"
            color: root.svc && root.svc.problem && !root.svc.busy ? root.urgent : root.accent
            opacity: root.svc && root.svc.daemonActive ? 1.0 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            Layout.alignment: Qt.AlignVCenter
          }

          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(2)
            Text {
              Layout.fillWidth: true
              text: "Voxtype"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              Layout.fillWidth: true
              text: root.headerStatus.toUpperCase()
              color: root.headerStatusColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
          }

          Ui.ToggleSwitch {
            id: powerSwitch
            enabled: root.ready
            checked: root.svc ? root.svc.daemonActive : false
            hasCursor: root.has(0)
            foreground: root.foreground
            Layout.alignment: Qt.AlignVCenter
            onHovered: function(value) { if (value) { root.cursorActive = true; root.cursorIndex = 0 } }
            onToggled: if (root.svc) root.svc.toggleDaemon()
            Accessible.role: Accessible.CheckBox
            Accessible.name: checked ? "Stop Voxtype" : "Start Voxtype"
            Accessible.checked: checked
            Ui.PanelToolTip {
              visible: powerSwitch.containsMouse
              text: powerSwitch.checked ? "Stop Voxtype" : "Start Voxtype"
              fontFamily: root.fontFamily
            }
          }
        }

        // ---- Section tabs ----------------------------------------------------
        Ui.CursorSurface {
          id: tabBar
          width: parent.width
          implicitHeight: tabRow.implicitHeight + Style.space(4) * 2
          hasCursor: root.has(1)
          foreground: root.foreground
          Component.onCompleted: root.registerRow(1, tabBar)

          RowLayout {
            id: tabRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(4)
            anchors.rightMargin: Style.space(4)
            spacing: Style.space(2)

            Repeater {
              model: root.sections
              delegate: Item {
                id: tabItem
                required property string modelData
                required property int index
                readonly property bool current: root.section === index
                Layout.fillWidth: true
                implicitHeight: tabLabel.implicitHeight + Style.space(6) * 2

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: tabItem.current ? root.cardFill : "transparent"
                  border.width: tabItem.current ? 1 : 0
                  border.color: root.hairline
                }
                Text {
                  id: tabLabel
                  anchors.centerIn: parent
                  text: tabItem.modelData
                  color: tabItem.current ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: tabItem.current
                  textFormat: Text.PlainText
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: { root.cursorActive = true; root.cursorIndex = 1 }
                  onClicked: root.setSection(tabItem.index)
                }
              }
            }
          }
        }

        // ---- Section content (scrolls when long) ----------------------------
        Flickable {
          id: flick
          width: parent.width
          height: Math.min(sectionColumn.implicitHeight, Style.space(460))
          contentWidth: width
          contentHeight: sectionColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: sectionColumn
            width: flick.width
            spacing: Style.space(12)

            // ================= Home =================
            Column {
              visible: root.section === 0
              width: parent.width
              spacing: Style.space(10)

              // Live card while recording or transcribing; a quiet line otherwise.
              Rectangle {
                visible: !!root.svc && root.svc.busy
                width: parent.width
                implicitHeight: liveContent.implicitHeight + Style.space(10) * 2
                color: root.cardFill
                border.width: 1
                border.color: root.hairline
                radius: Style.cornerRadius

                RowLayout {
                  id: liveContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(10)

                  StatusDot {
                    dotColor: root.live
                    hollow: !!root.svc && root.svc.transcribing
                    diameter: Style.space(8)
                    SequentialAnimation on opacity {
                      running: !!root.svc && root.svc.recording
                      loops: Animation.Infinite
                      alwaysRunToEnd: true
                      NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                    }
                  }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)
                    Text {
                      Layout.fillWidth: true
                      text: root.svc && root.svc.recording ? "Recording" : "Transcribing on " + (root.svc ? root.svc.serverHost : "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                    }
                    Text {
                      Layout.fillWidth: true
                      text: root.svc ? root.svc.defaultSourceLabel : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                    }
                  }
                  Text {
                    visible: !!root.svc && root.svc.recording
                    text: root.svc ? Model.formatElapsed((root.nowMs - root.svc.recordingStartedAt) / 1000) : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                    textFormat: Text.PlainText
                  }
                }
              }

              RowLayout {
                visible: !!root.svc && !root.svc.busy
                width: parent.width
                spacing: Style.space(10)
                StatusDot {
                  Layout.leftMargin: Style.space(12)
                  dotColor: root.svc && root.svc.problem ? root.urgent : root.dim
                  hollow: true
                  diameter: Style.space(8)
                }
                Text {
                  Layout.fillWidth: true
                  text: !root.svc || !root.svc.daemonActive ? "Voxtype is off"
                    : root.svc.problem ? "Dictation will fail until " + (root.svc.serverHost || "the server") + " is back"
                    : "Idle · press your dictation key"
                  color: root.svc && root.svc.problem ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
              }

              // Last dictation (Enter or c copies).
              RowCard {
                rowIndex: root.homeLast
                titleText: "Last dictation"
                detailText: root.svc && root.svc.lastEntry
                  ? root.svc.lastEntry.text : (root.svc && !root.svc.historyEnabled ? "History is off" : "Nothing yet")
                detailLines: 2
                trailingText: root.svc && root.svc.lastEntry ? Model.formatTime(root.svc.lastEntry.time, root.nowMs) : ""
                tooltipText: "Enter copies"
                onActivated: root.activateCursor()
              }

              ValueRow {
                rowIndex: root.homeMic
                titleText: "Microphone"
                valueText: root.svc ? root.svc.defaultSourceLabel : ""
              }
              PickerList { forRow: root.homeMic }
              ValueRow {
                rowIndex: root.homeLanguage
                titleText: "Language"
                valueText: root.svc ? Model.languageName(root.svc.language) : ""
              }
              PickerList { forRow: root.homeLanguage }
              ValueRow {
                rowIndex: root.homeIndicator
                titleText: "Indicator"
                valueText: root.svc ? Model.indicatorName(root.svc.indicator) : ""
              }
              PickerList { forRow: root.homeIndicator }

              Column {
                width: parent.width
                spacing: Style.space(4)
                Ui.PanelSeparator { foreground: root.foreground }
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  FooterButton {
                    width: (parent.width - parent.spacing) / 2
                    rowIndex: root.homeAutoStart
                    iconText: "󰐥"
                    labelText: "Auto-start"
                    iconColor: root.svc && root.svc.autoStartEnabled ? root.accent : root.dim
                    labelColor: root.svc && root.svc.autoStartEnabled ? root.foreground : root.dim
                    enabled: !!root.svc && root.svc.autoStartKnown
                    tooltipText: root.svc && root.svc.autoStartEnabled
                      ? "Starts at login. Doesn't start or stop Voxtype now."
                      : "Doesn't start at login. Doesn't start or stop Voxtype now."
                    onActivated: root.activateCursor()
                  }
                  FooterButton {
                    width: (parent.width - parent.spacing) / 2
                    rowIndex: root.homeHistory
                    iconText: "󰋚"
                    labelText: "History"
                    tooltipText: "Past dictations"
                    onActivated: root.setSection(2)
                  }
                }
              }
            }

            // ================= Vocabulary =================
            Column {
              visible: root.section === 1
              width: parent.width
              spacing: Style.space(6)

              SectionLabel { text: "TERMS" }
              Note { text: "Spellings Whisper should prefer. They're sent with every dictation as a hint." }
              Repeater {
                model: root.section === 1 ? root.termList : []
                delegate: ListRow {
                  required property var modelData
                  required property int index
                  rowIndex: root.vocabTermBase + index
                  titleText: String(modelData)
                  confirming: root.confirmKey === "term:" + modelData
                  onActivated: root.askOrRemove("term:" + modelData)
                  onRemoveClicked: root.askOrRemove("term:" + modelData)
                }
              }
              EditorRow {
                id: addTermRow
                rowIndex: root.vocabAddTerm
                Ui.TextField {
                  id: addTermField
                  width: parent.width
                  placeholderText: "Add a term…"
                  foreground: root.foreground
                  hasCursor: root.has(root.vocabAddTerm)
                  font.family: root.fontFamily
                  onActiveFocusChanged: root.noteEditor(addTermField, activeFocus)
                  onAccepted: {
                    if (root.svc && root.svc.addTerm(text)) text = ""
                    root.leaveEditor()
                  }
                  Keys.onEscapePressed: { text = ""; root.leaveEditor() }
                }
              }

              Item { width: 1; height: Style.space(4) }
              SectionLabel { text: "REPLACEMENTS" }
              Note { text: "Fixed after transcription: what Whisper hears → what gets typed. Not case-sensitive." }
              Repeater {
                model: root.section === 1 ? root.replacementRows : []
                delegate: ListRow {
                  required property var modelData
                  required property int index
                  rowIndex: root.vocabRepBase + index
                  titleText: modelData.heard
                  arrowText: modelData.written
                  confirming: root.confirmKey === "rep:" + modelData.heard
                  onActivated: root.askOrRemove("rep:" + modelData.heard)
                  onRemoveClicked: root.askOrRemove("rep:" + modelData.heard)
                }
              }
              EditorRow {
                rowIndex: root.vocabAddRep
                RowLayout {
                  width: parent.width
                  spacing: Style.space(6)
                  Ui.TextField {
                    id: addHeardField
                    Layout.fillWidth: true
                    placeholderText: "Heard…"
                    foreground: root.foreground
                    hasCursor: root.has(root.vocabAddRep)
                    font.family: root.fontFamily
                    onActiveFocusChanged: root.noteEditor(addHeardField, activeFocus)
                    onAccepted: addWrittenField.forceActiveFocus()
                    KeyNavigation.tab: addWrittenField
                    Keys.onEscapePressed: { text = ""; addWrittenField.text = ""; root.leaveEditor() }
                  }
                  Text {
                    text: "→"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Ui.TextField {
                    id: addWrittenField
                    Layout.fillWidth: true
                    placeholderText: "Written…"
                    foreground: root.foreground
                    font.family: root.fontFamily
                    onActiveFocusChanged: root.noteEditor(addWrittenField, activeFocus)
                    onAccepted: {
                      if (root.svc && root.svc.addReplacement(addHeardField.text, text)) {
                        addHeardField.text = ""
                        text = ""
                      }
                      root.leaveEditor()
                    }
                    Keys.onEscapePressed: { text = ""; addHeardField.text = ""; root.leaveEditor() }
                  }
                }
              }
              Note { text: "Enter on a row asks to remove it; Enter again removes it. Changes restart Voxtype." }
            }

            // ================= History =================
            Column {
              visible: root.section === 2
              width: parent.width
              spacing: Style.space(6)

              Note {
                visible: !!root.svc && root.historyRows.length === 0
                text: root.svc && !root.svc.historyEnabled ? "History is off (Settings)."
                  : root.svc && !root.svc.hookInstalled ? "History needs the My Voxtype hook (Settings → History hook)."
                  : "No dictations yet."
              }
              Repeater {
                model: root.section === 2 ? root.historyRows : []
                delegate: RowCard {
                  required property var modelData
                  required property int index
                  rowIndex: root.histBase + index
                  titleText: Model.formatTime(modelData.time, root.nowMs)
                  trailingText: modelData.words + (modelData.words === 1 ? " word" : " words")
                  detailText: modelData.text
                  detailLines: 3
                  confirming: root.confirmKey === "hist:" + modelData.line
                  confirmText: "Press x again to delete"
                  tooltipText: "Enter or c copies · x deletes"
                  onActivated: root.svc.copyText(modelData.text)
                }
              }
              Column {
                visible: root.historyRows.length > 0
                width: parent.width
                spacing: Style.space(4)
                Ui.PanelSeparator { foreground: root.foreground }
                FooterButton {
                  width: parent.width
                  rowIndex: root.histClear
                  iconText: "󰩺"
                  labelText: root.confirmKey === "clear" ? "Press again to clear all" : "Clear all"
                  iconColor: root.confirmKey === "clear" ? root.urgent : root.dim
                  labelColor: root.confirmKey === "clear" ? root.urgent : root.foreground
                  tooltipText: "Deletes every saved dictation"
                  onActivated: root.askOrRemove("clear")
                }
              }
            }

            // ================= Stats =================
            Column {
              visible: root.section === 3
              width: parent.width
              spacing: Style.space(10)

              GridLayout {
                width: parent.width
                columns: 3
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)
                StatTile { label: "Today"; value: root.svc ? Model.formatCount(root.svc.stats.wordsToday) : "–"; unit: "words" }
                StatTile { label: "This week"; value: root.svc ? Model.formatCount(root.svc.stats.wordsWeek) : "–"; unit: "words" }
                StatTile { label: "All time"; value: root.svc ? Model.formatCount(root.svc.stats.wordsAll) : "–"; unit: "words" }
                StatTile { label: "Dictations"; value: root.svc ? Model.formatCount(root.svc.stats.dictations) : "–"; unit: "total" }
                StatTile {
                  label: "Speed"
                  value: root.svc && root.svc.stats.wpm > 0 ? String(root.svc.stats.wpm) : "–"
                  unit: "words/min"
                }
                StatTile {
                  label: "Response"
                  value: root.svc && root.svc.stats.medianLatencyMs >= 0
                    ? (root.svc.stats.medianLatencyMs / 1000).toFixed(2) : "–"
                  unit: "s, median"
                }
              }
              Note {
                text: "Speed and response time count dictations since My Voxtype started timing them"
                  + (root.svc && root.svc.stats.timed > 0 ? " (" + root.svc.stats.timed + " so far)." : ".")
                  + " Response is from the end of recording to the text being typed."
              }
            }

            // ================= Settings =================
            Column {
              visible: root.section === 4
              width: parent.width
              spacing: Style.space(6)

              ToggleRow {
                rowIndex: root.setHistory
                titleText: "Save history"
                detailText: "Keeps every dictation in ~/.local/share/voxtype/history.tsv"
                checked: !!root.svc && root.svc.historyEnabled
                onActivated: root.svc.setHistoryEnabled(!root.svc.historyEnabled)
              }
              ToggleRow {
                rowIndex: root.setEscape
                titleText: "Escape cancels"
                detailText: "Esc stops a recording without typing; apps still get Esc"
                checked: !!root.svc && root.svc.escapeCancels
                onActivated: root.svc.setEscapeCancels(!root.svc.escapeCancels)
              }
              ToggleRow {
                rowIndex: root.setPause
                titleText: "Pause media"
                detailText: "Pauses music and video while you dictate"
                checked: !!root.svc && root.svc.pauseMedia
                onActivated: root.svc.setPauseMedia(!root.svc.pauseMedia)
              }
              ValueRow {
                rowIndex: root.setEnter
                titleText: "Press Enter after typing"
                valueText: root.svc ? Model.autoSubmitName(root.svc.autoSubmit) : ""
              }
              PickerList { forRow: root.setEnter }
              EditorRow {
                rowIndex: root.setHold
                ColumnLayout {
                  width: parent.width
                  spacing: Style.space(4)
                  RowLayout {
                    Layout.fillWidth: true
                    Text {
                      Layout.fillWidth: true
                      text: "Hold-to-talk key"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                    }
                    Text {
                      text: root.svc && root.svc.holdKey !== "" ? root.svc.holdKey : "None"
                      color: root.svc && root.svc.holdKey !== "" ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      textFormat: Text.PlainText
                    }
                  }
                  Ui.TextField {
                    id: holdField
                    visible: activeFocus
                    Layout.fillWidth: true
                    placeholderText: "e.g. SUPER + F10, then Enter (empty = none)"
                    foreground: root.foreground
                    font.family: root.fontFamily
                    onActiveFocusChanged: {
                      if (activeFocus) text = root.svc ? root.svc.holdKey : ""
                      root.noteEditor(holdField, activeFocus)
                    }
                    onAccepted: {
                      if (root.svc && !root.svc.setHoldKey(text)) {
                        root.svc.error = "Not a key chord. Use e.g. SUPER + F10."
                        return
                      }
                      root.leaveEditor()
                    }
                    Keys.onEscapePressed: root.leaveEditor()
                  }
                  Text {
                    visible: !holdField.visible
                    Layout.fillWidth: true
                    text: "Press and hold to dictate. Enter sets it, x removes it."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }
                }
              }
              ValueRow {
                rowIndex: root.setMax
                titleText: "Longest recording"
                valueText: root.svc ? root.svc.maxDurationSecs + " s" : ""
              }
              PickerList { forRow: root.setMax }
              ValueRow {
                rowIndex: root.setTimeout
                titleText: "Server timeout"
                valueText: root.svc ? root.svc.remoteTimeoutSecs + " s" : ""
              }
              PickerList { forRow: root.setTimeout }
              RowCard {
                rowIndex: root.setHook
                titleText: "History hook"
                detailText: !root.svc ? ""
                  : root.svc.hookInstalled ? "Installed: joins lines, drops sound tags, saves history"
                  : "Not installed. Enter installs it (replaces: " + (root.svc.postProcessCommand || "none") + ")"
                detailLines: 2
                trailingText: root.svc && root.svc.hookInstalled ? "On" : "Install"
                onActivated: root.activateCursor()
              }
              RowCard {
                rowIndex: root.setConfig
                titleText: "Open config file"
                detailText: "~/.config/voxtype/config.toml"
                detailLines: 1
                trailingText: "󰏌"
                onActivated: root.svc.openConfig()
              }
            }
          }
        }

        // ---- Messages ----------------------------------------------------------
        Text {
          width: parent.width
          visible: !!root.svc && (root.svc.error !== "" || root.svc.actionMessage !== "")
          text: root.svc ? (root.svc.error || root.svc.actionMessage) : ""
          color: root.svc && root.svc.error !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }

        Text {
          width: parent.width
          text: root.picking ? "↑↓ choose · Enter pick · Esc back" : "↑↓ move · ←→ sections · Enter select · Esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }
      }
    }
  }

  // ---- Components ------------------------------------------------------------

  component SectionLabel: Text {
    width: parent ? parent.width : 0
    leftPadding: Style.space(10)
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    font.bold: true
    textFormat: Text.PlainText
  }

  component Note: Text {
    width: parent ? parent.width : 0
    leftPadding: Style.space(10)
    rightPadding: Style.space(10)
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
  }

  component StatusDot: Rectangle {
    property color dotColor: root.dim
    property bool hollow: false
    property int diameter: Style.space(7)
    implicitWidth: diameter
    implicitHeight: diameter
    radius: diameter / 2
    color: hollow ? "transparent" : dotColor
    border.width: hollow ? 1 : 0
    border.color: dotColor
    Layout.alignment: Qt.AlignVCenter
  }

  // A row with a title and a value that ←/→ (or Enter) changes.
  component ValueRow: Ui.CursorSurface {
    id: valueRow
    property int rowIndex: 0
    property string titleText: ""
    property string valueText: ""

    width: parent ? parent.width : 0
    implicitHeight: valueContent.implicitHeight + Style.space(8) * 2
    hasCursor: root.has(rowIndex)
    foreground: root.foreground
    Component.onCompleted: root.registerRow(rowIndex, valueRow)
    onRowIndexChanged: root.registerRow(rowIndex, valueRow)
    Accessible.role: Accessible.Button
    Accessible.name: titleText + ": " + valueText

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = valueRow.rowIndex }
      onClicked: {
        root.cursorIndex = valueRow.rowIndex
        if (root.pickerRow === valueRow.rowIndex) root.closePicker()
        else root.openPicker(valueRow.rowIndex)
      }
    }
    RowLayout {
      id: valueContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)
      Text {
        Layout.fillWidth: true
        text: valueRow.titleText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
      Text {
        Layout.maximumWidth: valueRow.width * 0.55
        text: valueRow.valueText
        color: valueRow.hasCursor ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
      Text {
        text: root.pickerRow === valueRow.rowIndex ? "󰅃" : "󰅀"
        color: valueRow.hasCursor ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // The options under a value row while its list is open. The current
  // value has a dot; the highlighted option follows the keys or the mouse.
  component PickerList: Column {
    id: pickerList
    property int forRow: -1
    readonly property bool open: root.pickerRow === forRow
    readonly property var options: open ? root.pickerOptions(forRow) : []
    readonly property string current: open ? String(root.pickerCurrent(forRow)) : ""
    visible: open
    width: parent ? parent.width : 0
    leftPadding: Style.space(10)
    spacing: Style.space(1)

    Repeater {
      model: pickerList.options
      delegate: Ui.CursorSurface {
        id: option
        required property var modelData
        required property int index
        readonly property bool isCurrent: String(modelData.value) === pickerList.current
        width: pickerList.width - pickerList.leftPadding
        implicitHeight: optionContent.implicitHeight + Style.space(5) * 2
        hasCursor: root.pickerIndex === index
        foreground: root.foreground
        Accessible.role: Accessible.RadioButton
        Accessible.name: modelData.label
        Accessible.checked: isCurrent

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.pickerIndex = option.index
          onClicked: root.choose(pickerList.forRow, option.modelData.value)
        }
        RowLayout {
          id: optionContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(8)
          StatusDot {
            dotColor: option.isCurrent ? root.accent : root.dim
            hollow: !option.isCurrent
            diameter: Style.space(7)
          }
          Text {
            Layout.fillWidth: true
            text: option.modelData.label
            color: option.isCurrent ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: option.isCurrent
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
        }
      }
    }
  }

  // Title + detail + optional trailing text; Enter activates.
  component RowCard: Ui.CursorSurface {
    id: card
    property int rowIndex: 0
    property string titleText: ""
    property string detailText: ""
    property int detailLines: 1
    property string trailingText: ""
    property string tooltipText: ""
    property bool confirming: false
    property string confirmText: ""
    signal activated()

    width: parent ? parent.width : 0
    implicitHeight: cardContent.implicitHeight + Style.space(8) * 2
    hasCursor: root.has(rowIndex)
    foreground: root.foreground
    Component.onCompleted: root.registerRow(rowIndex, card)
    onRowIndexChanged: root.registerRow(rowIndex, card)
    Accessible.role: Accessible.Button
    Accessible.name: titleText
    Accessible.description: detailText

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = card.rowIndex }
      onClicked: card.activated()
    }
    ColumnLayout {
      id: cardContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(3)
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Text {
          Layout.fillWidth: true
          text: card.titleText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Text {
          visible: text !== ""
          text: card.trailingText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }
      }
      Text {
        visible: text !== ""
        Layout.fillWidth: true
        text: card.detailText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: card.detailLines
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
      Text {
        visible: card.confirming
        Layout.fillWidth: true
        text: card.confirmText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }
    }
    Ui.PanelToolTip {
      visible: cardMouse.containsMouse && card.tooltipText !== ""
      text: card.tooltipText
      fontFamily: root.fontFamily
    }
  }

  // A vocabulary entry: text (→ replacement) and a remove button that asks first.
  component ListRow: Ui.CursorSurface {
    id: listRow
    property int rowIndex: 0
    property string titleText: ""
    property string arrowText: ""
    property bool confirming: false
    signal activated()
    signal removeClicked()

    width: parent ? parent.width : 0
    implicitHeight: listContent.implicitHeight + Style.space(6) * 2
    hasCursor: root.has(rowIndex)
    foreground: root.foreground
    Component.onCompleted: root.registerRow(rowIndex, listRow)
    onRowIndexChanged: root.registerRow(rowIndex, listRow)
    Accessible.role: Accessible.Button
    Accessible.name: arrowText !== "" ? titleText + " becomes " + arrowText : titleText

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: { root.cursorActive = true; root.cursorIndex = listRow.rowIndex }
    }
    RowLayout {
      id: listContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(6)
      Text {
        Layout.fillWidth: listRow.arrowText === ""
        Layout.maximumWidth: listRow.arrowText === "" ? -1 : listRow.width * 0.45
        text: listRow.titleText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
      Text {
        visible: listRow.arrowText !== ""
        text: "→"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        visible: listRow.arrowText !== ""
        Layout.fillWidth: true
        text: listRow.arrowText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
      Text {
        text: listRow.confirming ? "Remove?" : "󰆴"
        color: listRow.confirming ? root.urgent : (removeMouse.containsMouse || listRow.hasCursor ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: listRow.confirming ? Style.font.caption : Style.font.body
        font.bold: listRow.confirming
        MouseArea {
          id: removeMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: listRow.removeClicked()
        }
      }
    }
  }

  // Holds an inline editor; the row itself is the cursor target.
  component EditorRow: Ui.CursorSurface {
    id: editorRow
    property int rowIndex: 0
    default property alias content: editorBody.data

    width: parent ? parent.width : 0
    implicitHeight: editorBody.childrenRect.height + Style.space(6) * 2
    hasCursor: root.has(rowIndex) && !root.editing
    foreground: root.foreground
    Component.onCompleted: root.registerRow(rowIndex, editorRow)
    onRowIndexChanged: root.registerRow(rowIndex, editorRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: { root.cursorActive = true; root.cursorIndex = editorRow.rowIndex }
      onClicked: { root.cursorIndex = editorRow.rowIndex; root.activateCursor() }
    }
    Item {
      id: editorBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      height: childrenRect.height
    }
  }

  // Title + detail with a switch; Enter toggles.
  component ToggleRow: Ui.CursorSurface {
    id: toggleRow
    property int rowIndex: 0
    property string titleText: ""
    property string detailText: ""
    property bool checked: false
    signal activated()

    width: parent ? parent.width : 0
    implicitHeight: toggleContent.implicitHeight + Style.space(8) * 2
    hasCursor: root.has(rowIndex)
    foreground: root.foreground
    Component.onCompleted: root.registerRow(rowIndex, toggleRow)
    Accessible.role: Accessible.CheckBox
    Accessible.name: titleText
    Accessible.checked: checked

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = toggleRow.rowIndex }
      onClicked: toggleRow.activated()
    }
    RowLayout {
      id: toggleContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(8)
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)
        Text {
          Layout.fillWidth: true
          text: toggleRow.titleText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Text {
          Layout.fillWidth: true
          text: toggleRow.detailText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }
      }
      Ui.ToggleSwitch {
        checked: toggleRow.checked
        cursorRing: false
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: toggleRow.activated()
      }
    }
  }

  component StatTile: Rectangle {
    id: tile
    property string label: ""
    property string value: ""
    property string unit: ""
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    implicitHeight: tileContent.implicitHeight + Style.space(10) * 2
    color: root.cardFill
    border.width: 1
    border.color: root.hairline
    radius: Style.cornerRadius
    Column {
      id: tileContent
      anchors.centerIn: parent
      spacing: Style.space(2)
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.label.toUpperCase()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
        textFormat: Text.PlainText
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        textFormat: Text.PlainText
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.unit
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }
    }
  }

  // Footer action: an icon over a short label (as in My Sunshine).
  component FooterButton: Ui.CursorSurface {
    id: footerButton
    property string iconText: ""
    property string labelText: ""
    property color iconColor: root.dim
    property color labelColor: root.foreground
    property string tooltipText: ""
    property int rowIndex: 0
    signal activated()

    implicitHeight: footerColumn.implicitHeight + Style.space(8) * 2
    hasCursor: root.has(rowIndex)
    foreground: root.foreground
    opacity: enabled ? 1.0 : 0.5
    Component.onCompleted: root.registerRow(rowIndex, footerButton)
    onRowIndexChanged: root.registerRow(rowIndex, footerButton)
    Accessible.role: Accessible.Button
    Accessible.name: labelText
    Accessible.onPressAction: if (footerButton.enabled) footerButton.activated()

    MouseArea {
      id: footerMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: footerButton.enabled
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = footerButton.rowIndex }
      onClicked: footerButton.activated()
    }
    Column {
      id: footerColumn
      anchors.centerIn: parent
      spacing: Style.space(4)
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: footerButton.iconText
        color: footerButton.iconColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: footerButton.labelText
        color: footerButton.labelColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }
    }
    Ui.PanelToolTip {
      visible: footerMouse.containsMouse && footerButton.tooltipText !== ""
      text: footerButton.tooltipText
      fontFamily: root.fontFamily
    }
  }
}
