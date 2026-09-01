# Verifying against real hardware

This plugin was written against Ubiquiti's published integration API but has not
been run against a live console. `unifi-protect probe` performs a raw GET and
prints whatever comes back, so each assumption below can be confirmed or
corrected quickly. Work down the list; each step depends on the one before it.

## 1. The key and the pin work

```bash
unifi-protect check
```

Expected: one line naming your console. A TLS pin failure (curl exit 90) means
the certificate changed since `setup` — re-run `setup` to re-pin. A 401 means the
key is wrong or was revoked.

## 2. Camera fields are shaped as expected

```bash
unifi-protect probe /cameras | jq '.[0] | {id, name, state, modelKey, featureFlags}'
```

The panel and the launcher provider read `id`, `name`, and `state`, and treat
`state == "CONNECTED"` as online. The provider looks for `featureFlags.isPtz` to
decide whether to offer preset navigation. **If your firmware names the PTZ flag
differently, `bin/omalaunch-provider` needs one line changed** — it is the single
most likely mismatch in this repo.

## 3. Snapshots return a JPEG

```bash
unifi-protect snapshot "$(unifi-protect probe /cameras | jq -r '.[0].id')"
file ~/.cache/omarchy-unifi/snapshots/*.jpg
```

Expected: `JPEG image data`. If the body is JSON, the endpoint wants different
query parameters than `?highQuality=true`.

## 4. RTSP can be enabled and a URL comes back

```bash
id=$(unifi-protect probe /cameras | jq -r '.[0].id')
unifi-protect enable-rtsp "$id" high
unifi-protect probe "/cameras/$id/rtsps-stream?qualities=high"
```

The code expects an object keyed by quality (`{"high": "rtsps://…"}`). If it is
an array or nests the URL, `cmd_stream_url` in `bin/unifi-protect` needs its `jq`
expression adjusted.

Also confirm the PATCH body shape: the code sends
`{"channels":[{"id":0,"isRtspEnabled":true}]}` and assumes channel 0/1/2 map to
high/medium/low. Compare against `probe /cameras | jq '.[0].channels'`.

## 5. Events come back in the window asked for

```bash
unifi-protect events 120
```

The code passes millisecond epochs as `start` and `end` and reads `.start`,
`.type`, and `.camera` from each entry.

## 6. PTZ presets, if you have a PTZ camera

```bash
unifi-protect ptz-goto <ptz-id> 0
```

The slot-based endpoints are the least-documented part of the integration API. If
these 404, capture the response and open an issue — the paths are one-liners in
`bin/unifi-protect`.

## Reporting what you found

Please include the firmware version from `unifi-protect check`, the camera model,
and the raw `probe` output with ids redacted. That is enough to fix a shape
mismatch without access to the hardware.
