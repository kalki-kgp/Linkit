# Linkit MVP

## One-line

Linkit is a lightweight, nearby-first Android to macOS transfer system for sending files between Krishna's Android phone and Mac without cloud upload, accounts, or iPhone/AirDrop dependency.

## Product Goal

Make file movement between one Android phone and one Mac feel instant, private, and boringly reliable.

The MVP is not a full sync engine. It is not a cloud drive. It is not a messaging app.

The first magic flow:

1. Android user taps Share on any file/photo/document.
2. Chooses Linkit.
3. Selects paired Mac.
4. File appears in `~/Downloads/Linkit Drop` on the Mac.

## Core Assumptions

- The Android phone and Mac are physically nearby.
- Transfers should work without internet.
- Transfers should work when both devices are on the same home Wi-Fi.
- Transfers should work when the Android phone hotspot is on and the Mac is connected to that hotspot.
- The Mac can run a tiny background menu bar app.
- The Android app should not run a permanent background service.
- The first version is built for Krishna's own devices, not the Play Store/App Store public audience.

## Non-goals For MVP

- No cloud relay.
- No account/login.
- No global internet transfer.
- No continuous folder sync.
- No notification mirroring.
- No SMS/WhatsApp integration.
- No automatic hotspot creation from inside the app.
- No Wi-Fi Direct in v1.
- No KDE Connect clone in v1.
- No huge Electron-style desktop app.

## Platforms

### Android

- Native Kotlin.
- Jetpack Compose UI.
- Android Share Target integration.
- Uses Storage Access Framework / content URIs.
- Runs transfer work only after direct user action.

### macOS

- Native Swift.
- SwiftUI for small windows.
- AppKit for menu bar, launch at login, drag/drop, notifications, and clipboard later.
- Runs a lightweight local HTTP/WebSocket server while app is open or launched at login.

## Architecture

```txt
Android Share Sheet
        |
        v
Android Linkit app
        |
        | local HTTP/WebSocket over Wi-Fi or phone hotspot
        v
macOS Linkit menu bar agent
        |
        v
~/Downloads/Linkit Drop
```

There is no external server in the MVP data path.

## Network Modes

### Mode 1: Same Wi-Fi

Both devices are connected to the same Wi-Fi router.

```txt
Android -> Wi-Fi router -> Mac
```

Data stays inside the local network. It does not consume internet data.

Discovery:

- Prefer mDNS/Bonjour.
- Android uses `NsdManager`.
- macOS advertises `_linkit._tcp.local`.

### Mode 2: Android Hotspot

Android hotspot is enabled. Mac connects to the Android hotspot.

```txt
Android hotspot -> Mac
```

This is still local device-to-device traffic. It should not consume mobile data unless the app separately calls internet APIs, which MVP will not.

Discovery:

- mDNS may be unreliable on hotspot networks.
- QR pairing and cached direct IP/port must be first-class fallbacks.
- Android app should show "Hotspot mode" connection hints.

### Mode 3: Manual IP Fallback

If discovery fails, Android can connect to the Mac using a manually entered or QR-provided IP and port.

This matters because mDNS can be flaky across routers, Android vendors, VPNs, and hotspot modes.

## Pairing

Pairing happens once.

### MVP Pairing Flow

1. Mac app shows QR code.
2. QR contains:
   - Mac device ID
   - Mac display name
   - Mac local IP
   - Mac port
   - Mac public key
   - one-time pairing token
3. Android scans QR.
4. Android calls Mac `/v1/pair`.
5. Mac shows pairing confirmation.
6. Both devices store each other's trusted public key.

### Device Identity

Each device has a long-term keypair.

Device ID:

```txt
device_id = base32(blake3(public_key))[0..32]
```

MVP can use Ed25519 keys for signing requests.

Later versions can move to mTLS or Noise.

## Security Model

MVP security priorities:

- Reject unknown devices.
- Pair explicitly.
- Never accept files from unpaired devices.
- Sign requests after pairing.
- Save files only into a known folder unless user chooses otherwise.
- Show sender, filename, size, and transfer result.

### MVP Request Authentication

Every request after pairing includes:

