#!/usr/bin/env bash
# Offline test suite. Nothing here touches a console; the Protect API surface is
# exercised by `unifi-protect probe` against real hardware instead.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0; skip=0
ok()   { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
skipt(){ printf 'skip - %s\n' "$1"; skip=$((skip + 1)); }
check() { if [[ $1 -eq 0 ]]; then ok "$2"; else no "$2"; fi; }

# ---------------------------------------------------------------- syntax

for script in lib/protect.sh bin/unifi-protect bin/unifi-terminal tests/run-tests.sh; do
  bash -n "$script" 2>/dev/null
  check $? "bash syntax: $script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning lib/protect.sh bin/unifi-protect bin/unifi-terminal >/dev/null 2>&1
  check $? "shellcheck is clean"
else
  skipt "shellcheck not installed"
fi

# ---------------------------------------------------------------- qml

# qmllint cannot resolve QtObject-grouped properties like Style.font or the
# host-injected `bar`, so those warnings are expected noise. Hard errors and
# layout-positioning warnings are not: both are real runtime bugs.
QMLLINT="$(command -v qmllint || printf '/usr/lib/qt6/bin/qmllint')"
if [[ -x $QMLLINT ]] && [[ -d ${OMARCHY_PATH:-/usr/share/omarchy}/shell ]]; then
  qmlroot="$(mktemp -d)"
  ln -sfn "${OMARCHY_PATH:-/usr/share/omarchy}/shell" "$qmlroot/qs"
  lint="$("$QMLLINT" -I "$qmlroot" BarWidget.qml Panel.qml 2>&1)"
  rm -rf "$qmlroot"
  ! grep -qE "^Error:|Expected token|Unexpected token|Syntax error|Unterminated|layout-positioning|property-override" <<<"$lint"
  check $? "qmllint reports no parse errors, layout, or shadowed-property warnings"
else
  skipt "qmllint or the Omarchy shell is not available"
fi

# ---------------------------------------------------------------- manifest

jq -e . manifest.json >/dev/null 2>&1
check $? "manifest.json is valid JSON"

# This is a standalone Omarchy plugin. A launcher contribution would make it
# load, and fail, on machines that do not have that launcher.
! jq -e 'has("omalaunch") or (.kinds | index("extension"))' manifest.json >/dev/null 2>&1
check $? "the manifest declares no launcher coupling"

! grep -rqil "omalaunch" --exclude-dir=.git --exclude=run-tests.sh .
check $? "no launcher references remain anywhere in the repo"

if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate . >/dev/null 2>&1
  check $? "omarchy-plugin-validate accepts the manifest"
else
  skipt "omarchy-plugin-validate not available"
fi

for entry in $(jq -r '.entryPoints[]' manifest.json); do
  [[ -f $entry ]]
  check $? "entry point exists: $entry"
done

# The panel dispatches through the wrapper so a terminal action's output
# survives the command finishing.
[[ -x bin/unifi-terminal ]]
check $? "the terminal wrapper is executable"

grep -q "bin/unifi-terminal" Panel.qml
check $? "the panel opens terminals through the wrapper, not the CLI directly"

# ---------------------------------------------------------------- key format

source lib/protect.sh 2>/dev/null || true
# The library sets `set -e` for its own callers; inheriting it here would
# abort the run on the first failed assertion instead of reporting it.
set +e

api_key_valid 'abcdEFGH01234567_-.~+/=' && ok "a URL-safe key is accepted" || no "a URL-safe key is accepted"
api_key_valid 'short' && no "a too-short key is rejected" || ok "a too-short key is rejected"
# A key carrying a quote or backslash would break out of the curl config's
# quoted header value, so the format guard is a correctness check, not cosmetics.
api_key_valid 'abcdEFGH01234567"' && no "a quote in a key is rejected" || ok "a quote in a key is rejected"
api_key_valid 'abcdEFGH01234567\' && no "a backslash in a key is rejected" || ok "a backslash in a key is rejected"
api_key_valid "$(printf 'abcdEFGH01234567\nheader = "X-Evil: 1"')" \
  && no "a newline in a key is rejected" || ok "a newline in a key is rejected"

# ---------------------------------------------------------------- cli

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/config"

# Every subcommand must be reachable from the dispatcher. `probe` was defined
# but unlisted at one point, which the verification guide depends on.
missing=""
for sub in $(./bin/unifi-protect --help | awk '/^[a-z]/ && $1 != "usage:" {print $1}'); do
  grep -qE "^\\s+${sub}\\)" bin/unifi-protect || missing="$missing $sub"
done
[[ -z $missing ]]
check $? "every documented subcommand is dispatched (missing:${missing:-none})"

# `die` inside a command substitution cannot stop the caller, so an unconfigured
# system used to report the same problem three times and continue with empty
# values. One command, one message.
lines="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect cameras 2>&1 | wc -l)"
[[ $lines -eq 1 ]]
check $? "an unconfigured console reports exactly one error (got $lines)"

out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect cameras 2>&1)"
grep -q "no console configured" <<<"$out"
check $? "the unconfigured error names the fix"

