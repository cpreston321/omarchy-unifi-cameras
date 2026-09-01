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
  property bool configured: true
  property bool busy: false
  property string status: ""
  // Bumped after each refresh so every card reloads its JPEG. Image caches by
  // source URL and the filename never changes, so the reload has to be pushed.
  property int frame: 0

  readonly property string quality: String(setting("quality", "high"))
  readonly property int refreshSeconds: Math.max(5, Number(setting("refreshSeconds", 30)))

  function refreshAll() {
    if (root.busy) return
    root.busy = true
    root.status = "Refreshing…"
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
    root.status = "Saved to ~/Pictures/UniFi"
  }

  // ---------------------------------------------------------------- processes

  property Process listProcess: Process {
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // A missing config is the expected first-run state, not an error worth
        // shouting about — the panel offers setup instead.
        root.configured = false
        root.cameras = []
        root.status = String(listStderr.text || "").trim()
        return
      }
      root.configured = true
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
        root.status = rows.length === 0 ? "No cameras on this console" : ""
      } catch (error) {
        root.status = "Could not read the camera list"
      }
    }
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
  }

  property Process refreshProcess: Process {
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) {
        root.status = String(refreshStderr.text || "Refresh failed").trim()
        return
      }
      root.status = ""
      root.frame += 1
      root.loadCameras()
    }
    stderr: StdioCollector { id: refreshStderr; waitForEnd: true }
  }

  property Process playProcess: Process {}
  property Process exportProcess: Process {}

  property Process setupProcess: Process {}
  function openSetup() {
    setupProcess.command = ["omarchy-launch-terminal", root.cli, "setup"]
    setupProcess.running = true
    root.close()
  }

  // ------------------------------------------------------------------ timers

  Timer {
    id: pollTimer
    interval: root.refreshSeconds * 1000
    repeat: true
    running: root.opened && root.configured
    onTriggered: root.refreshAll()
  }

  // ------------------------------------------------------------- open / close

  function open() {
    root.controller.show()
    root.loadCameras()
    root.refreshAll()
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
    contentHeight: panel.fittedContentHeight(Style.space(520))

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
          Layout.fillWidth: true
        }

        Button {
          iconText: ""
          tooltipText: "Refresh"
          enabled: root.configured && !root.busy
          onClicked: root.refreshAll()
        }
      }

      // First-run and error state share one line; both are resolved the same
      // way, by opening setup in a terminal.
      Label {
        Layout.fillWidth: true
        visible: root.status !== ""
        text: root.status
        wrapMode: Text.WordWrap
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        opacity: 0.7
      }

      Button {
        visible: !root.configured
        text: "Connect a console…"
        onClicked: root.openSetup()
      }

      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.configured
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

      Label {
        Layout.fillWidth: true
        visible: root.configured && root.cameras.length > 0
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
