# Linkit Current State

Last updated: 2026-05-24

> Recent additions: in-app Reconnect via Bonjour after network change; bidirectional presence detection; consumer Compose redesign; clipboard-action buttons on the receiver notification; hidden debug telemetry panel (7-tap unlock).

Linkit is a private Android + macOS local device link for one phone and one Mac. It moves files, clipboard text, plain text, and links directly over the local network or phone hotspot. There is no account, cloud relay, or internet data path.

## What Works

### Pairing And Trust

- Mac shows a QR pairing payload from the menu-bar app.
- Android scans the QR and signs a one-time pairing challenge.
- Both devices store trusted public keys after pairing.
- Manual token pairing is intentionally disabled because QR pairing proves possession of the Android private key.
- Requests after pairing are signed with P-256 ECDSA + SHA-256.

### Android To Mac Files

- Android app can pick one or more files and send them to the Mac.
- Android share sheet can send files from other apps to Linkit.
- Files land in `~/Downloads/Linkit Drop`.
- Uploads stream with constant memory and SHA-256 verification.
- Finalize is idempotent.
- Unknown/unpaired devices are rejected.
- Transfer progress, speed, ETA, success, failure, and cancel state are shown on the Mac.
- A 1 GB Android -> Mac soak transfer completed with matching SHA-256 and empty `.tmp`.

### Mac To Android Files

- Drag files onto the Mac menu-bar icon to send them to the paired Android device.
- Android foreground receiver accepts signed file sessions from the Mac.
- Files land in `Downloads/Linkit Drop` on Android.
- Transfer progress, speed, ETA, success, failure, and cancel state are shown in the Mac popup.
- A 1 GB Mac -> Android soak transfer completed.

### Cancel

- The Mac transfer popup has a **Cancel** button.
- Mac -> Android cancel aborts the local upload and sends signed `DELETE /v1/transfers/:id`.
- Android -> Mac cancel marks the receiver transfer canceled and removes the temp file.

### Clipboard, Text, And Link Handoff

- Signed `POST /v1/actions` supports:
  - `clipboard` for plain-text clipboard handoff.
  - `text` for plain-text handoff.
  - `open_url` for opening `http` or `https` links on the other device.
- Mac menu can:
  - send clipboard text to Android;
  - open the clipboard link on Android;
  - turn on Mac -> Android clipboard text sync.
- Android app can:
  - send current clipboard text to Mac;
  - open the current clipboard link on Mac;
  - turn on foreground clipboard text sync.
- Android share sheet can:
  - send selected plain text to the Mac clipboard;
  - open shared `http` or `https` URLs on the Mac.
- Mac receiving text sets the Mac clipboard.
- Android receiving text sets the Android clipboard.

Android limitation: Android 10+ does not let ordinary background apps read clipboard contents unless the app is focused or is the active input method. Therefore Mac -> Android clipboard sync can run from the Mac menu-bar app, but automatic Android -> Mac clipboard sync is foreground-only. Background Android copies should use the Linkit share sheet or the explicit **Send Clipboard** button.

### Phone Control

- Android exposes signed phone-control actions to the paired Mac:
  - `phone_call` validates a normal phone number and starts the call on Android. If direct-call permission is not granted, Android opens the dialer with the number filled in.
  - `phone_answer` answers a ringing Android call when Android grants call-control permission.
  - `phone_decline` and `phone_hangup` end the current Android call when Android grants call-control permission.
- Android's foreground receiver service mirrors call state to the Mac with signed `phone_state` actions when `READ_PHONE_STATE` is granted.
- Mac menu shows a **Phone** section with **Call Number on Android...**, **Answer Android Call**, **Decline Android Call**, and **Hang Up Android Call**.
- Incoming Android calls can show a Mac prompt with Answer / Decline / Dismiss.

Call audio is not relayed to the Mac. Normal third-party Android apps cannot capture and forward cellular call audio with public permissions, so Linkit currently controls calls while audio remains routed on Android.

### Reconnect After Network Change

- Android remembers the paired Mac across Wi-Fi/hotspot toggles.
- On app open/resume, Android filters Bonjour for the paired Mac name, then verifies the candidate with signed Mac identity proof (`POST /v1/identity/proof`) before updating the stored IP/port and re-registering. No re-scan of the QR is required.
- A **Reconnect** button on the device card runs the same flow on demand.
- `MacPresence.touch()` fires on every successful Android → Mac signed request (register, action, finalize), so the UI cannot get stuck in "offline" right after a successful action.