mkdir -p "$CFG/omarchy-unifi"
printf 'not json' > "$CFG/omarchy-unifi/config.json"
out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect cameras 2>&1)"
grep -q "not valid JSON" <<<"$out"
check $? "a malformed config is reported as such"

printf '{"console":{"port":443}}' > "$CFG/omarchy-unifi/config.json"
out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect cameras 2>&1)"
grep -q "missing console.host" <<<"$out"
check $? "a config without a host is reported as such"

# `forget` has to work on a half-configured system rather than dying first.
XDG_CONFIG_HOME="$CFG" HOME="$TMP" ./bin/unifi-protect forget >/dev/null 2>&1
check $? "forget succeeds without a usable config"

# A configured console with no key in the keyring is the state right after
# `setup` is interrupted. It must report the missing key once, not follow up
# with a bogus complaint about the key's format.
#
# Gated on secret-tool: without it the CLI stops earlier, at the missing
# dependency, and these would pass for the wrong reason rather than fail.
printf '{"console":{"host":"198.51.100.1","port":443,"pin":"sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}' > "$CFG/omarchy-unifi/config.json"
if command -v secret-tool >/dev/null 2>&1; then
  out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect check 2>&1)"
  [[ $(wc -l <<<"$out") -eq 1 ]]
  check $? "a missing API key reports exactly one error"

  grep -q "no API key stored" <<<"$out"
  check $? "the missing-key error names the fix"

  ! grep -q "unexpected format" <<<"$out"
  check $? "a missing key is not also reported as malformed"
else
  skipt "secret-tool not installed; missing-key reporting not exercised"
fi

# The panel decides which screen to show from `status`, so it must classify
# every setup state, always succeed, and never emit the key itself.
st="$(XDG_CONFIG_HOME="$TMP/nothing" ./bin/unifi-protect status)"
[[ $? -eq 0 ]] && jq -e '.state == "no-console" and .configured == false' <<<"$st" >/dev/null
check $? "status reports no-console without a config"

printf '{"console":{"host":"198.51.100.1","port":443,"pin":"sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}' > "$CFG/omarchy-unifi/config.json"
st="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect status)"
jq -e '.state == "no-key" and .configured == true and .hasKey == false and .host == "198.51.100.1"' <<<"$st" >/dev/null
check $? "status distinguishes a configured console with no key"

printf 'not json' > "$CFG/omarchy-unifi/config.json"
st="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect status)"
jq -e '.state == "bad-config"' <<<"$st" >/dev/null
check $? "status reports bad-config for unreadable settings"

! jq -e 'to_entries | map(.key) | index("key")' <<<"$st" >/dev/null 2>&1
check $? "status never includes the key itself"

# Every state the CLI can report needs copy in the panel, or the empty screen
# falls back to a message that does not match the actual problem.
for st_name in no-console bad-config no-key bad-key ready; do
  grep -q "\"$st_name\"" bin/unifi-protect || continue
  [[ $st_name == ready ]] || grep -q "\"$st_name\":" Panel.qml
  check $? "the panel has copy for the '$st_name' state"
done

out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect probe cameras 2>&1)"
grep -q "usage: unifi-protect probe" <<<"$out"
check $? "probe rejects a path that is not absolute"

