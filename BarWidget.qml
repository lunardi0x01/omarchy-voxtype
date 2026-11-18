pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons as Commons
import qs.Ui as Ui

// Microphone icon: dim when Voxtype is off, plain when ready, accent while
// recording (and pulsing while transcribing), urgent when the server can't
// be reached. Left click opens the panel; right click starts/stops Voxtype.
Ui.BarWidget {
  id: root
  moduleName: "lunardi0x01.voxtype"

  // Prefer a host-provided service; replacement bars get none, so the
  // widget then runs its own Service.qml (as My Sunshine does).
  readonly property var hostService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  property var ownService: null
  readonly property var service: hostService || ownService

  function ensureOwnService() {
    if (hostService || ownService) return
    var comp = Qt.createComponent(Qt.resolvedUrl("Service.qml"), Component.PreferSynchronous)
    if (comp.status !== Component.Ready) {
      console.warn("lunardi0x01.voxtype: Service.qml failed to load: " + comp.errorString())
      return
    }
    ownService = comp.createObject(root)
  }

  onHostServiceChanged: if (hostService && ownService) {
    ownService.destroy()
    ownService = null
  }
  Component.onCompleted: Qt.callLater(ensureOwnService)

  readonly property var panelAnchor: button
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property bool recording: !!service && service.recording === true
  readonly property bool transcribing: !!service && service.transcribing === true
  readonly property bool problem: !!service && service.problem === true

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
    target.service = root.service
  }

  function screenName() {
    var window = button.QsWindow.window
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  function openOnFocusedScreen() {
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; focused !== "" && i < peers.length; i++) {
      var peer = peers[i]
      if (peer && typeof peer.screenName === "function" && typeof peer.open === "function"
          && peer.screenName() === focused) {
        peer.open()
        return
      }
    }
    open()
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-microphone / microphone-outline / microphone-off
    text: !root.service || !root.service.daemonActive ? "󰍭"
      : root.recording || root.transcribing ? "󰍬" : "󰍮"
    keepSpace: false
    dimmed: !root.service || !root.service.statusKnown || !root.service.daemonActive
    active: root.recording || root.transcribing || root.problem
    activeColor: root.problem && !root.recording && !root.transcribing
      ? (root.bar ? root.bar.urgent : Commons.Color.urgent) : Commons.Color.accent
    tooltipText: root.service ? root.service.tooltipText : "Voxtype"
    Accessible.role: Accessible.Button
    Accessible.name: tooltipText
    Accessible.onPressAction: root.togglePanel()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.service) root.service.toggleDaemon()
      } else if (buttonCode === Qt.LeftButton) root.togglePanel()
    }

    SequentialAnimation on opacity {
      running: root.transcribing
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.45; duration: 500; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutSine }
    }
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onOpenPanelRequested() { root.openOnFocusedScreen() }
  }
}
