import QtQuick
import QtMultimedia

// RTSPS playback for the detail view, isolated in its own file on purpose.
// QtMultimedia is not guaranteed to be installed, and a failed import takes
// down the whole component that declares it — so the panel loads this through
// a Loader and treats an error status as "fall back to snapshots" rather than
// losing the camera grid along with it.
Item {
  id: root

  property string url: ""
  property bool active: false

  readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
  readonly property bool buffering: player.mediaStatus === MediaPlayer.LoadingMedia
    || player.mediaStatus === MediaPlayer.StalledMedia

  signal failed(string message)

  function stop() { player.stop() }

  onActiveChanged: {
    if (!active) player.stop()
    else if (url !== "") player.play()
  }

  MediaPlayer {
    id: player
    videoOutput: output
    source: root.active && root.url !== "" ? root.url : ""

    onSourceChanged: if (root.active && root.url !== "") play()
    onErrorOccurred: function(error, errorString) {
      // Reported rather than retried: the caller already has a working
      // snapshot path to fall back to, and a retry loop against a console
      // that is refusing the stream just burns the shell's process slots.
      root.failed(String(errorString || "the stream could not be opened"))
    }
  }

  VideoOutput {
    id: output
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectFit
  }
}