# Piping a key in is the way to set one without it reaching a transcript, and
# `wl-paste` emits no trailing newline. `read` returns 1 at EOF in that case,
# which under `set -e` aborted before anything was stored.
printf '{"console":{"host":"198.51.100.1","port":443,"pin":""}}' > "$CFG/omarchy-unifi/config.json"
# This is the one test that touches the real Secret Service, since that is what
# key-set writes to. It uses a documentation-range host so it cannot collide
# with a real console, and clears the entry immediately. Without a keyring the
# store fails for an unrelated reason, so the assertion would be meaningless.
if command -v secret-tool >/dev/null 2>&1 && secret-tool search --all application omarchy-unifi >/dev/null 2>&1; then
  out="$(printf 'abcdEFGH0123456789' | XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect key-set 2>&1)"
  ! grep -qi "unexpected format\|does not look like" <<<"$out"
  check $? "a key piped without a trailing newline is read, not dropped"
  secret-tool clear application omarchy-unifi kind api-key host 198.51.100.1 2>/dev/null || true

  ! secret-tool lookup application omarchy-unifi kind api-key host 198.51.100.1 >/dev/null 2>&1
  check $? "the test key is removed from the keyring afterwards"
else
  skipt "no usable Secret Service; key storage not exercised"
fi

# Hardware findings, pinned so a refactor cannot quietly reintroduce them.
# Verified against UniFi Protect 7.2.105.
! grep -q "enable-rtsp" bin/unifi-protect
check $? "enable-rtsp is gone (the integration API rejects channel edits)"

! grep -q "cmd_events" bin/unifi-protect
check $? "the events subcommand is gone (/events 404s on this API)"

grep -q "qualities=high,medium,low" bin/unifi-protect
check $? "stream-url asks for every quality so it can fall back"

# Live video only starts on a press, so the resting badge must not claim a
# connection is being attempted.
grep -q 'property string liveMode: "snapshots"' Panel.qml
check $? "the panel rests on snapshots rather than a phantom 'Connecting…'"

# FFmpeg verifies peer certificates by default and a UniFi console serves a
# self-signed one, so RTSPS fails outright without this. Verified on 7.2.105.
grep -q "tls_verify=0" bin/unifi-protect
check $? "mpv is told not to verify the console's self-signed stream cert"

grep -q "rtsp-transport=tcp" bin/unifi-protect
check $? "the stream is pulled over TCP rather than UDP"

# Qt reports the TLS rejection as "Could not open file", which points readers
# at a missing path rather than the certificate.
! grep -q "failed.connect(function(message) { root.fallBackToSnapshots(message)" Panel.qml
check $? "the panel does not relay Qt's misleading player error"

grep -q "mpv" Panel.qml
check $? "the video fallback names the remedy"

# Handing the stream to mpv is an action on the video, so it lives on the
# stage rather than duplicating a row button.
! grep -q 'text: "Open in mpv"' Panel.qml
check $? "the mpv row button is gone in favour of the stage control"

grep -q "Open full video in mpv" Panel.qml
check $? "the stage carries an expand control"

# The header's refresh icon already takes a fresh snapshot.
! grep -q 'text: "Refresh"' Panel.qml
check $? "the redundant refresh button is gone"

# The relay survives an orderly stop and a SIGKILL of either process.
grep -q 'kill -0 "$self"' bin/unifi-protect
check $? "the relay watchdog notices this script being killed"

# The relay holds an ffmpeg process and a listening socket; every exit from
# live view has to take it down.
grep -q "127.0.0.1" bin/unifi-protect
check $? "the relay binds to loopback only"

[[ $(grep -c "relayProcess.running = false" Panel.qml) -ge 3 ]]
check $? "every path out of live view stops the relay"

grep -q "sourceSize.width" Panel.qml
check $? "snapshots are decoded at display size rather than scaled from 4K"

grep -q "root.cameras.length > 1" Panel.qml
check $? "the camera control is inert when there is only one camera"

# The chip row and the header name were two controls for one job.
! grep -q "Flow {" Panel.qml
check $? "the chip selector is gone; the name button replaces it"

grep -q "cameraMenu" Panel.qml
check $? "the name button opens a camera menu"

grep -q "blocked: cameraMenu.opened" Panel.qml
check $? "Escape dismisses the camera menu before closing the panel"

# Status is an icon now, so the subtitle should not also spell it out.
! grep -q '"Online" : "Offline") + " · "' Panel.qml
check $? "the subtitle no longer repeats the online state"