### Bidirectional Presence Detection

- Mac runs a 15 s presence sweep with 30 s staleness threshold (`Timer.scheduledTimer`, tolerance 3 s). Stale connected devices are probed via signed `GET /v1/devices/self/status`; failures trigger `disconnectDevice`.
- Android records each signed Mac request in `MacPresence`; after > 90 s of silence, the 10 s tick runs active Mac identity proof and only demotes the connection to "Paired, offline" if that proof fails.
- The Mac usually converges within ~30-45 s of a real Android disconnect; Android waits for the ~90 s stale window, then demotes only after active Mac proof fails.

### Notification Action Buttons

- The Android receiver notification (`Mac drops enabled on …`) carries **Send Clipboard** and **Open Link** action buttons.
- Tapping launches `ClipboardActionActivity` (translucent theme, real window focus). The clipboard read is deferred to `onWindowFocusChanged(hasFocus = true)` so Android 10+ grants access.
- Result is reported via a Toast, then the activity finishes.

### Consumer UI Redesign (Android)

- Compose home built around a single Device card (avatar + name + pulsing status line) and a 4-tile action grid (Send file, Send clipboard, Open link, Clipboard sync).
- Recent activity list replaces the previous debug-style metrics row.
- A warm-paper Light/Dark palette derived from custom `LinkitPalette` tokens.
- Pairing-only state shows a Welcome screen; debug/dev fields (IP, port, token) are no longer visible in normal use.

### Debug Panel (Android)

- Hidden screen launched by tapping the **Linkit** wordmark seven times within ~1.5 s windows.
- `DebugTelemetry` is a process-scoped singleton that exposes:
  - CPU time via `android.os.Process.getElapsedCpuTime()` (since process start and since baseline)
  - Per-UID network bytes via `TrafficStats.getUidRxBytes/getUidTxBytes(uid)`
  - Foreground-service uptime windows (`LinkitReceiverService`, `LinkitSendService`)
  - System battery samples on service start/stop + on demand
  - Event log (reconnect, discovery, presence, fgs, client calls) — last 120 entries
  - Log ring buffer — last 500 lines
- Controls: **Reset baseline**, **Clear logs**, **Copy full report**, **Copy `adb dumpsys batterystats` command** (`adb shell dumpsys batterystats --charged tech.kalkikgp.linkit`).
- In-app numbers are proxies; ground-truth mAh attribution still requires the adb command on a host machine.

### Menu Bar And UX

- Mac runs as a packaged menu-bar `.app`.
- Menu shows connected and paired devices.
- Menu includes pairing QR, transfer progress, drop folder, diagnostics, transfer log, preferences, launch-at-login toggle, recent transfers, clipboard actions, and refresh.
- Mac private identity key is stored in Keychain with migration from the old `mac-identity.p256` file.
- Packaged app supports launch at login.
- Android app has hotspot/flaky-network hints.

### Packaging And Verification

- Local macOS app build: `dist/Linkit.app`
- Signed Android release APK: `dist/linkit-release.apk`
- Debug APK: `android/app/build/outputs/apk/debug/app-debug.apk`
- Current verification has passed:
  - `swift test`
  - `./gradlew testDebugUnitTest`
  - `./gradlew assembleDebug`
  - `./scripts/build-macos-app.sh`
  - `./scripts/build-android-release.sh`
  - `git diff --check`

## Known Limits

- One trusted phone + one Mac is the intended personal-use path.
- Each HTTP transfer session is still one file; UI queues multiple files by sending multiple sessions.
- Android -> Mac automatic clipboard sync cannot run in the background because of Android clipboard privacy rules.
- Android phone call audio relay is not implemented; current phone support is call control only.
- Android receive still depends on the foreground receiver service.
- TLS/mTLS/Noise is not implemented; traffic is local HTTP with signed control/upload requests.
- Resumable/chunked transfers are not implemented.
- Folder sync is not implemented.
- Remote internet transfer is not implemented.
- Public distribution, Play Store release, notarized macOS app, and CI are not done.

## Next Sensible Improvements

- Add SAF-selected save location for Android receives.
- Add multi-file transfer sessions instead of one session per file.
- Add WebSocket or event stream for richer live state.
- Add a Quick Settings tile for **Send Clipboard to Mac** (notification action buttons already exist).
- Mirror the Debug telemetry panel into the Mac menu-bar app (Option-click → diagnostics) with `proc_pid_rusage` and `powermetrics` callouts.
- Add CI for Swift and Android test/build checks.
