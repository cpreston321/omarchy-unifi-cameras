# UniFi Cameras for Omarchy

A local-first Omarchy plugin for UniFi Protect. Snapshots and live view for
every camera on your console, from the bar or from Omalaunch — using Protect's
official local integration API, an API key stored in the Secret Service, and a
pinned certificate. No Ubiquiti account, no cloud round-trip, no camera daemon
added to Omarchy.

> **Status: `0.1.0`, verified against UniFi Protect 7.2.105.** Setup, camera
> listing, snapshots, and the panel are confirmed working on real hardware.
> Live video is confirmed working through mpv (HEVC 4K over RTSPS) once RTSP is
> enabled per camera in the Protect app — see [Live video](#live-video). PTZ is
> still unverified for lack of a PTZ camera, and the integration API exposes no
> events collection on this firmware.
> [docs/verifying-against-hardware.md](docs/verifying-against-hardware.md)
> records what each endpoint actually returned.

## Requirements

Everything is stock on Omarchy: `curl`, `jq`, `openssl`, `secret-tool` (GNOME
Keyring), `mpv`, `python3`, `ffmpeg`. `qt6-multimedia` is optional and only adds
in-panel video; the plugin works without it.

On the console side you need **UniFi Protect 5.3 or newer** on UniFi OS, which
is where the local integration API and API keys landed.

## Installation

```bash
omarchy plugin add https://github.com/cpreston/omarchy-unifi-cameras --enable
```

Then create an API key on the console — **UniFi OS → Control Plane →
Integrations → Create API Key** — and connect:

```bash
~/.config/omarchy/plugins/quantumfire.unifi-cameras/bin/unifi-protect setup
```

With no address, `setup` scans the network and offers what it finds, so you do
not have to go looking for your console's IP. It identifies one by asking the
integration API for `/meta/info` without a key: only Protect answers that path
with a 401. Pass an address to skip the scan.

It then reads the console's certificate, stores its public-key fingerprint,
prompts for the API key, saves the key in the Secret Service, and verifies the
connection. `unifi-protect scan` runs discovery on its own.

You can do all of this from the launcher instead: type `unifi` in Omalaunch,
pick **Connect a console…**, and press Enter to scan.

## Using it

**From the bar.** Click the camera icon for a grid of snapshots, refreshed
every 30 seconds while the panel is open. Click a camera to watch it in mpv;
right-click to save a still into `~/Pictures/UniFi/<date>/`.

**From Omalaunch.** Type `cam` for the camera list, then pick Live view, a
low-bandwidth stream, a snapshot, or — on PTZ models — a preset slot. The
camera list comes from a local cache, so the launcher never blocks on the
network. Refresh it from the bar panel or with `unifi-protect refresh`.

**From a terminal.**

```
unifi-protect cameras              # id, state, name
unifi-protect play <id> [quality]  # live view in mpv
unifi-protect snapshot <id>        # JPEG into the cache
unifi-protect export <id>          # JPEG into ~/Pictures/UniFi/
unifi-protect ptz-goto <id> <slot> # PTZ preset
unifi-protect scan                 # find consoles on this network
unifi-protect probe /cameras       # raw API response
```

`unifi-protect` with no arguments lists everything.

## Widget settings

Set on the bar entry in `~/.config/omarchy/shell.json`:

| Key              | Default | Meaning                                  |
|------------------|---------|------------------------------------------|
| `quality`        | `high`  | Stream quality handed to mpv             |
| `panelQuality`   | `medium`| Stream quality for in-panel live video    |
| `refreshSeconds` | `30`    | Snapshot refresh interval while open     |

## Live video

Protect ships with RTSP **disabled on every camera**, and the local integration
API cannot turn it on: the camera object it exposes has no channels and no RTSP
field, and `PATCH /cameras/{id}` rejects both. So enabling it is a one-time
manual step per camera:

**Protect → the camera → Settings → Advanced → RTSP → enable a stream.**

Until then the panel shows that camera as refreshing stills rather than live
video, and says so. Once enabled, streams are RTSPS on port 7441 and the URL
carries a per-camera alias that grants access — so it reaches both mpv and the
in-panel player without ever passing through a command line another user could
read.

**Live Video** plays the camera in the panel, and the **expand control** in the
top-right of the picture hands the full-resolution stream to mpv.

Getting video into the panel takes one indirection. FFmpeg verifies peer
certificates by default, a UniFi console serves a self-signed one, and Qt
Multimedia offers no way to skip that — so `unifi-protect relay` has ffmpeg do
the TLS and remux the stream (copy, not re-encode) to MPEG-TS over HTTP bound
to `127.0.0.1`. The panel starts it on a press and stops it whenever live view
ends. The HTTP API keeps its certificate pin throughout, which is where
credentials actually travel.

The panel uses the medium substream by default rather than making the console
push 4K into a few hundred pixels; mpv gets the configured `quality`. In-panel
video needs `ffmpeg` and `qt6-multimedia`; without either, the stage falls back
to one-second stills, says so, and nothing else is affected.

## Storage

| What | Where |
|------|-------|
| Console host, port, certificate pin | `~/.config/omarchy-unifi/config.json` |
| Cached snapshots and camera list | `~/.cache/omarchy-unifi/` |
| Exported stills | `~/Pictures/UniFi/<date>/` |
| API key | Secret Service, `application=omarchy-unifi kind=api-key host=<host>` |

`unifi-protect forget` removes all four.

## Security

Short version: the key never appears in argv or the environment, transport trust
is a public-key pin rather than a disabled certificate check, and the plugin
makes no outbound connection other than to your console. The details, including
what this design does *not* protect against, are in [SECURITY.md](SECURITY.md).

## Tests

```bash
./tests/run-tests.sh
```

Fully offline: manifest validation, both Omalaunch extension definitions checked
against Omalaunch's own `normalizeExtension`, provider behavior against
fixtures, API-key format guards, `qmllint`, and shell syntax.

## Credit

The shape of this plugin — bar widget plus panel, bash helpers over `curl`, keys
in the Secret Service, mpv fed off-argv — follows
[omarchy-reolink-cameras](https://github.com/rodrix2000/omarchy-reolink-cameras)
by rodrix2000, which worked out that design first for Reolink hardware.

## License

MIT.