# The model sits in CAMERA DETAILS; printing it under the button too was the
# same fact twice on one screen.
! grep -q "root.selected.model : \"\"" Panel.qml
check $? "the model is not repeated under the camera button"

grep -q 'label: "Model"' Panel.qml
check $? "the model is still reported in the details list"

# Settings the API rejects must never reach the UI. isMicEnabled reads as
# writable on the camera object and is not; verified on Protect 7.2.105.
grep -q "toggle_apply" bin/unifi-protect
check $? "settings go through one place that names what is writable"

! grep -qE 'key: "(mic|hdr|video|name)' Panel.qml
check $? "no setting row is offered for a field the API will not accept"

# Every key the panel can send has to be one the CLI handles, or the switch
# fails silently against a console that never saw the request.
for key in $(grep -oE 'key: "[a-z-]+"' Panel.qml | sed 's/key: "//;s/"//'); do
  [[ $key == detect-* ]] && continue
  grep -q "    ${key})" bin/unifi-protect
  check $? "the CLI handles the '$key' key the panel sends"
done

for setting in led osd-name osd-date osd-logo; do
  grep -q "$setting)" bin/unifi-protect
  check $? "the CLI accepts the '$setting' setting"
done

out="$(./bin/unifi-protect toggle someid bogus on 2>&1)"
grep -q "unknown setting" <<<"$out"
check $? "an unknown setting is refused before any request"

out="$(./bin/unifi-protect toggle someid led maybe 2>&1)"
grep -q "state must be on or off" <<<"$out"
check $? "a non-boolean state is refused before any request"

# objectTypes is replaced wholesale, so it is rebuilt from what the console
# reports rather than from anything this process cached.
grep -q "smartDetectSettings.objectTypes" bin/unifi-protect
check $? "detection toggles read the live list before rewriting it"

grep -q "root.loadCameras()" Panel.qml
check $? "a switch follows the console's answer rather than the press"

# The panel is content-sized but capped to the screen, so anything that can
# grow past the cap has to be reachable.
grep -q "interactive: contentHeight > height" Panel.qml
check $? "content taller than the card scrolls instead of clipping"

# KeyboardPanel already insets its content by popupPadding; margins here are
# padding on top of padding.
! grep -q "anchors.margins: Style.space(16)" Panel.qml
check $? "the content does not double up on the panel's own padding"

# Discovery fingerprints the integration API rather than an open port: plenty
# of things serve HTTPS on 443, only Protect serves this path.
grep -q "proxy/protect/integration/v1" bin/unifi-protect
check $? "the scan probes the integration API path"

grep -q 'code == 401 || \$code == 200' bin/unifi-protect
check $? "an unauthenticated 401 is what identifies a console"

grep -q "setup_choose_host" bin/unifi-protect
check $? "setup offers what the scan found instead of demanding an address"

# A scan that sweeps every reachable subnet costs seconds for no real gain.
grep -q "SCAN_MAX_HOSTS" bin/unifi-protect
check $? "the scan is bounded"

# The title-row Setup button was only ever visible once setup had succeeded —
# every failure state replaces the whole view with its own action button.
! grep -q 'text: "Setup"' Panel.qml
check $? "no Setup button sits in the title once setup has succeeded"

