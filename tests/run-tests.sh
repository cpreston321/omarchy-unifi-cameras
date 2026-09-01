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

for script in lib/protect.sh bin/unifi-protect bin/unifi-setup-terminal tests/run-tests.sh; do
  bash -n "$script" 2>/dev/null
  check $? "bash syntax: $script"
done

python3 -c "import ast,sys; ast.parse(open('bin/omalaunch-provider').read())" 2>/dev/null
check $? "python syntax: bin/omalaunch-provider"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning lib/protect.sh bin/unifi-protect bin/unifi-setup-terminal >/dev/null 2>&1
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

jq -e '.omalaunch.extensions and .omalaunch.extensionProviders' manifest.json >/dev/null 2>&1
check $? "manifest declares both Omalaunch contribution paths"

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

for provider in $(jq -r '.omalaunch.extensionProviders[][0]' manifest.json); do
  [[ -x $provider ]]
  check $? "extension provider is executable: $provider"
done

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

# ---------------------------------------------------------------- provider

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/omarchy-unifi"

# No cache at all: the launcher must get an empty catalog, not an error.
out="$(XDG_CACHE_HOME="$TMP/empty" ./bin/omalaunch-provider 2>/dev/null)"
[[ $out == "[]" ]]
check $? "provider emits an empty catalog when no console is configured"

cp tests/fixtures/cameras.json "$TMP/omarchy-unifi/cameras.json"
provider_out="$(XDG_CACHE_HOME="$TMP" ./bin/omalaunch-provider)"

printf '%s' "$provider_out" | jq -e . >/dev/null 2>&1
check $? "provider emits valid JSON"

count="$(printf '%s' "$provider_out" | jq '.workflow.items | length')"
[[ $count -eq 3 ]]
check $? "provider drops entries with a malformed or missing id (got $count of 5)"

printf '%s' "$provider_out" | jq -e '[.workflow.items[].label] == ["Driveway PTZ", "Front Door", "Garage"]' >/dev/null
check $? "provider sorts cameras by name"

printf '%s' "$provider_out" | jq -e '.workflow.items[] | select(.label == "Driveway PTZ") | .items | map(.id) | index("preset")' >/dev/null
check $? "a PTZ camera gets a preset node"

printf '%s' "$provider_out" | jq -e '.workflow.items[] | select(.label == "Front Door") | .items | map(.id) | index("preset") == null' >/dev/null
check $? "a non-PTZ camera gets no preset node"

# Every command has to be an argument array the launcher can dispatch without a
# shell; a bare string would be silently dropped by normalizeExtension.
printf '%s' "$provider_out" | jq -e '[.workflow.items[].items[] | .command // []] | all(type == "array" and length > 0)' >/dev/null
check $? "every workflow leaf carries an argument-array command"

# ---------------------------------------------------------------- cli

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
printf '{"console":{"host":"198.51.100.1","port":443,"pin":""}}' > "$CFG/omarchy-unifi/config.json"
out="$(XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect check 2>&1)"
[[ $(wc -l <<<"$out") -eq 1 ]]
check $? "a missing API key reports exactly one error"

grep -q "no API key stored" <<<"$out"
check $? "the missing-key error names the fix"

! grep -q "unexpected format" <<<"$out"
check $? "a missing key is not also reported as malformed"

# The panel decides which screen to show from `status`, so it must classify
# every setup state, always succeed, and never emit the key itself.
st="$(XDG_CONFIG_HOME="$TMP/nothing" ./bin/unifi-protect status)"
[[ $? -eq 0 ]] && jq -e '.state == "no-console" and .configured == false' <<<"$st" >/dev/null
check $? "status reports no-console without a config"

printf '{"console":{"host":"198.51.100.1","port":443,"pin":""}}' > "$CFG/omarchy-unifi/config.json"
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
# with a real console, and clears the entry immediately.
out="$(printf 'abcdEFGH0123456789' | XDG_CONFIG_HOME="$CFG" ./bin/unifi-protect key-set 2>&1)"
! grep -qi "unexpected format\|does not look like" <<<"$out"
check $? "a key piped without a trailing newline is read, not dropped"
secret-tool clear application omarchy-unifi kind api-key host 198.51.100.1 2>/dev/null || true

! secret-tool lookup application omarchy-unifi kind api-key host 198.51.100.1 >/dev/null 2>&1
check $? "the test key is removed from the keyring afterwards"

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

grep -q "self-signed certificate" Panel.qml
check $? "the video fallback names the real cause and the remedy"

grep -q "rtsp_disabled_message" bin/unifi-protect
check $? "a disabled RTSP channel produces actionable guidance"

grep -q 'in model.lower()' bin/omalaunch-provider
check $? "PTZ is detected from the model name, not a featureFlags key"

! grep -q 'isPtz\|canOpticalZoom' bin/omalaunch-provider
check $? "the provider no longer reads featureFlags keys Protect does not send"

# ------------------------------------------------- Omalaunch schema conformance

OMALAUNCH="${OMALAUNCH_PATH:-$HOME/Documents/projects/omalaunch}"
if command -v node >/dev/null 2>&1 && [[ -f $OMALAUNCH/MenuModel.js ]]; then
  printf '%s' "$provider_out" > "$TMP/provider.json"
  node -e '
    const fs = require("fs"), vm = require("vm")
    const context = { module: { exports: {} } }
    vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), context)
    const menu = context.module.exports
    let bad = 0
    for (const file of process.argv.slice(2)) {
      const normalized = menu.normalizeExtension(JSON.parse(fs.readFileSync(file, "utf8")))
      if (!normalized || normalized.mode !== "workflow" || !normalized.workflow) {
        console.error("rejected: " + file); bad++
      }
    }
    process.exit(bad ? 1 : 0)
  ' "$OMALAUNCH/MenuModel.js" omalaunch.json "$TMP/provider.json" >/dev/null 2>&1
  check $? "both extensions pass Omalaunch's normalizeExtension"
else
  skipt "Omalaunch checkout or node not available for schema conformance"
fi

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
