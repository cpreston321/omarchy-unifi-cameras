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
  readonly property string logoPath: cacheHome + "/omarchy-unifi/logo.svg"

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
  // The in-panel view is a few hundred pixels wide, so it defaults to the
  // medium substream rather than making the console push 4K into a thumbnail.
  readonly property string panelQuality: String(setting("panelQuality", "medium"))
  readonly property int refreshSeconds: Math.max(5, Number(setting("refreshSeconds", 30)))

  // ------------------------------------------------------------ live view

  // Selection is held by id: the camera list is replaced wholesale on every
  // refresh, so an index or an object reference would quietly point at a
  // different camera the moment one is added or renamed.
  property string selectedId: ""
  readonly property var selected: {
    for (var i = 0; i < root.cameras.length; i++)
      if (root.cameras[i].id === root.selectedId) return root.cameras[i]
    return root.cameras.length > 0 ? root.cameras[0] : null
  }
  readonly property int onlineCount: {
    var n = 0
    for (var i = 0; i < root.cameras.length; i++) if (root.cameras[i].connected) n += 1
    return n
  }
  property bool wantLive: false
  property string streamUrl: ""
  // Ticks so the snapshot age re-reads the clock; `shotAt` alone would leave
  // the badge reading "just now" indefinitely.
  property int ageTick: 0

  readonly property string shotAge: {
    root.ageTick
    if (!root.shotAt) return "—"
    var seconds = Math.max(0, Math.round((Date.now() - root.shotAt.getTime()) / 1000))
    if (seconds < 10) return "just now"
    if (seconds < 60) return seconds + "s ago"
    return Math.round(seconds / 60) + "m ago"
  }

  readonly property var detailRows: {
    var camera = root.selected
    if (!camera) return []
    var rows = [
      { label: "Model", value: camera.model },
      { label: "State", value: camera.connected ? "Connected" : "Disconnected" },
      { label: "Microphone", value: camera.mic ? "On" : "Off" }
    ]
    if (camera.hdr !== "") rows.push({ label: "HDR", value: camera.hdr })
    if (camera.smart !== "") rows.push({ label: "Smart detection", value: camera.smart })
    return rows
  }
  // "connecting" while the URL is being fetched or the player is opening,
  // "live" once frames arrive, "snapshots" when stills are what is on screen.
  // Stills are the resting state: live video only starts on a deliberate
  // press, so anything else would claim a connection that was never attempted.
  property string liveMode: "snapshots"
  property string liveDetail: ""
  property int detailFrame: 0
  property var shotAt: null

  function selectCamera(camera) {
    if (!camera) return
    if (root.wantLive) root.stopLive()
    root.selectedId = camera.id
    root.wantLive = false
    root.streamUrl = ""
    root.liveMode = "connecting"
    root.liveDetail = ""
    root.liveMode = "snapshots"
    root.liveDetail = camera.connected ? "" : "This camera is offline."
    root.refreshSelected()
  }

  property bool settingsOpen: false

  // ------------------------------------------------------------ in-panel setup
  //
  // Setup runs here rather than in a terminal. The API key reaches the CLI
  // through the process's stdin, so it is never an argument, never in the
  // environment, and never written to a file on the way.
  property string setupPhase: ""      // "", "scanning", "choose", "saving"
  property var scanResults: []
  property string setupError: ""

  function startScan() {
    root.setupPhase = "scanning"
    root.setupError = ""
    root.scanResults = []
    scanProcess.command = [root.cli, "scan"]
    scanProcess.running = true
  }

  function useHost(host) {
    if (!host) return
    root.setupPhase = "saving"
    root.setupError = ""
    pinProcess.command = [root.cli, "pin", String(host)]
    pinProcess.running = true
  }

  function saveKey(key) {
    if (!key) return
    root.setupPhase = "saving"
    root.setupError = ""
    keyProcess.running = true
    // Written, then the writer is closed so `read` sees EOF rather than
    // blocking. The field is cleared by the caller the moment this returns.
    keyProcess.write(key + "\n")
  }

  // Rows are derived from the camera the console reports, so the switches show
  // what is actually set rather than what was last pressed.
  readonly property var settingRows: {
    var camera = root.selected
    if (!camera) return []
    var rows = [
      { key: "led",      label: "Status LED",      on: camera.led },
      { key: "osd-date", label: "Timestamp overlay", on: camera.osdDate },
      { key: "osd-name", label: "Name overlay",    on: camera.osdName },
      { key: "osd-logo", label: "Logo overlay",    on: camera.osdLogo }
    ]
    var supported = camera.detectSupported || []
    for (var i = 0; i < supported.length; i++) {
      var kind = String(supported[i])
      rows.push({
        key: "detect-" + kind,
        label: "Detect " + kind.replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase(),
        on: (camera.detectEnabled || []).indexOf(kind) >= 0
      })
    }
    return rows
  }

  property string pendingSetting: ""

  // The switch is not moved optimistically: the console is the authority on
  // whether a setting took, so the camera list is re-read and the row follows
  // whatever came back.
  function applySetting(key, enabled) {
    if (!root.selected || root.pendingSetting !== "") return
    root.pendingSetting = key
    settingProcess.command = [root.cli, "toggle", root.selected.id, key, enabled ? "on" : "off"]
    settingProcess.running = true
  }

  function refreshSelected() {
    if (!root.selected || detailShotProcess.running) return
    detailShotProcess.command = [root.cli, "snapshot", root.selected.id]
    detailShotProcess.running = true
  }

  // Live video is opt-in per camera. Starting a stream makes the console
  // transcode, so it waits for a deliberate press rather than firing whenever
  // a camera is selected.
  function startLive() {
    if (!root.selected || !root.selected.connected) return
    root.wantLive = true
    root.liveMode = "connecting"
    root.liveDetail = ""
    root.streamUrl = ""
    relayProcess.running = false
    relayProcess.command = [root.cli, "relay", root.selected.id, root.panelQuality]
    relayProcess.running = true
  }

  // The relay holds an ffmpeg process and a listening socket, so it is stopped
  // explicitly rather than left to time out whenever live view ends — leaving
  // the panel, switching camera, or closing the popup.
  function stopLive() {
    root.wantLive = false
    root.streamUrl = ""
    root.liveMode = "snapshots"
    root.liveDetail = ""
    relayProcess.running = false
    root.refreshSelected()
  }

  // Video failed, or was never available. Stills still tell you what the
  // camera sees, so the view degrades to them rather than to an error.
  // Video failed, or was never available. The request to watch this camera
  // stands — stills just refresh in video's place, a second apart — so
  // wantLive is deliberately left set.
  // Qt reports the certificate rejection as "Could not open file", which sends
  // anyone reading it looking for a missing path. The cause is known and the
  // remedy is one button away, so say that instead of relaying its words.
  function videoUnavailable() {
    if (root.liveMode === "live") return
    root.liveMode = "snapshots"
    root.liveDetail = "Live video could not be decoded here. Showing stills — "
      + "use Open in mpv for full video."
    relayProcess.running = false
    root.refreshSelected()
  }

  function fallBackToSnapshots(reason) {
    if (root.liveMode === "live") return
    root.liveMode = "snapshots"
    root.liveDetail = root.humanize(reason)
    relayProcess.running = false
    root.refreshSelected()
  }

  // The CLI prefixes every error with its own name, which belongs in a
  // terminal and reads as noise in a panel.
  function humanize(message) {
    var text = String(message || "").trim()
    return text.replace(/^unifi-protect:\s*/, "")
  }

  // Copy for each non-ready state. Kept in one place so the headline, the
  // explanation, and the button always describe the same problem — the panel
  // previously offered "Connect a console…" when a console was already
  // connected and only the key was missing.
  readonly property var emptyStates: ({
    "loading":     { title: "Checking…",              body: "" },
    "no-console":  { title: "No console connected",
                     body: "Search this network for a UniFi Protect console, or enter its address." },
    "bad-config":  { title: "Console settings unreadable",
                     body: "The saved settings could not be read. Connecting again rewrites them." },
    "no-key":      { title: "API key needed",
                     body: "Create one on the console under Control Plane → Integrations, then paste it here." },
    "bad-key":     { title: "Stored key looks wrong",
                     body: "The key in your keyring is not in the format Protect issues. Paste a new one." },
    "unreachable": { title: "Can't reach the console",
                     body: "It did not answer. It may be rebooting, or its certificate may have changed." },
    "no-cameras":  { title: "No cameras",             body: "This console has no cameras adopted." }
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
        root.detail = root.humanize(listStderr.text)
        root.cameras = []
        return
      }
      try {
        var parsed = JSON.parse(String(listStdout.text || "[]"))
        var rows = []
        for (var i = 0; i < parsed.length; i++) {
          var entry = parsed[i]
          if (!entry || !entry.id) continue
          var smart = entry.smartDetectSettings && entry.smartDetectSettings.objectTypes
            ? entry.smartDetectSettings.objectTypes : []
          var osd = entry.osdSettings || {}
          var led = entry.ledSettings || {}
          var flags = entry.featureFlags || {}
          rows.push({
            id: String(entry.id),
            name: String(entry.name || "Camera").substring(0, 64),
            connected: String(entry.state || "") === "CONNECTED",
            model: String(entry.type || "Camera").substring(0, 64),
            mic: entry.isMicEnabled === true,
            hdr: String(entry.hdrType || ""),
            smart: smart.map(function(kind) { return String(kind).substring(0, 32) })
              .slice(0, 16).join(", "),
            osdName: osd.isNameEnabled === true,
            osdDate: osd.isDateEnabled === true,
            osdLogo: osd.isLogoEnabled === true,
            led: led.isEnabled === true,
            detectSupported: Array.isArray(flags.smartDetectTypes) ? flags.smartDetectTypes : [],
            detectEnabled: smart
          })
        }
        rows.sort(function(a, b) { return a.name.localeCompare(b.name) })
        root.cameras = rows
        if (!root.shotAt) root.refreshSelected()
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
        root.detail = root.humanize(refreshStderr.text)
        return
      }
      root.frame += 1
      root.loadCameras()
    }
    stderr: StdioCollector { id: refreshStderr; waitForEnd: true }
  }

  property Process scanProcess: Process {
    onExited: function(exitCode) {
      var found = String(scanStdout.text || "").trim()
      root.scanResults = found === "" ? [] : found.split("\n")
      root.setupPhase = "choose"
      if (exitCode !== 0) root.setupError = root.humanize(scanStderr.text)
    }
    stdout: StdioCollector { id: scanStdout; waitForEnd: true }
    stderr: StdioCollector { id: scanStderr; waitForEnd: true }
  }

  property Process pinProcess: Process {
    onExited: function(exitCode) {
      root.setupPhase = ""
      if (exitCode !== 0) {
        root.setupError = root.humanize(pinStderr.text)
        return
      }
      root.loadStatus()
    }
    stderr: StdioCollector { id: pinStderr; waitForEnd: true }
  }

  property Process keyProcess: Process {
    command: [root.cli, "key-set"]
    stdinEnabled: true
    onExited: function(exitCode) {
      root.setupPhase = ""
      if (exitCode !== 0) {
        root.setupError = root.humanize(keyStderr.text)
        return
      }
      root.loadStatus()
    }
    stderr: StdioCollector { id: keyStderr; waitForEnd: true }
  }

  property Process settingProcess: Process {
    onExited: function(exitCode) {
      root.pendingSetting = ""
      if (exitCode !== 0) {
        root.toast = "Could not change that setting"
        toastTimer.restart()
      }
      root.loadCameras()
    }
  }

  property Process playProcess: Process {}
  property Process exportProcess: Process {}

  property Process relayProcess: Process {
    onExited: function(exitCode) {
      if (!root.wantLive) return
      // A relay that dies while live view is wanted means no video; the
      // request itself stands, so stills take over in its place.
      root.fallBackToSnapshots(relayStderr.text)
    }
    stdout: StdioCollector {
      id: relayStdout
      waitForEnd: false
      onTextChanged: {
        if (!root.wantLive) return
        var line = String(relayStdout.text || "").trim().split("\n")[0]
        if (line.indexOf("http://") === 0) root.streamUrl = line
      }
    }
    stderr: StdioCollector { id: relayStderr; waitForEnd: true }
  }

  // Single-camera stills, polled faster than the grid while a detail view is
  // open. Also the poster frame behind the video while it negotiates.
  property Process detailShotProcess: Process {
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      root.detailFrame += 1
      root.shotAt = new Date()
    }
  }


  // ------------------------------------------------------------------ timers

  Timer {
    id: ageTimer
    interval: 5000
    repeat: true
    running: root.opened && root.ready
    onTriggered: root.ageTick += 1
  }

  Timer {
    id: toastTimer
    interval: 2500
    onTriggered: root.toast = ""
  }

  // Only runs while stills are actually the picture being shown; once video is
  // live it would be pure waste against the console.
  Timer {
    id: detailShotTimer
    // Live means as fast as the console will answer; otherwise this is just
    // keeping the poster from going stale while the panel sits open.
    interval: root.wantLive ? 1000 : 15000
    repeat: true
    running: root.opened && root.ready && root.liveMode !== "live"
      && root.selected !== null && root.selected.connected
    onTriggered: root.refreshSelected()
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

  function close() {
    root.stopLive()
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
    contentWidth: panel.fittedContentWidth(Style.space(460))
    // Measured, not guessed. A fixed height leaves dead space under a console
    // with one camera and clips one with several, and the difference between
    // the setup message and a full camera view is most of the panel.
    contentHeight: panel.fittedContentHeight(
      root.ready ? cameraView.implicitHeight : Style.space(300))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: cameraMenu.opened
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    // ----------------------------------------------------------- empty state

    ColumnLayout {
      visible: !root.ready
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(32), Style.space(320))
      spacing: Style.space(8)

      Label {

        textFormat: Text.PlainText
        Layout.alignment: Qt.AlignHCenter
        text: "\udb81\udfae"
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.displayLarge
        color: root.contentForeground
        opacity: 0.25
      }

      Label {

        textFormat: Text.PlainText
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

        textFormat: Text.PlainText
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

      // ---- console discovery -------------------------------------
      //
      // Everything setup needs happens here. Handing off to a terminal meant
      // the widget could not finish its own first run.

      Button {
        Layout.alignment: Qt.AlignHCenter
        Layout.topMargin: Style.space(6)
        visible: root.needsConsole && root.setupPhase === ""
        bordered: true
        text: "Find my console"
        onClicked: root.startScan()
      }

      Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(6)
        visible: root.setupPhase === "scanning"
        textFormat: Text.PlainText
        text: "Searching this network…"
        horizontalAlignment: Text.AlignHCenter
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        opacity: 0.6
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        spacing: Style.space(4)
        visible: root.needsConsole && root.setupPhase === "choose"

        Repeater {
          model: root.scanResults

          delegate: Button {
            required property var modelData
            Layout.fillWidth: true
            bordered: true
            text: String(modelData)
            onClicked: root.useHost(modelData)
          }
        }

        Label {
          Layout.fillWidth: true
          visible: root.scanResults.length === 0
          textFormat: Text.PlainText
          text: "No console answered. Enter its address below."
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          opacity: 0.6
        }
      }

      // Always offered: a scan cannot reach a console on another subnet.
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        spacing: Style.space(6)
        visible: root.needsConsole && root.setupPhase !== "scanning"

        TextField {
          id: hostField
          Layout.fillWidth: true
          placeholderText: "Console address"
          onAccepted: root.useHost(text.trim())
        }

        Button {
          bordered: true
          text: "Connect"
          enabled: hostField.text.trim() !== ""
          onClicked: root.useHost(hostField.text.trim())
        }
      }

      // ---- API key -------------------------------------------------

      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(6)
        spacing: Style.space(6)
        visible: root.needsKey && root.setupPhase !== "saving"

        TextField {
          id: keyField
          Layout.fillWidth: true
          password: true
          placeholderText: "Paste the API key"
          onAccepted: { root.saveKey(text); text = "" }
        }

        Button {
          bordered: true
          text: "Save"
          enabled: keyField.text !== ""
          // Cleared immediately: the field is the only place the key sits in
          // this process, and it reaches the CLI over stdin.
          onClicked: { root.saveKey(keyField.text); keyField.text = "" }
        }
      }

      Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        visible: root.setupPhase === "saving"
        textFormat: Text.PlainText
        text: "Saving…"
        horizontalAlignment: Text.AlignHCenter
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        opacity: 0.6
      }

      Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        visible: root.setupError !== ""
        textFormat: Text.PlainText
        text: root.setupError
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
        color: Color.urgent
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }

      // The console's own words, kept small and last. Useful when a
      // certificate pin or a network fault is the real cause, but never the
      // headline — that is what the sentences above are for.
      Label {
        textFormat: Text.PlainText
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

    // --------------------------------------------------------------- camera

    // The panel is sized to its content but capped to the screen, so on a
    // short display — or with settings expanded and several cameras — the
    // content can exceed the card. Without this it would simply clip, with no
    // way to reach the rest.
    Flickable {
      anchors.fill: parent
      visible: root.ready
      contentWidth: width
      contentHeight: cameraView.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      // No margins of its own: KeyboardPanel already insets its content by
      // Style.spacing.popupPadding, so anything added here is padding on top
      // of padding — which is what made the panel look over-inset.
      ColumnLayout {
        id: cameraView
        width: parent.width
        spacing: 0

      // Title block
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(9)

        // The console's own favicon, cached by the CLI. Absent until the first
        // refresh after this version, and on a console that does not serve
        // one — so the row is built to look right without it.
        // Sized to the text beside it rather than to a number, so the lockup
        // holds together at any font scale the theme picks.
        Image {
          Layout.preferredWidth: titleBlock.implicitHeight
          Layout.preferredHeight: titleBlock.implicitHeight
          Layout.alignment: Qt.AlignVCenter
          visible: status === Image.Ready
          source: "file://" + root.logoPath
          sourceSize.width: Style.space(48)
          sourceSize.height: Style.space(48)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
        }

        // Two lines read as one lockup only if they sit tight against each
        // other. Text reserves roughly a fifth of the font size in leading
        // above and below each line, which is right in a paragraph and wrong
        // in a two-line title — so both lines are pinned to their glyphs.
        ColumnLayout {
          id: titleBlock
          Layout.fillWidth: true
          spacing: 0

          Label {

            textFormat: Text.PlainText
            Layout.fillWidth: true
            Layout.preferredHeight: Math.round(Style.font.title * 1.15)
            text: "UNIFI CAMERAS"
            verticalAlignment: Text.AlignVCenter
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            font.letterSpacing: 0.6
          }

          Label {

            textFormat: Text.PlainText
            Layout.fillWidth: true
            Layout.preferredHeight: Math.round(Style.font.caption * 1.25)
            text: root.cameras.length === 0
              ? root.consoleHost
              : root.onlineCount + " of " + root.cameras.length + " online · " + root.consoleHost
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.5
          }
        }
      }

      // Camera chips. A Flow rather than a Row so a console with many cameras
      // wraps instead of pushing the selected one off the edge.
      // Selected camera header. The name is the selector: one control that
      // reads as a button, carries the online state, and scales from one
      // camera to twenty — where a row of chips stopped fitting.
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(16)
        spacing: Style.space(8)
        visible: root.selected !== null

        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: cameraButton.height

          Rectangle {
            id: cameraButton
            height: Style.spacing.controlHeight
            width: Math.min(cameraButtonRow.implicitWidth + Style.space(20), parent.width)
            radius: Style.cornerRadius

            // With one camera there is nothing to choose, so the control keeps
            // the status and the name but stops pretending to be pressable.
            readonly property bool interactive: root.cameras.length > 1
            readonly property bool hot: cameraHover.hovered && interactive

            color: hot ? Style.hoverFill : Style.normalFill
            border.width: hot ? Math.max(1, Style.space(2)) : Style.normalBorderWidth
            border.color: hot ? Color.accent : Style.normalBorderColor

            RowLayout {
              id: cameraButtonRow
              anchors.centerIn: parent
              spacing: Style.space(7)

              Rectangle {
                Layout.preferredWidth: Style.space(7)
                Layout.preferredHeight: Style.space(7)
                radius: width / 2
                color: root.selected && root.selected.connected ? Color.accent : Color.urgent
              }

              Label {

                textFormat: Text.PlainText
                text: root.selected ? root.selected.name : ""
                elide: Text.ElideRight
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Label {

                textFormat: Text.PlainText
                visible: cameraButton.interactive
                text: "\udb80\udd40"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                opacity: 0.55
              }
            }

            HoverHandler {
              id: cameraHover
              cursorShape: cameraButton.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
            }

            TapHandler {
              enabled: cameraButton.interactive
              onSingleTapped: cameraMenu.opened ? cameraMenu.close() : cameraMenu.open()
            }

            Popup {
              id: cameraMenu
              x: 0
              y: cameraButton.height + Style.space(4)
              width: Math.max(cameraButton.width, Style.space(200))
              padding: Style.space(4)
              focus: true

              background: Rectangle {
                color: Color.popups.background
                border.width: Style.normalBorderWidth
                border.color: Color.popups.border
                radius: Style.cornerRadius
              }

              contentItem: ColumnLayout {
                spacing: Style.space(1)

                Repeater {
                  model: root.cameras

                  delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.spacing.popupRowHeight
                    radius: Style.space(3)
                    readonly property bool current: root.selected && root.selected.id === modelData.id
                    color: rowHover.hovered ? Style.hoverFill
                      : (current ? Style.selectedFill : "transparent")

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(9)
                      anchors.rightMargin: Style.space(9)
                      spacing: Style.space(7)

                      Rectangle {
                        Layout.preferredWidth: Style.space(7)
                        Layout.preferredHeight: Style.space(7)
                        radius: width / 2
                        color: modelData.connected ? Color.accent : Color.urgent
                      }

                      Label {

                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: modelData.name
                        elide: Text.ElideRight
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    HoverHandler {
                      id: rowHover
                      cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                      onSingleTapped: {
                        root.selectCamera(modelData)
                        cameraMenu.close()
                      }
                    }
                  }
                }
              }
            }
          }

        }

        Button {
          Layout.alignment: Qt.AlignVCenter
          iconText: "\uf021"
          tooltipText: "Refresh snapshot"
          enabled: root.selected !== null && root.selected.connected
          iconSpinning: detailShotProcess.running
          onClicked: root.refreshSelected()
        }
      }

      Rectangle {
        id: stage
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        Layout.preferredHeight: Math.round(width * 9 / 16)
        radius: Style.space(5)
        color: "#000000"
        clip: true

        readonly property string posterSource: root.selected
          ? "file://" + root.snapshotDir + "/" + root.selected.id + ".jpg"
          : ""

        // The still sits under the video and stays there: poster while the
        // stream negotiates, and the picture itself when video never arrives.
        Image {
          id: poster
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          // Decode straight to the size actually drawn. A 3840x2160 JPEG scaled
          // down by the scene graph without mipmaps is what made this look
          // pixelated; it also cost 33 MB of texture for a 460 px panel.
          // 2x the drawn width covers HiDPI without depending on a Screen
          // attachment, which a popup window does not reliably have.
          sourceSize.width: Math.max(640, Math.round(stage.width * 2))
          source: stage.posterSource
          opacity: root.selected && root.selected.connected ? 1 : 0.35

          Connections {
            target: root
            function onDetailFrameChanged() {
              // Clearing first is what forces a re-read; the filename is
              // stable, so re-assigning alone is a no-op.
              poster.source = ""
              poster.source = stage.posterSource
            }
            function onSelectedIdChanged() {
              poster.source = ""
              poster.source = stage.posterSource
            }
          }
        }

        // QtMultimedia may not be installed, and a failed import takes down
        // whatever component declares it. A Loader keeps that a missing
        // feature rather than a broken panel.
        Loader {
          id: playerLoader
          anchors.fill: parent
          active: root.wantLive && root.streamUrl !== ""
          source: Qt.resolvedUrl("LivePlayer.qml")
          visible: item !== null && item.playing

          onStatusChanged: {
            if (status === Loader.Error)
              root.fallBackToSnapshots("In-panel video needs qt6-multimedia. Use Open in mpv.")
          }

          onLoaded: {
            item.url = Qt.binding(function() { return root.streamUrl })
            item.active = Qt.binding(function() { return root.wantLive })
            item.failed.connect(function(message) { root.videoUnavailable() })
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

        Label {

          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: poster.status !== Image.Ready && !(playerLoader.item && playerLoader.item.playing)
          text: root.liveMode === "connecting" ? "Connecting…" : "No picture"
          color: "#ffffff"
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          opacity: 0.5
        }

        // Handing the stream to mpv belongs on the video, not in the button
        // grid: it is an action on what you are looking at, and reads as the
        // fullscreen control every other player puts in this corner.
        Rectangle {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(8)
          width: Style.space(28)
          height: width
          radius: Style.space(4)
          visible: root.selected !== null && root.selected.connected
          color: expandHover.hovered ? Qt.rgba(0, 0, 0, 0.85) : Qt.rgba(0, 0, 0, 0.55)
          border.width: 1
          border.color: expandHover.hovered ? Qt.rgba(1, 1, 1, 0.85) : Qt.rgba(1, 1, 1, 0.35)

          Label {

            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "\uf065"
            color: "#ffffff"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          HoverHandler {
            id: expandHover
            cursorShape: Qt.PointingHandCursor
          }

          TapHandler {
            onSingleTapped: {
              root.play(root.selected.id, root.quality)
              root.close()
            }
          }

          PanelToolTip {
            visible: expandHover.hovered
            text: "Open full video in mpv"
          }
        }

        // Says what is actually on screen, which is not always what was asked
        // for — a stream that never opened still shows stills.
        Rectangle {
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(8)
          width: badge.implicitWidth + Style.space(14)
          height: badge.implicitHeight + Style.space(8)
          radius: Style.space(3)
          color: Qt.rgba(0, 0, 0, 0.65)
          visible: root.selected !== null

          RowLayout {
            id: badge
            anchors.centerIn: parent
            spacing: Style.space(5)

            Rectangle {
              Layout.preferredWidth: Style.space(6)
              Layout.preferredHeight: Style.space(6)
              radius: width / 2
              color: root.liveMode === "live" ? Color.accent
                : (root.wantLive ? Color.urgent : "transparent")
              border.width: root.liveMode === "live" || root.wantLive ? 0 : 1
              border.color: "#ffffff"
              opacity: root.liveMode === "live" || root.wantLive ? 1 : 0.6
            }

            Label {

              textFormat: Text.PlainText
              text: root.liveMode === "live" ? "Live"
                : (root.liveMode === "connecting" ? "Connecting…"
                  : (root.wantLive ? "Live · stills"
                    : (root.shotAt ? "Snapshot · " + root.shotAge : "Snapshot")))
              color: "#ffffff"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Label {

        textFormat: Text.PlainText
        Layout.fillWidth: true
        Layout.topMargin: Style.space(7)
        visible: root.liveMode === "snapshots" && root.liveDetail !== ""
        text: root.liveDetail
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.45
      }

      // Actions
      GridLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(10)
        columns: 2
        columnSpacing: Style.space(8)
        visible: root.selected !== null

        Button {
          Layout.fillWidth: true
          bordered: true
          enabled: root.selected !== null && root.selected.connected
          text: root.wantLive ? "Stop Live" : "Live Video"
          onClicked: root.wantLive ? root.stopLive() : root.startLive()
        }

        Button {
          Layout.fillWidth: true
          bordered: true
          enabled: root.selected !== null && root.selected.connected
          text: "Save Photo"
          onClicked: root.saveSnapshot(root.selected.id)
        }
      }

      // A rule marks the break between acting on this camera and reading about
      // it. Without one the details read as more controls.
      PanelSeparator {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(16)
        visible: root.selected !== null
      }

      // Details. The integration API has no events collection on 7.2.105 —
      // /events answers 404 while every other collection answers 200 — so this
      // slot carries what the console does report rather than an empty feed.
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(12)
        visible: root.selected !== null
        spacing: Style.space(8)

        Label {

          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "CAMERA DETAILS"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 0.5
          opacity: 0.45
        }

        // Confirmations belong beside the heading, not in place of it — the
        // heading used to be replaced by the toast, which meant the section
        // lost its label for as long as the message showed.
        Label {
          textFormat: Text.PlainText
          visible: root.toast !== ""
          text: root.toast
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          opacity: 0.55
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        spacing: Style.space(6)

        Repeater {
          model: root.detailRows

          delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(10)

            Label {

              textFormat: Text.PlainText
              text: modelData.label
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              opacity: 0.5
            }

            Label {

              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: modelData.value
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignRight
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }


      // Collapsed by default: these are set-and-forget, and the panel is for
      // looking at cameras. Only the settings the API actually accepts are
      // offered — the rest of the camera object is read-only.
      Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(14)
        Layout.preferredHeight: Style.spacing.controlHeight
        radius: Style.cornerRadius
        visible: root.selected !== null && root.settingRows.length > 0
        color: settingsHover.hovered ? Style.hoverFill : "transparent"

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(2)
          anchors.rightMargin: Style.space(6)
          spacing: Style.space(6)

          Label {

            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "SETTINGS"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 0.5
            opacity: 0.45
          }

          Label {

            textFormat: Text.PlainText
            text: root.settingsOpen ? "\udb80\udd43" : "\udb80\udd40"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            opacity: 0.45
          }
        }

        HoverHandler {
          id: settingsHover
          cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
          onSingleTapped: root.settingsOpen = !root.settingsOpen
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: root.settingsOpen ? Style.space(6) : 0
        spacing: Style.space(2)
        visible: root.settingsOpen && root.selected !== null

        Repeater {
          model: root.settingRows

          delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            Layout.preferredHeight: Style.spacing.controlHeight
            spacing: Style.space(10)

            Label {

              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: modelData.label
              elide: Text.ElideRight
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              opacity: root.selected && root.selected.connected ? 0.75 : 0.4
            }

            ToggleSwitch {
              checked: modelData.on
              busy: root.pendingSetting === modelData.key
              // An offline camera cannot be reconfigured, and a second write
              // while one is in flight would race the read that follows it.
              interactive: root.selected !== null && root.selected.connected
                && root.pendingSetting === ""
              onToggled: root.applySetting(modelData.key, !modelData.on)
            }
          }
        }
      }
    }
    }
  }
}
