# Linkit

**Drop files, text, and links between your Android phone and your Mac. Locally. Instantly. No cloud.**

Linkit is a small, private device link between one phone and one Mac. Pair once with a QR code. After that, sending a file is one tap — or one drag onto your menu bar. Clipboard text and links move across the same signed local channel. You can even place and control phone calls from your Mac, with optional Bluetooth call audio routing.

No accounts. No upload to a server. No 25 MB email limit. No "your file is too large for AirDrop." Just your phone and your Mac talking directly over your local network.

---

## Why Linkit exists

Moving a file from an Android phone to a Mac is annoyingly bad in 2026:

- **AirDrop** doesn't exist for Android.
- **Google Drive** is a round trip through a data center for two devices sitting next to each other.
- **Email / WhatsApp** silently recompresses photos and caps you at tiny sizes.
- **USB cable** works, sort of, until macOS decides it doesn't.
- **Nearby Share** wants both devices on Google's terms.

If you live in both ecosystems — Android in your pocket, Mac on your desk — none of this is acceptable. Linkit fixes that.

---

## What it does

**Phone → Mac**
- Pick a file (or 50) in the Linkit app and send.
- Tap **Share** in any Android app — Files, Gallery, WhatsApp, Chrome — and pick Linkit.
- Files land in `~/Downloads/Linkit Drop` on your Mac, with the original filename and bytes intact.
- Share plain text to Linkit to copy it onto the Mac clipboard.
- Share an `http` or `https` URL to Linkit to open it on the Mac.
- Tap **Send Clipboard** or **Open Link on Mac** in the Android app for explicit handoff.

**Mac → Phone**
- Drag files onto the Linkit icon in your menu bar.
- They land in `Downloads/Linkit Drop` on your phone, even if the Linkit app is closed.
- Use the Mac menu to send clipboard text to Android or open the clipboard URL on Android.
- Turn on clipboard text sync from the Mac menu to push Mac clipboard changes to Android.

**Phone calls from Mac**
- **Call Number on Android...** — dial from the Mac; Android places the call (or opens the dialer if permission is missing).
- **Answer**, **Decline**, and **Hang Up** when Android grants call-control permission.
- Incoming calls can show a Mac prompt with caller number and contact name when Android grants call log / contacts access.
- **Experimental:** pair over Bluetooth and route call audio to the Mac speaker/mic via Hands-Free (HFP). Cellular audio otherwise stays on the phone — normal apps cannot forward call audio over the LAN.

**Clipboard caveat:** Android 10+ limits clipboard reads to focused apps and input methods. Automatic Android → Mac clipboard sync only works while Linkit is open/focused; background copies from other Android apps need the Linkit share sheet or the explicit **Send Clipboard** button. Mac → Android clipboard sync can run from the Mac menu-bar app.

**Reconnect after network changes** — when Wi-Fi or hotspot is toggled, both apps refresh presence without re-pairing. Android rediscovers the paired Mac by name over Bonjour, verifies it with signed identity proof, and re-registers its receiver — including from the background foreground service and while the UI shows paired-but-offline. macOS persists the last-known Android endpoint, probes on network path changes, and can revive the peer when you send. No re-scanning the QR.

**Bidirectional presence** — both sides know when the peer goes away. The Mac probes Android every ~30 s; Android refreshes its Mac registration in the background and actively proves the Mac before marking it offline after ~45 s of silence. The UI on each device reflects the same connection state.

**Same local channel, either direction, within the operating-system privacy rules. That's it.**

---

## Design principles

**Local.** Transfers happen over your Wi-Fi or hotspot. Your files do not leave the room.

**Fast.** Native Swift on the Mac, native Kotlin on Android. No Electron, no React Native, no JavaScript bridge. Linkit moves a 1 GB file at the speed of your LAN.

**Verified.** Every file is hashed end-to-end while it streams. If a single byte is off, the transfer fails loudly instead of silently writing a corrupt file.

**Private.** Devices pair once with a QR code. Every request after that is signed by a key that never leaves the device — an unknown phone on your network cannot send anything. Your clipboard, links, phone data, and file contents are **end-to-end encrypted** (AES-256) with a key carried only in the pairing QR, so other devices on the same Wi-Fi can't read them either.

**Quiet.** Linkit lives in your menu bar on Mac and a single silent notification on Android. It doesn't ping you. It doesn't ask for reviews. It does its job.

---

## How pairing works

The Mac shows a QR code. The phone scans it. Done.

Behind the scenes:
- Each device generates its own private signing key the first time it runs.
- Pairing exchanges public keys over the local network with a short-lived token.
- After that, both sides remember each other forever — close the apps, reboot, switch Wi-Fi networks, it still works.
- Forget the device and pairing is gone instantly.

You can pair on home Wi-Fi, office Wi-Fi, a coffee shop hotspot, or your phone's own hotspot. Anywhere both devices can see each other.

---

## What's in the box

**macOS app** — menu-bar app. Click for paired devices, pairing QR, recent transfers, drop folder, phone controls, optional call-audio setup, in-app update check, and diagnostics. The icon animates to reflect pairing, transfer, and connection state.

**Android app** — Consumer-grade Compose UI: device hero card, action grid (send file, clipboard, link, sync, reconnect), recent activity, phone-permission status, and a quiet background receiver so the Mac can push files or signed actions at any time. The receiver notification carries **Send Clipboard** and **Open Link** action buttons so you can hand off without opening the app. A hidden debug panel (tap the **Linkit** wordmark seven times) shows process CPU, per-UID network bytes, foreground-service uptime, battery delta, reconnect/discovery events, and a log ring buffer.

---

## What's out of scope (for now)

Linkit is deliberately one thing done well. These are not in the MVP:

- Folder sync
- Resumable / chunked transfers
- Sending to multiple devices at once
- Remote transfers over the internet
- iPhone / Linux / Windows
- Play Store or notarized macOS distribution

Some of these may come later. The first version is about making one phone and one Mac feel like the same machine for local file transfer, text handoff, and phone control.

---

## Status

Open source under the **[GPLv3](LICENSE)**. **Latest release: [v0.6.1](https://github.com/kalki-kgp/Linkit/releases/latest)** (June 2026) — a signed Android APK and a macOS app (ad-hoc signed, **not** Apple-notarized — see [install notes](docs/SETUP.md#installing-the-macos-app)) on GitHub Releases, with in-app updaters on both platforms.

For the technical feature snapshot, see [`docs/current-state.md`](docs/current-state.md).

For local setup, sideloading, and build scripts, see [`docs/SETUP.md`](docs/SETUP.md).

---

## License & contact

Built by Krishna ([@kalki-kgp](https://kalkikgp.tech)). Linkit is open source under the **[GNU GPLv3](LICENSE)** — you're free to use, study, modify, and share it, but any distributed derivative must stay under the GPL (no closed-source forks). Contributions are welcome under the terms in [`CONTRIBUTING.md`](CONTRIBUTING.md). The name **"Linkit"** and its logo are trademarks of the author and are **not** licensed for use in redistributed or derivative builds — fork freely, but ship it under a different name.

Found a security issue? See [`SECURITY.md`](SECURITY.md).
