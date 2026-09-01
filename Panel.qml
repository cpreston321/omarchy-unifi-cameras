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

  // ------------------------------------------------------------ live view

  // The camera whose detail view is open, or null for the grid.
  property var selected: null
  readonly property bool detailOpen: selected !== null
  property string streamUrl: ""
  // "connecting" while the URL is being fetched or the player is opening,
  // "live" once frames arrive, "snapshots" when video is unavailable and the
  // view is refreshing stills instead.
  property string liveMode: "connecting"
  property string liveDetail: ""
  property int detailFrame: 0

  function openCamera(camera) {
    root.selected = camera
    root.streamUrl = ""
    root.liveMode = "connecting"
    root.liveDetail = ""
    root.detailFrame = 0
    detailShotProcess.command = [root.cli, "snapshot", camera.id]
    detailShotProcess.running = true
    if (camera.connected) {
      streamProcess.command = [root.cli, "stream-url", camera.id, root.quality]
      streamProcess.running = true
    } else {
      root.liveMode = "snapshots"
      root.liveDetail = "This camera is offline."
    }
  }

  function closeCamera() {
    root.selected = null
    root.streamUrl = ""
    root.liveMode = "connecting"
  }

  // Video failed, or was never available. Stills still tell you what the
  // camera sees, so the view degrades to them rather than to an error.
  function fallBackToSnapshots(reason) {
    if (root.liveMode === "live") return
    root.liveMode = "snapshots"
    root.liveDetail = String(reason || "")
  }

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

  property Process streamProcess: Process {
    onExited: function(exitCode) {
      if (!root.detailOpen) return
      if (exitCode !== 0) {
        root.fallBackToSnapshots(String(streamStderr.text || "").trim())
        return
      }
      var url = String(streamStdout.text || "").trim()
      if (url === "") { root.fallBackToSnapshots("The console returned no stream URL."); return }
      root.streamUrl = url
    }
    stdout: StdioCollector { id: streamStdout; waitForEnd: true }
    stderr: StdioCollector { id: streamStderr; waitForEnd: true }
  }

  // Single-camera stills, polled faster than the grid while a detail view is
  // open. Also the poster frame behind the video while it negotiates.
  property Process detailShotProcess: Process {
    onExited: function(exitCode) {
      if (exitCode === 0 && root.detailOpen) root.detailFrame += 1
    }
  }

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

  // Only runs while stills are actually the picture being shown; once video is
  // live it would be pure waste against the console.
  Timer {
    id: detailShotTimer
    interval: 1500
    repeat: true
    running: root.opened && root.detailOpen && root.liveMode !== "live"
      && root.selected !== null && root.selected.connected
    onTriggered: {
      if (detailShotProcess.running) return
      detailShotProcess.command = [root.cli, "snapshot", root.selected.id]
      detailShotProcess.running = true
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshSeconds * 1000
    repeat: true
    running: root.opened && root.ready && !root.detailOpen
    onTriggered: root.refreshAll()
  }

  // ------------------------------------------------------------- open / close

  function open() {
    root.controller.show()
    root.loadStatus()
  }

  function close() {
    root.closeCamera()
    root.controller.hide()
  }
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
    // Three sizes, because the panel shows three different things: a grid, one
    // 16:9 camera, or a short message. An empty state kept at grid height
    // reads as a broken panel rather than a deliberate one.
    contentHeight: panel.fittedContentHeight(
      !root.ready ? Style.space(280)
        : (root.detailOpen ? Style.space(430) : Style.space(520)))

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

        Button {
          visible: root.detailOpen
          iconText: "\uf060"
          tooltipText: "Back to all cameras"
          onClicked: root.closeCamera()
        }

        Label {
          text: root.detailOpen && root.selected ? root.selected.name : "UniFi Cameras"
          elide: Text.ElideRight
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        // Live badge doubles as the honest label for what is on screen: solid
        // when video is playing, hollow while stills stand in for it.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(5)
          visible: root.detailOpen

          Rectangle {
            Layout.preferredWidth: Style.space(6)
            Layout.preferredHeight: Style.space(6)
            radius: width / 2
            color: root.liveMode === "live" ? Color.accent : "transparent"
            border.width: root.liveMode === "live" ? 0 : 1
            border.color: root.contentForeground
            opacity: root.liveMode === "live" ? 1 : 0.4
          }

          Label {
            Layout.fillWidth: true
            text: root.liveMode === "live" ? "Live"
              : (root.liveMode === "connecting" ? "Connecting…" : "Snapshots")
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            opacity: 0.55
          }
        }

        Label {
          Layout.fillWidth: !root.detailOpen
          visible: !root.detailOpen
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
          visible: root.detailOpen
          iconText: "\udb81\udd1a"
          tooltipText: "Save a snapshot"
          enabled: root.selected !== null && root.selected.connected
          onClicked: root.saveSnapshot(root.selected.id)
        }

        Button {
          visible: root.detailOpen
          iconText: "\uf0aa"
          tooltipText: "Open in mpv"
          enabled: root.selected !== null && root.selected.connected
          onClicked: { root.play(root.selected.id, root.quality); root.close() }
        }

        Button {
          visible: !root.detailOpen
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
          visible: root.emptyState !== null && !root.detailOpen
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
        // ------------------------------------------------------ detail view

        ColumnLayout {
          anchors.fill: parent
          visible: root.detailOpen
          spacing: Style.space(8)

          Rectangle {
            id: stage
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.space(6)
            color: "#000000"
            clip: true

            readonly property string posterSource: root.selected
              ? "file://" + root.snapshotDir + "/" + root.selected.id + ".jpg"
              : ""

            // The still sits under the video and stays there: it is the poster
            // while the stream negotiates, and the picture itself when video
            // never arrives.
            Image {
              id: poster
              anchors.fill: parent
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
              source: stage.posterSource

              Connections {
                target: root
                function onDetailFrameChanged() {
                  poster.source = ""
                  poster.source = stage.posterSource
                }
                function onSelectedChanged() {
                  poster.source = ""
                  poster.source = stage.posterSource
                }
              }
            }

            // QtMultimedia may not be installed. A Loader keeps that a missing
            // feature instead of a broken panel — an error status simply means
            // the stills below are what the viewer gets.
            Loader {
              id: playerLoader
              anchors.fill: parent
              active: root.detailOpen && root.streamUrl !== ""
              source: Qt.resolvedUrl("LivePlayer.qml")
              visible: item !== null && item.playing

              onStatusChanged: {
                if (status === Loader.Error)
                  root.fallBackToSnapshots("Video playback is unavailable on this system.")
              }

              onLoaded: {
                item.url = Qt.binding(function() { return root.streamUrl })
                item.active = Qt.binding(function() { return root.detailOpen })
                item.failed.connect(function(message) { root.fallBackToSnapshots(message) })
              }
            }

            Connections {
              target: playerLoader.item
              ignoreUnknownSignals: true
              function onPlayingChanged() {
                if (playerLoader.item && playerLoader.item.playing) {
                  root.liveMode = "live"
                  root.liveDetail = ""
                }
              }
            }

            // Shown only when there is nothing to look at yet: no poster has
            // arrived and no video is playing.
            Label {
              anchors.centerIn: parent
              visible: poster.status !== Image.Ready && !(playerLoader.item && playerLoader.item.playing)
              text: root.liveMode === "connecting" ? "Connecting…" : "No picture"
              color: "#ffffff"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              opacity: 0.5
            }
          }

          Label {
            Layout.fillWidth: true
            visible: root.liveMode === "snapshots" && root.liveDetail !== ""
            text: root.liveDetail
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.45
          }
        }
        // ------------------------------------------------------- camera grid

        Flickable {
          anchors.fill: parent
          visible: root.ready && root.cameras.length > 0 && !root.detailOpen
          clip: true
          contentHeight: grid.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          GridLayout {
            id: grid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(8)

            Repeater {
              model: root.cameras

              delegate: Rectangle {
                id: card
                required property var modelData

                Layout.fillWidth: true
                // 16:9, the aspect every Protect camera actually records in —
                // so the thumbnail is the frame, not a crop of it.
                Layout.preferredHeight: Math.round(width * 9 / 16)
                radius: Style.space(6)
                color: "#000000"
                clip: true

                readonly property bool hot: cardHover.hovered
                readonly property string snapshotSource: "file://" + root.snapshotDir + "/" + card.modelData.id + ".jpg"

                Image {
                  id: shot
                  anchors.fill: parent
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: false
                  source: card.snapshotSource
                  opacity: card.modelData.connected ? 1 : 0.35

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
                  anchors.centerIn: parent
                  visible: shot.status !== Image.Ready
                  text: card.modelData.connected ? "No snapshot yet" : "Offline"
                  color: "#ffffff"
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  opacity: 0.45
                }

                // Play affordance on hover, so it is obvious the tile opens a
                // live view rather than just being a picture.
                Rectangle {
                  anchors.centerIn: parent
                  width: Style.space(38)
                  height: width
                  radius: width / 2
                  visible: card.hot && card.modelData.connected
                  color: Qt.rgba(0, 0, 0, 0.45)
                  border.width: 1
                  border.color: Qt.rgba(1, 1, 1, 0.7)

                  Label {
                    anchors.centerIn: parent
                    text: "\uf04b"
                    color: "#ffffff"
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                // A gradient rather than a bar: the name stays readable over a
                // bright frame without stamping a black block across it.
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Style.space(34)
                  gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.75) }
                  }

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(2)
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

                // Drawn last so the hover ring sits above the image and the
                // gradient rather than being covered by them.
                Rectangle {
                  anchors.fill: parent
                  radius: parent.radius
                  color: "transparent"
                  border.width: card.hot ? Math.max(1, Style.space(2)) : Style.normalBorderWidth
                  border.color: card.hot ? Color.accent : Style.normalBorderColor
                  opacity: card.hot ? 1 : 0.5
                }

                HoverHandler {
                  id: cardHover
                  cursorShape: card.modelData.connected ? Qt.PointingHandCursor : Qt.ArrowCursor
                }

                TapHandler {
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onSingleTapped: function(point, button) {
                    if (button === Qt.RightButton) root.saveSnapshot(card.modelData.id)
                    else root.openCamera(card.modelData)
                  }
                }
              }
            }
          }
        }
      }

      Label {
        Layout.fillWidth: true
        visible: root.ready && root.cameras.length > 0 && !root.detailOpen
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
