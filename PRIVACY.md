# Linkit Privacy

**Short version: Linkit has no servers, no accounts, and no analytics. Your data
moves directly between your phone and your Mac over your local network and is
stored only on your own devices. Nothing is ever sent to the author or any third
party.**

## What Linkit does with your data

- **Files, clipboard text, links, phone numbers, call state, and (when enabled)
  notification title/text/source-app name** travel directly between the one phone
  and the one Mac you paired, over your LAN or phone hotspot.
- There is **no cloud relay, no telemetry, and no internet data path.** The author
  cannot see any of it.
- Received files land in `Downloads/Linkit Drop` on each device. Nothing else is
  copied off-device.
- Each device's **private signing key** is generated on first run and never leaves
  the device (Mac: Keychain; Android: the Android Keystore — non-exportable, and
  hardware-backed where the device supports it).
- The in-app **debug telemetry** panel (Android) is entirely on-device — it is a
  local diagnostics view and transmits nothing.

- **Android Auto Backup is disabled** (`allowBackup="false"`), so the paired-Mac
  record and its pairing secret are never copied into a device or cloud backup. The
  Android signing key is device-bound in the Keystore and cannot be restored anyway,
  so a restored install always re-pairs from a fresh QR scan.

## In transit

- Every control request and upload after pairing is **signed** (P-256 ECDSA +
  SHA-256), so a device you didn't pair cannot inject commands or files.
- **Confidentiality:** payloads are **end-to-end encrypted** — control actions
  (clipboard, text, links, phone control) with AES-256-GCM, and **file contents**
  with AES-256-CTR — keyed from the secret in the pairing QR, both directions.
  Transfer **filenames/sizes** and control responses are still sent in cleartext
  (metadata only). See [`SECURITY.md`](SECURITY.md).

## Android permissions — why each is requested

Linkit only asks for what a given feature needs. You can decline the phone
permissions and still use file, clipboard, and link transfer.

| Permission | Why |
| --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE` | Open local TCP sockets to your paired device and detect network changes. Despite the name, traffic stays on your LAN. |
| `CHANGE_WIFI_MULTICAST_STATE`, `NEARBY_WIFI_DEVICES` | Bonjour/mDNS discovery so the apps can find each other and reconnect after a network change. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `FOREGROUND_SERVICE_SPECIAL_USE` | Run the receiver/sender so the Mac can reach the phone, with a persistent notification. |
| `WAKE_LOCK`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Keep transfers alive and resist Doze. The battery-optimization exemption is **optional** and prompted, not forced. |
| `POST_NOTIFICATIONS` | Show receiver status and transfer/clipboard action notifications. |
| Notification-listener access | Optional system grant for notification mirroring. When enabled, Linkit forwards ordinary notification title, text, and source-app name to the paired Mac; it skips Linkit's own, ongoing, foreground-service, and group-summary notifications. |
| `REQUEST_INSTALL_PACKAGES` | Let the in-app updater install a downloaded release APK (with your approval). |
| `CAMERA` | Scan the Mac's pairing QR code. Used only during pairing; no images are stored or sent. |
| `READ_PHONE_STATE` | Mirror call state (ringing/active) to your Mac. |
| `READ_CALL_LOG` | Show the incoming caller's number on your Mac. **Optional.** |
| `READ_CONTACTS` | Resolve the caller's name for the Mac incoming-call panel. **Optional.** |
| `CALL_PHONE`, `ANSWER_PHONE_CALLS` | Place/answer/end calls initiated from your Mac. **Optional.** Without `CALL_PHONE`, the dialer is opened pre-filled instead. |
| `WRITE_EXTERNAL_STORAGE` | Save received files to Downloads on older Android versions. |

Call-log, contacts, and phone-control data are used **only** to drive the
corresponding feature on your paired Mac, in real time, over the signed local link.
They are not logged off-device, not retained, and not sent anywhere else.

## macOS

- The Mac app declares Local Network usage (for discovery). Its identity key is
  stored in the macOS Keychain.
- Received files land in `~/Downloads/Linkit Drop`.

## Changes

This document describes the current behavior. Material changes will be noted in the
release notes and this file's git history.
