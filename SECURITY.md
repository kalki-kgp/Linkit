# Security Policy

Linkit is a private, cloud-free link between **one** Android phone and **one** Mac.
Security is the whole point of the project, so please read this before relying on it
for anything sensitive — and please report problems.

## Reporting a vulnerability

**Do not open a public issue for security problems.** Use GitHub's private
vulnerability reporting:

- https://github.com/kalki-kgp/Linkit/security/advisories/new

Please include the version of both apps, your OS versions, and a description of the
issue and impact. I'll acknowledge as soon as I can. This is a personal project, so
response is best-effort, but security reports take priority.

## Supported versions

Only the **latest release** receives fixes. The in-app updaters on both platforms
point at the latest GitHub release.

## What Linkit protects (and what it doesn't)

**Trust model.** Pairing is QR-only: the Mac shows a QR with its public key and a
one-time challenge; the phone scans it and signs the challenge to prove it holds the
matching private key. Manual token pairing is intentionally disabled.

**Authenticity & integrity (strong).** After pairing, every control request and
upload slot is signed with **P-256 ECDSA + SHA-256**. A receiver rejects a request
unless the device id is trusted, the timestamp is within ±60 s, the nonce is unused
(120 s window), and the signature verifies against the stored peer key. Each device's
private signing key never leaves it — macOS Keychain, and Android Keystore
(hardware-backed, sign-only). An unpaired device on your network cannot inject
commands or files.

**Confidentiality.** Transport is plain local HTTP (no TLS), but payloads are
**end-to-end encrypted**, keyed from a 32-byte secret exchanged in the pairing QR
(which travels screen-to-camera, never over the network):

- **Control actions** — clipboard text, plain text, links, and phone control
  (numbers, contact names), both directions — with **AES-256-GCM** under an
  HKDF-derived message key.
- **File-transfer contents** with **AES-256-CTR** under a per-transfer HKDF key.
  Integrity comes from the signed upload slot plus the end-to-end SHA-256 the
  receiver verifies at finalize, so a tampered stream is rejected.

Both are version-gated with no cleartext fallback. Signing protects *authenticity*;
the ciphers protect *secrecy*.

**Still in cleartext (metadata):** transfer **filenames and sizes**, history
entries, and control *responses*. File *contents* and the control payloads above are
encrypted, but a device sniffing your network can still see what filenames you move.
Closing this is a planned follow-up.

**Application distribution.** The macOS app is **ad-hoc signed but not
Apple-notarized** (notarization needs a paid Apple account). Verify what you run by
**building from source** (see `docs/SETUP.md`) if you don't want to trust the
prebuilt binary. The Android APK is signed with the project's release key; the in-app
updater verifies the downloaded artifact's SHA-256 over GitHub's HTTPS.

## Out of scope

- A compromised or rooted endpoint, or someone with physical access to an unlocked
  device.
- A malicious *paired* peer — pairing is an explicit trust decision; only pair with
  your own devices.
- Denial of service from a device already on your LAN (request size, header, and
  connection limits exist to bound it, but a hostile LAN is not the threat Linkit is
  built to defeat).

## Scope reminder

Linkit is built for one trusted phone + one Mac on a local network for personal use.
It is not a hardened multi-tenant service.
