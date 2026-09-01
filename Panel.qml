pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Camera grid for a UniFi Protect console. Every network call goes through
// bin/unifi-protect: the panel reads JPEGs off the snapshot cache and parses
// JSON that the CLI already fetched, so no credential and no HTTP handling
// lives in QML.
Panel {
  id: root
  moduleName: "quantumfire.unifi-cameras"
  ipcTarget: "unifi-cameras"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------------ paths

  function localPath(relative) {
    return String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, "")
  }
  readonly property string cli: localPath("bin/unifi-protect")
  readonly property string cacheHome: {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    return (xdg && xdg !== "") ? xdg : Quickshell.env("HOME") + "/.cache"
  }
  readonly property string snapshotDir: cacheHome + "/omarchy-unifi/snapshots"

  // ------------------------------------------------------------------ state

  property var cameras: []
  // One of: loading, no-console, bad-config, no-key, bad-key, unreachable, ready.
  // Sourced from `unifi-protect status`, so the panel never infers setup state
  // by matching on error text.
  property string setupState: "loading"
  property string consoleHost: ""
  property string detail: ""
  property bool busy: false
  // Short-lived confirmation, unrelated to setup state.
  property string toast: ""
  readonly property bool ready: setupState === "ready"
  // Bumped after each refresh so every card reloads its JPEG. Image caches by
  // source URL and the filename never changes, so the reload has to be pushed.
  property int frame: 0

  readonly property string quality: String(setting("quality", "high"))
  readonly property int refreshSeconds: Math.max(5, Number(setting("refreshSeconds", 30)))

  // Copy for each non-ready state. Kept in one place so the headline, the
  // explanation, and the button always describe the same problem — the panel
  // previously offered "Connect a console…" when a console was already
  // connected and only the key was missing.
  readonly property var emptyStates: ({
    "loading":     { title: "Checking…",              body: "",  action: "",                 command: [] },
    "no-console":  { title: "No console connected",   body: "Connect a UniFi Protect console to see your cameras.",
                     action: "Connect a console…",    command: ["setup"] },
    "bad-config":  { title: "Console settings unreadable", body: "The saved settings could not be read. Reconnecting rewrites them.",
                     action: "Reconnect…",            command: ["setup"] },
    "no-key":      { title: "API key needed",         body: "Create an API key on the console under Control Plane → Integrations, then add it here.",
                     action: "Add API key…",          command: ["key-set"] },
    "bad-key":     { title: "Stored key looks wrong", body: "The key in your keyring is not in the format Protect issues.",
                     action: "Replace key…",          command: ["key-set"] },
    "unreachable": { title: "Can't reach the console", body: "The console did not answer. It may be rebooting, or the pinned certificate may have changed.",
                     action: "Reconnect…",            command: ["setup"] },
    "no-cameras":  { title: "No cameras",             body: "This console has no cameras adopted.",
                     action: "",                      command: [] }
  })

  readonly property var emptyState: {
    var key = root.ready ? (root.cameras.length === 0 ? "no-cameras" : "") : root.setupState
    return key === "" ? null : (root.emptyStates[key] || root.emptyStates["unreachable"])
  }

  function loadStatus() {
    statusProcess.command = [root.cli, "status"]
    statusProcess.running = true
  }

  function refreshAll() {
    if (root.busy || !root.ready) return
    root.busy = true
    refreshProcess.command = [root.cli, "refresh"]
    refreshProcess.running = true
  }

  function loadCameras() {
    listProcess.command = [root.cli, "cameras", "--json"]
    listProcess.running = true
  }

  function play(id, quality) {
    playProcess.command = [root.cli, "play", id, quality || "high"]
    playProcess.running = true
  }

  function saveSnapshot(id) {
    exportProcess.command = [root.cli, "export", id]
    exportProcess.running = true
    root.toast = "Saved to ~/Pictures/UniFi"
    toastTimer.restart()
  }

  // ---------------------------------------------------------------- processes

  property Process statusProcess: Process {
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.setupState = "unreachable"; return }
      try {
        var parsed = JSON.parse(String(statusStdout.text || "{}"))
        root.consoleHost = String(parsed.host || "")
        root.detail = String(parsed.detail || "")
        root.setupState = String(parsed.state || "unreachable")
      } catch (error) {
        root.setupState = "unreachable"
        root.detail = "The status command returned something unreadable."
      }
      if (root.setupState === "ready") { root.loadCameras(); root.refreshAll() }
      else root.cameras = []
    }
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
  }

  property Process listProcess: Process {
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // `status` already cleared setup problems, so a failure here means the
        // console itself did not answer.
        root.setupState = "unreachable"
        root.detail = String(listStderr.text || "").trim()
        root.cameras = []
        return
      }
      try {
        var parsed = JSON.parse(String(listStdout.text || "[]"))
        var rows = []
        for (var i = 0; i < parsed.length; i++) {
          var entry = parsed[i]
          if (!entry || !entry.id) continue
          rows.push({
            id: String(entry.id),
            name: String(entry.name || "Camera"),
            connected: String(entry.state || "") === "CONNECTED"
          })
        }
        rows.sort(function(a, b) { return a.name.localeCompare(b.name) })
        root.cameras = rows
      } catch (error) {
        root.setupState = "unreachable"
        root.detail = "Could not read the camera list."
      }
    }
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
  }

  property Process refreshProcess: Process {
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) {
        root.setupState = "unreachable"
        root.detail = String(refreshStderr.text || "").trim()
        return
      }
      root.frame += 1
      root.loadCameras()
    }
    stderr: StdioCollector { id: refreshStderr; waitForEnd: true }
  }

  property Process playProcess: Process {}
  property Process exportProcess: Process {}

  property Process setupProcess: Process {}
  // Setup and key entry both need a terminal: they prompt, and one of them
  // reads a secret that must not pass through the panel.
  function runSetupAction(subcommand) {
    if (!subcommand || subcommand.length === 0) return
    setupProcess.command = ["omarchy-launch-terminal", root.cli].concat(subcommand)
    setupProcess.running = true
    root.close()
  }

  // ------------------------------------------------------------------ timers

  Timer {
    id: toastTimer
    interval: 2500
    onTriggered: root.toast = ""
  }

  Timer {
    id: pollTimer
    interval: root.refreshSeconds * 1000
    repeat: true
    running: root.opened && root.ready
    onTriggered: root.refreshAll()
  }

  // ------------------------------------------------------------- open / close

  function open() {
    root.controller.show()
    root.loadStatus()
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ----------------------------------------------------------------- surface

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(620))
    // An empty state needs a fraction of the grid's height. Keeping the full
    // 520 leaves it marooned in dead space, which reads as a broken panel
    // rather than a deliberate message.
    contentHeight: panel.fittedContentHeight(root.ready ? Style.space(520) : Style.space(280))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      spacing: Style.space(10)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Label {
          text: "UniFi Cameras"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Label {
          Layout.fillWidth: true
          text: root.consoleHost
          elide: Text.ElideRight
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          opacity: 0.45
        }

        Label {
          visible: root.toast !== ""
          text: root.toast
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          opacity: 0.7
        }

        Button {
          iconText: "\uf021"
          tooltipText: "Refresh"
          enabled: root.ready && !root.busy
          iconSpinning: root.busy
          onClicked: root.refreshAll()
        }
      }

      // Everything below the header shares one flexible row. Without it the
      // column has nothing that grows, and QGridLayoutEngine spreads the
      // leftover height evenly across the rows instead — which is what left
      // the unconfigured panel with its three lines floating far apart.
      Item {
        id: body
        Layout.fillWidth: true
        Layout.fillHeight: true

        // ------------------------------------------------------- empty state

        ColumnLayout {
          visible: root.emptyState !== null
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(32), Style.space(320))
          spacing: Style.space(8)

          Label {
            Layout.alignment: Qt.AlignHCenter
            text: "\udb81\udfae"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.displayLarge
            color: root.contentForeground
            opacity: 0.25
          }

          Label {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(4)
            text: root.emptyState ? root.emptyState.title : ""
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Label {
            Layout.fillWidth: true
            visible: text !== ""
            text: root.emptyState ? root.emptyState.body : ""
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            lineHeight: 1.25
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            opacity: 0.65
          }

          Button {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(6)
            visible: root.emptyState !== null && root.emptyState.action !== ""
            bordered: true
            text: root.emptyState ? root.emptyState.action : ""
            onClicked: root.runSetupAction(root.emptyState ? root.emptyState.command : [])
          }

          // The console's own words, kept small and last. Useful when a
          // certificate pin or a network fault is the real cause, but never
          // the headline — that is what the sentences above are for.
          Label {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(4)
            visible: root.setupState === "unreachable" && root.detail !== ""
            text: root.detail
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 3
            elide: Text.ElideRight
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.4
          }
        }

        // ----------------------------------------------------- camera grid

        Flickable {
            anchors.fill: parent
            visible: root.ready && root.cameras.length > 0
            clip: true
          contentHeight: grid.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          GridLayout {
            id: grid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(10)
            rowSpacing: Style.space(10)

            Repeater {
              model: root.cameras

              delegate: Rectangle {
                id: card
                required property var modelData

                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(150)
                radius: Style.space(6)
                color: Style.normalFill
                border.width: Style.normalBorderWidth
                border.color: cardHover.hovered ? Style.hoverBorderColor : Style.normalBorderColor

                readonly property string snapshotSource: "file://" + root.snapshotDir + "/" + card.modelData.id + ".jpg"

                Image {
                  id: shot
                  anchors.fill: parent
                  anchors.margins: Style.space(1)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: false
                  source: card.snapshotSource
                  opacity: status === Image.Ready ? 1 : 0

                  Connections {
                    target: root
                    function onFrameChanged() {
                      // Clearing first is what actually forces a re-read; the
                      // filename is stable, so re-assigning alone is a no-op.
                      shot.source = ""
                      shot.source = card.snapshotSource
                    }
                  }
                }

                Label {
                  visible: shot.status !== Image.Ready
                  anchors.centerIn: parent
                  text: card.modelData.connected ? "No snapshot yet" : "Offline"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  opacity: 0.6
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(1)
                  height: Style.space(26)
                  color: Qt.rgba(0, 0, 0, 0.55)

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(6)

                    Rectangle {
                      Layout.preferredWidth: Style.space(6)
                      Layout.preferredHeight: Style.space(6)
                      radius: width / 2
                      color: card.modelData.connected ? Color.accent : Color.urgent
                    }

                    Label {
                      Layout.fillWidth: true
                      text: card.modelData.name
                      elide: Text.ElideRight
                      color: "#ffffff"
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }

                HoverHandler { id: cardHover }

                TapHandler {
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onSingleTapped: function(point, button) {
                    if (button === Qt.RightButton) root.saveSnapshot(card.modelData.id)
                    else { root.play(card.modelData.id, root.quality); root.close() }
                  }
                }
              }
            }
          }
        }
      }

      Label {
        Layout.fillWidth: true
        visible: root.ready && root.cameras.length > 0
        text: "Click to watch · Right-click to save a snapshot"
        horizontalAlignment: Text.AlignHCenter
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        opacity: 0.5
      }
    }
  }
}
