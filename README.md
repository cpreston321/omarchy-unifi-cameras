# UniFi Cameras for Omarchy

A local-first Omarchy plugin for UniFi Protect. Snapshots and live view for
every camera on your console, from the bar or from Omalaunch — using Protect's
official local integration API, an API key stored in the Secret Service, and a
pinned certificate. No Ubiquiti account, no cloud round-trip, no camera daemon
added to Omarchy.

> **Status: `0.1.0` is unverified against hardware.** Every endpoint below is
> implemented and the whole offline surface is tested, but the author has not
> yet run it against a live console. See
> [docs/verifying-against-hardware.md](docs/verifying-against-hardware.md) —
> `unifi-protect probe` exists to make that a ten-minute job.

## Requirements

Everything is stock on Omarchy: `curl`, `jq`, `openssl`, `secret-tool` (GNOME
Keyring), `mpv`, `python3`. Nothing extra to install.

On the console side you need **UniFi Protect 5.3 or newer** on UniFi OS, which
is where the local integration API and API keys landed.

## Installation

```bash
omarchy plugin add https://github.com/cpreston/omarchy-unifi-cameras --enable
```

Then create an API key on the console — **UniFi OS → Control Plane →
Integrations → Create API Key** — and connect:

```bash
~/.config/omarchy/plugins/quantumfire.unifi-cameras/bin/unifi-protect setup 192.168.1.1
```

`setup` reads the console's certificate, stores its public-key fingerprint,
prompts for the API key, saves the key in the Secret Service, and verifies the
connection. You can also do all of this from the launcher: type `unifi` in
Omalaunch and pick **Connect a console…**.

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
unifi-protect events [minutes]     # recent motion, rings, smart detections
unifi-protect ptz-goto <id> <slot> # PTZ preset
unifi-protect probe /cameras       # raw API response
```

`unifi-protect` with no arguments lists everything.

## Widget settings

Set on the bar entry in `~/.config/omarchy/shell.json`:

| Key              | Default | Meaning                                  |
|------------------|---------|------------------------------------------|
| `quality`        | `high`  | Stream quality for click-to-watch        |
| `refreshSeconds` | `30`    | Snapshot refresh interval while open     |

## Live video

Protect ships with RTSP **disabled on every channel**, so the first `play` for a
given camera and quality turns that channel on (`isRtspEnabled`) before asking
for a stream URL. Streams are RTSPS on port 7441 and the URL carries a
per-channel alias that grants access — so it goes to mpv through a stdin
playlist rather than the command line, where another user could read it.

If mpv fails to open the stream, that is the first thing to debug; see
[PLATFORM_NOTES.md](PLATFORM_NOTES.md).

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