# The mark is Ubiquiti's; it comes from the console the user owns rather than
# being redistributed in this repo.
! ls assets/*.svg >/dev/null 2>&1
check $? "no vendor logo is shipped in the repo"

grep -q "favicon.svg" bin/unifi-protect
check $? "the logo is fetched from the console"

grep -q "status === Image.Ready" Panel.qml
check $? "the title row renders correctly without a cached logo"

# The lockup has to survive a theme that scales fonts, so the logo is bound to
# the text block rather than set to a number.
grep -q "Layout.preferredHeight: titleBlock.implicitHeight" Panel.qml
check $? "the logo is sized from the title block, not a hardcoded value"

# A single spacing value makes every gap equally important, so nothing groups.
[[ $(grep -c "Layout.topMargin" Panel.qml) -ge 8 ]]
check $? "vertical gaps are set per boundary rather than inherited"

grep -q "rtsp_disabled_message" bin/unifi-protect
check $? "a disabled RTSP channel produces actionable guidance"

! grep -q 'isPtz\|canOpticalZoom' bin/unifi-protect
check $? "nothing reads featureFlags keys Protect does not send"

# ---------------------------------------------------------- security baseline
#
# Each of these pins a finding from the marketplace security review. They are
# the checks whose absence was not visible until someone looked.

# The pin is the only thing authenticating a console, because every request
# runs with --insecure against a self-signed certificate. No pin must mean no
# connection, not an unauthenticated one.
printf '{"console":{"host":"198.51.100.1","port":443,"pin":""}}' > "$CFG/omarchy-unifi/config.json"
out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect check 2>&1)"
grep -q "no usable certificate pin" <<<"$out"
check $? "a config without a pin is refused rather than run unauthenticated"

printf '{"console":{"host":"198.51.100.1","port":443,"pin":"sha256//tooshort"}}' > "$CFG/omarchy-unifi/config.json"
out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect check 2>&1)"
grep -q "no usable certificate pin" <<<"$out"
check $? "a malformed pin is refused"

! grep -q 'CONSOLE_PIN.*&&.*pinnedpubkey' lib/protect.sh
check $? "the pin is never conditional on being present"

# Camera ids are interpolated into request paths and become cache filenames.
# This validation existed once and was deleted with the launcher provider.
for sub in snapshot export stream-url play relay ptz-stop; do
  out="$(./bin/unifi-protect "$sub" '../../etc/passwd' 2>&1)"
  grep -q "invalid camera id" <<<"$out"
  check $? "'$sub' rejects a camera id that would escape the cache directory"
done
out="$(./bin/unifi-protect toggle '../x' led on 2>&1)"
grep -q "invalid camera id" <<<"$out"
check $? "'toggle' rejects a traversing camera id"
out="$(./bin/unifi-protect ptz-goto '../x' 0 2>&1)"
grep -q "invalid camera id" <<<"$out"
check $? "'ptz-goto' rejects a traversing camera id"

grep -q "camera_id_valid \"\$id\" || continue" bin/unifi-protect
check $? "the refresh sweep filters ids the console reports"

# Every id-taking command has to validate; a missed one is the bug this
# prevents, so the list is derived rather than hand-maintained.
missing=""
for sub in snapshot export stream-url play relay toggle ptz-goto ptz-patrol ptz-stop; do
  fn="cmd_$(tr '-' '_' <<<"$sub")"
  sed -n "/^${fn}() {/,/^}/p" bin/unifi-protect | grep -q "checked_camera_id" \
    || missing="$missing $sub"
done
[[ -z $missing ]]
check $? "every id-taking command validates it (missing:${missing:-none})"

# Qt allocates for whatever dimensions a JPEG header claims, and the panel
# hands it whatever the console sent.
source lib/protect.sh 2>/dev/null || true
set +e
printf 'not an image' > "$TMP/notjpeg.bin"
! snapshot_valid "$TMP/notjpeg.bin"
check $? "a snapshot that is not a JPEG is refused"

grep -q 'python3 - "\$1" "\$MAX_SNAPSHOT_PIXELS"' lib/protect.sh
check $? "the decode-cost limit has one definition, passed in rather than duplicated"

magick -size 9000x9000 xc:red "$TMP/bomb.jpg" 2>/dev/null && {
  ! snapshot_valid "$TMP/bomb.jpg"
  check $? "a frame too costly to decode is refused"
}

grep -q 'written <= MAX_SNAPSHOT_BYTES' lib/protect.sh
check $? "the byte budget is checked against what landed, not the declared length"

# A locked keyring or a host that accepts and stalls must not wedge the panel.
for helper in "secret-tool store" "secret-tool lookup" "openssl s_client"; do
  grep -q "timeout \"\$HELPER_TIMEOUT\" $helper" lib/protect.sh
  check $? "'$helper' runs under a deadline"
done

# QML's default textFormat sniffs for markup, so a camera name containing a
# tag would render as rich text instead of as the name.
labels=$(grep -c "Label {" Panel.qml)
plain=$(grep -c "textFormat: Text.PlainText" Panel.qml)
[[ $labels -eq $plain ]]
check $? "every label renders as plain text ($plain of $labels)"

grep -q 'String(entry.name || "Camera").substring(0, 64)' Panel.qml
check $? "remote camera names are length-capped where they enter the model"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
