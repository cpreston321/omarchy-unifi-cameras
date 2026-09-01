# Verifying against real hardware

Steps 1-3 and 5 are **confirmed** against UniFi Protect 7.2.105 on a UDM-class
console with a UVC G6 Pro Bullet. Step 4 is confirmed as *not possible* through
this API, and step 6 remains unverified for lack of a PTZ camera. `unifi-protect
probe` performs a raw GET and prints whatever comes back, so re-checking any of
this on different firmware takes a minute.

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

**Confirmed on 7.2.105.** The camera object carries exactly:
`activePatrolSlot, featureFlags, guid, hasPackageCamera, hdrType, id,
isMicEnabled, ledSettings, mac, micVolume, modelKey, name, osdSettings,
smartDetectSettings, state, type, videoMode`.

`featureFlags` holds `hasHdr, hasLedStatus, hasMic, hasSpeaker,
smartDetectAudioTypes, smartDetectTypes, supportFullHdSnapshot, videoModes` —
**no PTZ key of any kind**. PTZ is therefore detected from the model name in
`type`, which reads like `UVC G6 Pro Bullet` or `UVC G5 PTZ`.

## 3. Snapshots return a JPEG

```bash
unifi-protect snapshot "$(unifi-protect probe /cameras | jq -r '.[0].id')"
file ~/.cache/omarchy-unifi/snapshots/*.jpg
```

Expected: `JPEG image data`. If the body is JSON, the endpoint wants different
query parameters than `?highQuality=true`.

## 4. RTSP cannot be enabled through this API

```bash
id=$(unifi-protect probe /cameras | jq -r '.[0].id')
unifi-protect probe "/cameras/$id/rtsps-stream?qualities=high"
```

**Confirmed on 7.2.105.** The response shape is an object keyed by quality, as
the code expects — but every value is null until RTSP is enabled:

```json
{"high":null,"medium":null,"low":null,"package":null}
```

And it cannot be enabled from here. The camera object has no `channels` and no
RTSP field, and `PATCH /cameras/{id}` answers 400 for any attempt to add one:

```json
{"error":"Failed to parse 'request-body'","name":"AJV_PARSE_ERROR",
 "issues":[{"message":"must NOT have additional properties"}]}
```

So enabling RTSP is a manual, per-camera step in the Protect app:
**Protect → the camera → Settings → Advanced → RTSP**. The `enable-rtsp`
subcommand was removed because it could never have worked; `stream-url` now says
this instead of failing opaquely.

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
