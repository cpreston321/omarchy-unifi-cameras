# Security model

## What is protected, and how

**The API key never reaches argv or the environment.** `curl` gets it through a
config file on stdin (`curl --config -`), so it never appears in `/proc/<pid>/cmdline`
or `/proc/<pid>/environ` where another local user could read it. The same applies
to `secret-tool store`, which reads the key from stdin.

**A key with unexpected characters is rejected, not escaped.** The key is
interpolated into a curl config file, whose quoted values give `"` and `\` a
meaning. Rather than escape them, `api_key_valid` accepts only the URL-safe
base64 alphabet that Protect actually issues. A key containing a newline could
otherwise append arbitrary curl options — the test suite covers exactly that.

**Transport trust is a public-key pin, not a disabled check.** UniFi consoles
serve self-signed certificates for internal names, so ordinary CA verification
cannot succeed. `setup` records the leaf certificate's SHA-256 public-key
fingerprint and every later request passes it as `--pinnedpubkey`, which curl
enforces independently of `--insecure`. Replacing the console, or a machine on
the path substituting its own certificate, fails every request loudly instead of
silently trusting the new key.

**Requests cannot be redirected or proxied away.** Every call sets
`--proto '=https'`, `--noproxy '*'`, and `--no-location`, with connect and total
timeouts and a response size ceiling. A compromised or confused console cannot
redirect the plugin at a third-party host, and cannot hang the shell's process
slot or exhaust memory with an unbounded body.

**Stream URLs stay off the command line.** An RTSPS URL embeds a per-channel
alias that is itself an access grant, so it reaches mpv through a stdin playlist.
mpv runs with `--no-config --load-scripts=no --terminal=no`, so a hostile stream
cannot reach user scripts or a config the plugin did not choose.

**Ids from the console are constrained before use.** Camera ids are used to build
cache filenames and argument arrays, so the Omalaunch provider requires them to
match `^[A-Za-z0-9]{4,64}$` and drops anything else — a name like `../../etc/passwd`
never becomes a path. The test suite asserts this against a fixture that contains
one.

**Config is written atomically with restrictive modes.** `~/.config/omarchy-unifi/`
is `0700` and the config file is written `0600` to a temporary file and renamed,
so a partial write is never read back as truth.

## What is not protected

- **The Secret Service is the trust boundary for the key.** While the keyring is
  unlocked, any process running as you can read the key. That is inherent to the
  platform, not to this plugin.
- **Omarchy plugins are unsandboxed.** This plugin runs as you inside
  `omarchy-shell`, with your files and services. Read the code before enabling
  it, as with any plugin.
- **The first connection is trust-on-first-use.** The pin captured by `setup` is
  whatever the console presented at that moment. If the network was already
  hostile then, the pin records the attacker's key. Run `setup` on a network you
  trust, and compare the printed fingerprint against the console if it matters.
- **A Protect API key is not scoped per capability.** Anything the key can do on
  the console, this plugin could do. Issue a dedicated key so you can revoke it
  independently.
- **Siren, unlock, and other physical-effect endpoints are deliberately absent.**
  Nothing here can trip an alarm or open a door. Adding such a command should
  come with an explicit confirmation step.

## Reporting

Open an issue, or email the maintainer for anything you would rather not file in
public.