```txt
X-Linkit-Device-Id: <android_device_id>
X-Linkit-Timestamp: <unix_ms>
X-Linkit-Nonce: <random>
X-Linkit-Signature: sign(method + path + timestamp + nonce + body_hash)
```

Mac verifies:

- device is paired,
- timestamp is fresh,
- nonce was not reused recently,
- signature matches trusted public key.

MVP can use plain HTTP on local network plus signed requests.

Later:

- TLS with pinned self-signed certs,
- mTLS,
- Noise protocol,
- encrypted chunks.

## MVP Features

### 1. Android to Mac File Send

Required.

Input sources:

- Android Share Sheet `ACTION_SEND`.
- Android Share Sheet `ACTION_SEND_MULTIPLE`.
- In-app file picker.

Behavior:

- Read file via `ContentResolver`.
- Stream to Mac without loading full file into RAM.
- Show progress, speed, remaining time.
- Retry once on transient network failure.
- On completion, Mac writes final file atomically.

Mac destination:

```txt
~/Downloads/Linkit Drop
```

If file exists:

```txt
photo.jpg
photo (1).jpg
photo (2).jpg
```

### 2. Mac Menu Bar Agent

Required.

Menu items:

- Status: Connected / Waiting / Receiving
- Show Pairing QR
- Open Linkit Drop Folder
- Recent Transfers
- Preferences
- Quit

The menu bar app runs the local server and receives files.

### 3. Pairing UI

Required.

Mac:

- Shows QR.
- Shows incoming pair request.
- Accept/Reject buttons.

Android:

- Scan QR.
- Shows paired Mac.
- Allows forget device.

### 4. Transfer History

Required but simple.

Store locally:

- filename,
- size,
- sender,
- receiver,
- timestamp,
- status,
- saved path on Mac.

No cloud sync.

### 5. Manual Connection Fallback

Required.

Android should support:

- scan QR,
- choose discovered Mac,
- manual IP and port.

## API Sketch

### `GET /v1/info`

Returns public device info.

```json
{
  "protocolVersion": 1,
  "deviceId": "abc123",
  "deviceName": "Krishna's MacBook Air",
  "platform": "macos",
  "publicKey": "base64...",
  "capabilities": ["receive_files"]
}
```

### `POST /v1/pair`

Android requests pairing.

```json
{
  "deviceId": "phone123",
  "deviceName": "Krishna's Android",
  "platform": "android",
  "publicKey": "base64...",
  "pairingToken": "..."
}
```

### `POST /v1/transfers`

Creates a transfer session.

```json
{
  "files": [
    {
      "name": "photo.jpg",
      "size": 1234567,
      "mimeType": "image/jpeg"
    }
  ]
}
```

Response:

```json
{
  "transferId": "tr_123",
  "uploadUrl": "/v1/transfers/tr_123/files/0"
}
```

### `PUT /v1/transfers/:id/files/:index`

Streams file bytes.

Headers:

```txt
Content-Length: <size>
Content-Type: application/octet-stream
X-Linkit-File-Name: <url-encoded-name>
X-Linkit-File-Hash: <optional in MVP>
```

### `GET /v1/transfers/:id`

Returns transfer status.

```json
{
  "transferId": "tr_123",
  "status": "complete",
  "bytesReceived": 1234567,
  "savedPath": "/Users/onepiece/Downloads/Linkit Drop/photo.jpg"
}
```

### `WS /v1/events`

Later-MVP or post-MVP.

Used for live transfer state, device status, and future clipboard sync.

## Performance Targets

### Speed

Target on good 5 GHz Wi-Fi:

```txt
30-90 MB/s
```

Target on Android hotspot:

```txt
10-60 MB/s
```

Target on 2.4 GHz Wi-Fi:

```txt
3-12 MB/s
```

MVP should stream files with constant memory.

Memory target:

```txt
<= 64 MB extra memory during large transfer
```

### Battery

Android:

- No continuous scanning.
- No permanent foreground service.
- Transfer starts from user action.
- Hold wake/network lock only during active transfer if needed.
- Release immediately after completion/failure.

Mac:

- Idle menu bar agent should be negligible.
- Bonjour advertisement and local listener are acceptable.

Battery target:

- 1 GB transfer on good Wi-Fi should be under roughly 1% phone battery.
- Idle Android battery cost should be effectively zero when app is not open.

