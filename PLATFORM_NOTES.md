# Platform notes

## RTSPS and mpv

Protect serves RTSPS on port 7441 with the console's self-signed certificate.
mpv plays it through FFmpeg's RTSP demuxer, which does its own TLS handling — it
does not consult the pin this plugin uses for HTTP.

**RTSP is off by default and only the Protect app can turn it on.** Verified
against 7.2.105: `GET /cameras` returns no `channels` and no RTSP field, and
`PATCH /cameras/{id}` answers 400 with `must NOT have additional properties` for
any attempt to set one. `rtsps-stream` then returns
`{"high":null,"medium":null,"low":null,"package":null}`. Enable a stream under
**Protect → the camera → Settings → Advanced → RTSP**.

If `unifi-protect play` opens mpv and then exits immediately, work through this
in order:

1. **Confirm the stream URL exists.** `unifi-protect stream-url <id> high`. If it
   reports RTSP is off, enable it in the Protect app as above.
2. **Try the URL directly.** `unifi-protect stream-url <id> high | mpv --playlist=-`.
   If that fails too, the problem is FFmpeg's TLS, not this plugin.
3. **Fall back to plain RTSP.** Some firmware also exposes the same alias over
   unencrypted RTSP on port 7447. It avoids TLS entirely, at the cost of an
   unencrypted stream on your LAN. Rewrite the URL by hand to test:
   `rtsp://<console>:7447/<alias>`.

## `--playlist=-`

The stream URL is piped to mpv rather than passed as an argument, to keep the
access-granting alias out of `/proc`. If a future mpv changes how `--playlist=-`
handles a single URL, the fallback is an IPC socket in `$XDG_RUNTIME_DIR` —
which is what the Reolink plugin this one is modeled on does.

## PTZ

Detected from the model name in `type` (for example `UVC G5 PTZ`). The
integration API's `featureFlags` carries no PTZ key at all on 7.2.105 — it holds
`hasHdr`, `hasMic`, `smartDetectTypes` and similar — so a flag-based check would
silently never fire.

Preset and patrol commands (`ptz-goto`, `ptz-patrol`, `ptz-stop`) target the
integration API's slot-based endpoints. Continuous pan/tilt/zoom — holding a
direction and releasing to stop — is deliberately not implemented: it needs a
release-to-stop guarantee and an independent safety timer, and neither is worth
shipping unverified against real hardware.

## Multi-console setups

The config holds one console. Protect adopts every camera to a single console,
so this covers the common case; a second console would need a config that is an
array and a console selector in the panel.
