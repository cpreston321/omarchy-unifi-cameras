#!/usr/bin/env bash
# Shared runtime for the UniFi Protect plugin. Sourced by bin/unifi-protect;
# not executable on its own.
#
# Two invariants shape everything below:
#   1. The API key never reaches argv or the environment. It is written into a
#      curl config on stdin, so it is never visible in /proc to another user.
#   2. Consoles use self-signed certificates, so transport trust is a public-key
#      pin captured at setup time rather than the system CA store.

set -euo pipefail

readonly API_BASE='/proxy/protect/integration/v1'

# Ceilings, not tuning knobs: a hung console must not wedge the shell's Process
# slot, and a malformed response must not be buffered without bound.
readonly HTTP_TIMEOUT=10
readonly HTTP_CONNECT_TIMEOUT=4
readonly MAX_JSON_BYTES=4194304
readonly MAX_SNAPSHOT_BYTES=16777216
# A locked keyring prompting behind the panel, or a host that accepts the TCP
# connection and then says nothing, must not wedge the caller indefinitely.
readonly HELPER_TIMEOUT=15
# Beyond any camera Protect ships; a frame larger than this is a decode cost,
# not a picture.
readonly MAX_SNAPSHOT_PIXELS=40000000

config_dir()  { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-unifi"; }
config_path() { printf '%s\n' "$(config_dir)/config.json"; }
cache_dir()   { printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-unifi"; }
snapshot_dir(){ printf '%s\n' "$(cache_dir)/snapshots"; }

die() { printf 'unifi-protect: %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required tools: ${missing[*]}"
}

# ------------------------------------------------------------------ config

# Config is loaded once into shell variables rather than read per field. A
# `die` inside a command substitution only kills the subshell, so a per-field
# reader would report a missing console once for every field it was asked for
# and then carry on with empty values.
CONSOLE_HOST=""
CONSOLE_PORT=""
CONSOLE_PIN=""
CONFIG_LOADED=0

config_load() {
  [[ $CONFIG_LOADED -eq 1 ]] && return 0
  require_tools jq
  local path
  path="$(config_path)"
  [[ -f $path ]] || die "no console configured; run 'unifi-protect setup <host>' first"
  jq -e . "$path" >/dev/null 2>&1 || die "config is not valid JSON: $path"
  CONSOLE_HOST="$(jq -r '.console.host // empty' "$path")"
  CONSOLE_PORT="$(jq -r '.console.port // 443' "$path")"
  CONSOLE_PIN="$(jq -r '.console.pin // empty' "$path")"
  [[ -n $CONSOLE_HOST ]] || die "config is missing console.host; re-run 'unifi-protect setup <host>'"
  [[ $CONSOLE_PORT =~ ^[0-9]+$ ]] || die "config has a non-numeric console.port"
  # Fail closed. A console serves a self-signed certificate, so every request
  # runs with --insecure and the pin is the *only* thing authenticating the
  # server. Without one there is no authentication at all, which is worse than
  # refusing to connect — and worse still because it looks like it is working.
  pin_valid "$CONSOLE_PIN" \
    || die "config has no usable certificate pin; re-run 'unifi-protect setup ${CONSOLE_HOST}' to pin this console"
  CONFIG_LOADED=1
}

# True when a console has been set up, without dying if it has not. Lets a
# command clean up or report state on an unconfigured system.
config_present() { [[ -f $(config_path) ]]; }

console_host() { config_load; printf '%s\n' "$CONSOLE_HOST"; }
console_port() { config_load; printf '%s\n' "$CONSOLE_PORT"; }
console_pin()  { config_load; printf '%s\n' "$CONSOLE_PIN"; }

console_origin() {
  config_load
  if [[ $CONSOLE_PORT == 443 ]]; then printf 'https://%s\n' "$CONSOLE_HOST"
  else printf 'https://%s:%s\n' "$CONSOLE_HOST" "$CONSOLE_PORT"; fi
}

config_write() {
  local host=$1 port=$2 pin=$3
  pin_valid "$pin" || die "refusing to write a config without a usable certificate pin"
  local dir path tmp
  dir="$(config_dir)"; path="$(config_path)"
  mkdir -p "$dir"; chmod 700 "$dir"
  tmp="$(mktemp "$dir/.config.XXXXXX")"
  jq -n --arg host "$host" --argjson port "$port" --arg pin "$pin" \
    '{console: {host: $host, port: $port, pin: $pin}}' > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$path"
  CONFIG_LOADED=0
}

# ------------------------------------------------------ credentials (Secret Service)

secret_attrs() { printf 'application omarchy-unifi kind api-key host %s' "$1"; }

api_key_store() {
  # Reads the key from stdin so it is never an argument to secret-tool.
  local host=$1
  require_tools secret-tool
  timeout "$HELPER_TIMEOUT" secret-tool store --label="UniFi Protect API key ($host)" \
    application omarchy-unifi kind api-key host "$host"
}

# Presence is checked separately from retrieval because callers read the key
# through a command substitution, and a `die` there would only kill the
# subshell — leaving the caller to continue with an empty key and report a
# second, misleading error about its format.
api_key_present() {
  config_load
  require_tools secret-tool
  timeout "$HELPER_TIMEOUT" secret-tool lookup application omarchy-unifi kind api-key host "$CONSOLE_HOST" >/dev/null 2>&1
}

api_key_lookup() {
  config_load
  timeout "$HELPER_TIMEOUT" secret-tool lookup application omarchy-unifi kind api-key host "$CONSOLE_HOST" 2>/dev/null
}

# Run in the caller's shell, before any substitution, so both failure modes
# abort with exactly one message.
require_api_key() {
  config_load
  api_key_present || die "no API key stored for $CONSOLE_HOST; run 'unifi-protect key-set'"
  local key
  key="$(api_key_lookup)"
  api_key_valid "$key" || die "the stored API key has an unexpected format; re-run 'unifi-protect key-set'"
}

api_key_clear() {
  local host=$1
  secret-tool clear application omarchy-unifi kind api-key host "$host" 2>/dev/null || true
}

# The key is interpolated into a curl config file, whose quoting rules would
# otherwise need escaping. UniFi keys are URL-safe base64, so rejecting anything
# else is both accurate and simpler than escaping.
api_key_valid() { [[ $1 =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]]; }

# ------------------------------------------------------------------ TLS pin

# Public-key pin of the console's leaf certificate, in curl's --pinnedpubkey
# format. Captured once at setup; a change afterwards fails every request loudly
# rather than silently trusting a new certificate.
# curl's --pinnedpubkey format: sha256// then base64 of a SHA-256 digest,
# which is always 43 characters plus one '=' of padding.
# Camera ids come from the console and are used two ways that both matter:
# they are interpolated into request paths, and they become cache filenames.
# A console that is compromised, spoofed, or simply buggy must not be able to
# steer either — an id like "../../.bashrc" is a write outside the cache.
camera_id_valid() { [[ $1 =~ ^[A-Za-z0-9]{4,64}$ ]]; }

checked_camera_id() {
  camera_id_valid "${1-}" || die "invalid camera id"
  printf '%s\n' "$1"
}

pin_valid() { [[ $1 =~ ^sha256//[A-Za-z0-9+/]{43}=$ ]]; }

fetch_pin() {
  local host=$1 port=$2
  require_tools openssl
  local der
  der="$(timeout "$HELPER_TIMEOUT" openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null \
    | openssl x509 -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null \
    | base64 -w0 2>/dev/null)" || true
  [[ -n $der ]] || die "could not read a TLS certificate from $host:$port"
  local pin="sha256//${der}"
  pin_valid "$pin" || die "the certificate from $host:$port did not yield a usable pin"
  printf '%s\n' "$pin"
}

# ------------------------------------------------------------------ HTTP

# curl options shared by every request. --insecure disables CA and hostname
# checks (the console's certificate is self-signed and issued to an internal
# name); --pinnedpubkey is what actually establishes trust and is enforced
# independently of --insecure.
curl_common() {
  config_load
  printf '%s\n' \
    --silent --show-error --fail-with-body \
    --proto '=https' --noproxy '*' --no-location \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
    --insecure
  # config_load has already refused an unusable pin, so this is never the
  # bare --insecure that would leave the server unauthenticated.
  printf '%s\n' --pinnedpubkey "$CONSOLE_PIN"
}

# api_request METHOD PATH [JSON_BODY]
# Writes the response body to stdout. The API key is passed on stdin inside a
# curl config, never as an argument.
api_request() {
  local method=$1 path=$2 body=${3-}
  require_tools curl jq
  require_api_key
  local key origin
  key="$(api_key_lookup)"
  origin="$(console_origin)"

  local -a args
  mapfile -t args < <(curl_common)
  args+=(--request "$method" --max-filesize "$MAX_JSON_BYTES")
  args+=(--header 'Accept: application/json')
  if [[ -n $body ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "$body")
  fi
  args+=("${origin}${API_BASE}${path}")

  printf 'header = "X-API-Key: %s"\n' "$key" | curl --config - "${args[@]}"
}

# Confirms the bytes are a JPEG and that decoding one will not cost more than
# it is worth. The panel hands this file to Qt, which will happily allocate for
# whatever dimensions the header claims — so the header is read here, before
# anything renders it, rather than trusting the console.
snapshot_valid() {
  python3 - "$1" "$MAX_SNAPSHOT_PIXELS" <<'PYTHON'
import struct, sys

path = sys.argv[1]
MAX_PIXELS = int(sys.argv[2])

with open(path, "rb") as handle:
    data = handle.read(1024 * 128)

if not data.startswith(b"\xff\xd8\xff"):
    sys.exit(1)

# Walk the JPEG segments to the frame header, which carries the dimensions.
offset = 2
while offset + 9 < len(data):
    if data[offset] != 0xFF:
        offset += 1
        continue
    marker = data[offset + 1]
    if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
        offset += 2
        continue
    length = struct.unpack(">H", data[offset + 2:offset + 4])[0]
    # SOF0-SOF15, excluding the non-frame markers that share the range.
    if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
        height, width = struct.unpack(">HH", data[offset + 5:offset + 9])
        sys.exit(0 if 0 < width * height <= MAX_PIXELS else 1)
    offset += 2 + length

# A JPEG whose dimensions are past the window read above is not one a camera
# produced.
sys.exit(1)
PYTHON
}

# api_snapshot CAMERA_ID OUTPUT_PATH — writes a JPEG, atomically.
api_snapshot() {
  local id=$1 out=$2
  require_tools curl
  require_api_key
  local key origin tmp
  key="$(api_key_lookup)"
  origin="$(console_origin)"
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "${out}.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  local -a args
  mapfile -t args < <(curl_common)
  args+=(--request GET --max-filesize "$MAX_SNAPSHOT_BYTES")
  args+=(--header 'Accept: image/jpeg' --output "$tmp")
  args+=("${origin}${API_BASE}/cameras/${id}/snapshot?highQuality=true")

  printf 'header = "X-API-Key: %s"\n' "$key" | curl --config - "${args[@]}"
  # A console that is booting answers 200 with an empty body; treat that as a
  # miss rather than replacing a good cached frame with a blank one.
  [[ -s $tmp ]] || die "empty snapshot for camera $id"
  # --max-filesize is only enforced when the response declares a length, so a
  # chunked reply can walk straight past it. This is the budget that actually
  # holds, checked against what landed on disk.
  local written
  written="$(stat -c %s "$tmp")"
  (( written <= MAX_SNAPSHOT_BYTES )) \
    || die "snapshot for camera $id is ${written} bytes; limit is ${MAX_SNAPSHOT_BYTES}"
  snapshot_valid "$tmp" || die "the console did not return a usable JPEG for camera $id"
  mv "$tmp" "$out"
  printf '%s\n' "$out"
}