## Lightweight Constraints

### Android APK

Target:

```txt
< 20 MB APK for MVP
```

Avoid:

- Flutter,
- React Native,
- Tauri mobile,
- huge analytics SDKs,
- embedded browser UI,
- database engines unless needed.

Use:

- Kotlin,
- Jetpack Compose,
- OkHttp or Ktor client,
- ZXing/ML Kit only if QR scanning needs it.

### macOS App

Target:

```txt
< 20-30 MB app bundle if practical
```

Avoid:

- Electron.

Use:

- SwiftUI/AppKit,
- Network.framework,
- URLSession or lightweight Swift HTTP server.

## Build Order

### Phase 0: Protocol Spike

Goal: prove local transfer path.

- Tiny Mac server receives `PUT /upload`.
- Android sends one file from file picker.
- Save to `~/Downloads/Linkit Drop`.
- No pairing yet.
- Manual IP entry only.

Success:

- 1 GB file transfers without app crash.
- Progress visible on Android.
- Memory stays stable.

### Phase 1: Pairing + Trust

- Generate device keys.
- Mac QR pairing.
- Android QR scan.
- Store trusted device.
- Signed requests.

Success:

- Unpaired Android cannot send.
- Paired Android can send without re-pairing.

### Phase 2: Real UX

- Android Share Target.
- Mac menu bar app.
- Recent transfers.
- Notifications.
- Open destination folder.

Success:

- Share from Google Photos / Files / WhatsApp to Mac works.

### Phase 3: Discovery

- Mac advertises `_linkit._tcp.local`.
- Android discovers paired Mac automatically on same Wi-Fi.
- Manual IP/hotspot fallback remains.

Success:

- Same Wi-Fi flow does not need manual IP after pairing.
- Hotspot flow works with QR/cached IP.

## Post-MVP Roadmap

### Mac to Android

- Android foreground receive mode.
- Mac drag-drop menu bar window.
- Android notification to accept incoming file.
- Save via SAF-selected folder.

### Clipboard

- Text-only first.
- Explicit toggle.
- Never sync passwords by default.
- Pause button.

### Folder Drop

- Send folder as zip or recursive manifest.
- Preserve directory structure.
- Add BLAKE3 file verification.

### Resumable Transfers

- Chunked upload.
- Per-chunk hash.
- Resume failed transfer.

### Nearby Remote Mode

- Tailscale support first.
- Iroh later for encrypted QUIC, local discovery, relay fallback, and content-addressed blobs.

### USB Mode

- Optional later mode for very large transfers.
- Android Debug Bridge or MTP integration needs careful UX.

## Risks

### Android Hotspot Discovery

mDNS may fail on hotspot networks.

Mitigation:

- Manual IP fallback.
- QR includes current IP and port.
- Show "Mac connected to phone hotspot?" checklist.

### Android Background Limits

Android limits long-running background services.

Mitigation:

- Android sends from foreground/user action first.
- Mac is the always-available receiver.
- Receive-on-Android is post-MVP and explicit foreground mode.

### Local Network Permissions

macOS local network prompts and firewall can confuse users.

Mitigation:

- Trigger local network access only when user pairs or enables receiving.
- Clear permission text.
- Signed app later.

### Router Isolation

Some Wi-Fi networks block device-to-device traffic.

Mitigation:

- Phone hotspot mode.
- Manual IP diagnostics.
- Future Tailscale mode.

## Definition Of Done

MVP is done when:

- Mac app installs and runs as a menu bar app.
- Android app installs via APK.
- Mac shows pairing QR.
- Android pairs successfully.
- Android Share Sheet sends a file to Mac.
- File lands in `~/Downloads/Linkit Drop`.
- Transfer progress is visible.
- 1 GB transfer succeeds on same Wi-Fi.
- 1 GB transfer succeeds with Android hotspot and Mac connected to it.
- Unknown/unpaired devices are rejected.
- Android idle battery usage is effectively zero.
- Mac idle footprint is small enough to leave running.

## Working Name

Use `Linkit` for now.

Package/app ids can be:

```txt
Android: tech.kalkikgp.linkit
macOS: tech.kalkikgp.Linkit
Protocol: _linkit._tcp.local
Default folder: ~/Downloads/Linkit Drop
```
