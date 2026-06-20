# Linkit Current State

Last updated: 2026-06-20  
**Release:** [v0.6.1](https://github.com/kalki-kgp/Linkit/releases/tag/v0.6.1)

Linkit is a private Android + macOS local device link for one phone and one Mac. It moves files, clipboard text, plain text, links, and phone-call control directly over the local network or phone hotspot. There is no account, cloud relay, or internet data path.

> **Recent (v0.6.1):** `MacRediscovery` shared utility; receiver-service rediscovery on failed Mac registration; UI offline retry loop; persisted endpoint sync after background rediscovery.  
> **Recent (v0.6):** Phone control + caller ID; experimental Bluetooth Hands-Free call audio on Mac; Doze resistance; Mac last-known Android endpoint persistence.  
> **Earlier:** In-app updaters (v0.4+); bidirectional presence; Bonjour reconnect; consumer Compose UI; debug telemetry; clipboard notification actions; Mac→Android drops; signed pairing and uploads.

## Distribution

- **GitHub Releases** — signed `linkit-release.apk` and `linkit-macos.zip` per tag (`v0.1.0`, `v0.4.0`, `v0.5.0`, `v0.6`, `v0.6.1`, …).
- **In-app updaters** — both apps fetch `releases/latest/download/linkit-*-update.json`, verify SHA-256, and install (Android requires user approval; Mac swaps `Linkit.app` and relaunches).
- **Release CI** — `.github/workflows/release.yml` runs tests, builds both platforms, uploads assets. Use workflow dispatch with explicit `version_code` (must increase; v0.6.1 = build **7**).
- Not on Play Store; macOS app is not notarized. Personal sideload / GitHub download only.

## What Works

### Pairing And Trust

- Mac shows a QR pairing payload from the menu-bar app.
- Android scans the QR and signs a one-time pairing challenge.
- Both devices store trusted public keys after pairing.
- Manual token pairing is intentionally disabled because QR pairing proves possession of the Android private key.
- Requests after pairing are signed with P-256 ECDSA + SHA-256.
- Mac private identity key lives in Keychain (migrated from legacy `mac-identity.p256` file).

### Android To Mac Files

- Android app can pick one or more files and send them to the Mac.
- Android share sheet can send files from other apps to Linkit (content URIs passed directly to send service — no share-cache copy).
- Files land in `~/Downloads/Linkit Drop`.
- Uploads stream with constant memory and SHA-256 verification.
- Finalize is idempotent.
- Unknown/unpaired devices are rejected.
- Transfer progress, speed, ETA, success, failure, and cancel state are shown on the Mac.
- A 1 GB Android → Mac soak transfer completed with matching SHA-256 and empty `.tmp`.

### Mac To Android Files

- Drag files onto the Mac menu-bar icon to send them to the paired Android device.
- Android foreground receiver accepts signed file sessions from the Mac.
- Files land in `Downloads/Linkit Drop` on Android.
- Transfer progress, speed, ETA, success, failure, and cancel state are shown in the Mac popup.
- A 1 GB Mac → Android soak transfer completed.
- Receive path holds a partial wake lock during upload so Doze cannot suspend mid-transfer.

### Cancel

- The Mac transfer popup has a **Cancel** button.
- Mac → Android cancel aborts the local upload and sends signed `DELETE /v1/transfers/:id`.
- Android → Mac cancel marks the receiver transfer canceled and removes the temp file.

### Clipboard, Text, And Link Handoff

- Signed `POST /v1/actions` supports:
  - `clipboard` for plain-text clipboard handoff.
  - `text` for plain-text handoff.
  - `open_url` for opening `http` or `https` links on the other device.
- Mac menu can send clipboard text to Android, open the clipboard link on Android, and turn on Mac → Android clipboard text sync.
- Android app can send current clipboard text to Mac, open the current clipboard link on Mac, and turn on foreground clipboard text sync.
- Android share sheet can send selected plain text to the Mac clipboard or open shared URLs on the Mac.
- Mac receiving text sets the Mac clipboard; Android receiving text sets the Android clipboard.

Android limitation: Android 10+ does not let ordinary background apps read clipboard contents unless the app is focused or is the active input method. Mac → Android clipboard sync can run from the Mac menu-bar app; automatic Android → Mac clipboard sync is foreground-only.

### Phone Control

- Android exposes signed phone-control actions to the paired Mac:
  - `phone_call` — validates a normal phone number and starts the call on Android; without `CALL_PHONE`, opens the dialer prefilled.
  - `phone_answer` — answers a ringing call when `ANSWER_PHONE_CALLS` is granted (Android 8+).
  - `phone_decline` / `phone_hangup` — end the current call when call-control permission is granted (Android 9+).
- Android's foreground receiver service mirrors call state to the Mac with signed `phone_state` actions when `READ_PHONE_STATE` is granted.
- With `READ_CALL_LOG` and `READ_CONTACTS`, incoming calls can include caller number and resolved contact display name on the Mac.
- Mac menu **Phone** section: **Call Number on Android...**, **Answer**, **Decline**, **Hang Up**; incoming-call panel when ringing.
- Cellular call audio is **not** relayed over the signed HTTP channel — normal third-party apps cannot capture/forward cellular audio with public permissions.

### Bluetooth Call Audio (Experimental)

- Mac `HandsFreeBridge` uses `IOBluetooth` Hands-Free Profile to route call audio to Mac speaker/mic when paired.
- Android `BluetoothPairAssist` bonds to the Mac using the Bluetooth address from `GET /v1/info`.
- Mac menu: **Set Up Call Audio...**, **Move Call Audio to Mac** / **Move Call Audio to Phone**.
- Android UI can enable call audio and shows Bluetooth pairing status.
- Requires classic Bluetooth pairing between phone and Mac; separate from Wi-Fi/LAN Linkit pairing.

### Reconnect After Network Change

- Pairing trust is key-bound; only IP/port go stale when either device moves networks (e.g. hotspot → shared Wi-Fi).
- **`MacRediscovery.kt`** — Bonjour lookup filtered by paired Mac name → signed `POST /v1/identity/proof` → persist new endpoint. Mutex prevents concurrent rediscovery races.
- **Android UI (`MainActivity`):** `ConnectivityManager` callbacks and resume trigger `discoverAndReconnect()`; **Reconnect** on device card; paired-but-offline retry every ~30 s (3 × 10 s ticks); `MacPresence` listener syncs UI when the receiver service updated the stored endpoint in the background.
- **Android receiver service (`LinkitReceiverService`):** on failed verify/register at stored Mac address, runs `MacRediscovery` then re-registers; updates notification to "Listening for Mac drops" on success.
- **macOS:** `NWPathMonitor` refreshes local IP display and forces signed Android status probe; `lastKnownHost` / `receivePort` persisted per trusted Android device and used to revive sends after reconnect.
- `MacPresence.touch()` on every successful Android → Mac signed request so the UI does not stick "offline" right after a successful action.

### Bidirectional Presence Detection

- Mac: ~15 s presence sweep, ~30 s staleness threshold; stale devices probed via signed `GET /v1/devices/self/status`; failures disconnect.
- Android: foreground service refreshes Mac registration ~every 20 s; after >45 s silence the 10 s UI tick runs active Mac identity proof; success renews registration, failure shows "Paired, offline".
- Connected Android battery % shown on Mac when registered.
- Both sides usually converge within ~30–60 s of a real disconnect; restored hotspot can recover as soon as refresh or rediscovery succeeds.

### Notification Action Buttons

- Android receiver notification (`Mac drops enabled on …`) carries **Send Clipboard** and **Open Link** actions.
- Tapping launches `ClipboardActionActivity` (translucent theme, real window focus). Clipboard read deferred to `onWindowFocusChanged(true)` for Android 10+.
- Result via Toast, then activity finishes.

### Consumer UI (Android)

- Compose **Home** (focused dashboard): device card (avatar, name, pulsing status), action grid (send file, send clipboard, open link, mirror clipboard), recent activity. Top bar has the Linkit wordmark (7-tap debug) and a **gear icon**.
- **Settings screen** (pushed from the gear, system back / arrow to return) with Android-style grouped sections mirroring the Mac Settings window: Connection (status, address, reconnect/disconnect, pair with a different Mac, forget), Clipboard (persisted mirror-to-Mac toggle), Transfers (received-files location, clear recent activity), Phone, Call audio (experimental), Notifications & background (battery-optimization exemption, app notification settings), Appearance (System/Light/Dark), Updates, About (version, GitHub).
- **Preferences** persisted in `LinkitPreferences` (SharedPreferences-backed `StateFlow`): appearance theme override and clipboard-sync state. Theme follows the chosen appearance (was system-only); warm-paper Light/Dark palette from `LinkitPalette`.
- Pairing-only Welcome screen; debug IP/port/token hidden from normal use.
- Network hints when hotspot or flaky connectivity is detected.
- One-time prompts: notification permission (Android 13+), battery optimization exemption (keeps FGS + Wi-Fi alive on Doze), phone and Bluetooth permissions as needed.

### Menu Bar And UX (macOS)

- Packaged menu-bar `.app` with animated status icon (paired, transferring, success, error, pairing).
- **Popover panel** (left-click the icon): device header with name, status dot, battery, and a gear to Settings; quick-action tiles (Send File, Clipboard, Open Link); persisted clipboard-sync toggle; contextual Phone and Call Audio rows; inline transfer progress with cancel; recent transfers; footer (Pairing QR, Drop Folder, Quit). Built in SwiftUI (`LinkitPanelView`) over a `PanelViewModel` bridge. Right-click gives a minimal fallback menu (Open, Settings, Updates, Quit).
- **Settings window** (`SettingsView`, sidebar sections): General (launch at login, clipboard sync, appearance Match System/Light/Dark, transfer-received notifications), Devices (paired/connected list with disconnect/forget, pairing QR), Transfers (drop-folder location with Change…/Reset/Reveal/Open, recent transfers, transfer log), Phone & Audio, Network (listening address + custom port), Diagnostics (live status, copy report, version, check for updates), About.
- **Preferences** persisted in `UserDefaults` (`Preferences`); port and drop-folder location apply on relaunch (offered inline).
- File picker for Mac → Android sends, plus drag-and-drop onto the menu-bar icon.
- Separate **paired** vs **connected** device state in UI and trust store.

### Debug Panel (Android)

- Hidden screen: tap **Linkit** wordmark seven times within ~1.5 s windows.
- `DebugTelemetry` (process singleton): CPU time, per-UID `TrafficStats`, FGS uptime (`LinkitReceiverService`, `LinkitSendService`), battery samples, event log (120 entries), log ring buffer (500 lines).
- Controls: reset baseline, clear logs, copy report, copy `adb dumpsys batterystats` command.

### Packaging And Verification

Local builds:
```sh
./scripts/build-macos-app.sh       # -> dist/Linkit.app
./scripts/build-android-release.sh # -> dist/linkit-release.apk
./scripts/verify.sh                # swift test + Mac build + Android tests + debug APK
```

Current verification passes: `swift test`, `./gradlew testDebugUnitTest`, `./gradlew assembleDebug`, release build scripts, `git diff --check`. Release workflow also runs Mac + Android tests before upload.

## Known Limits

- One trusted phone + one Mac is the intended personal-use path.
- Each HTTP transfer session is one file; UI queues multiple files as multiple sessions.
- Android → Mac automatic clipboard sync cannot run in the background (Android clipboard privacy).
- Cellular call audio is not relayed over LAN; Bluetooth HFP is experimental and separate from Wi-Fi pairing.
- Android receive depends on the foreground receiver service (and user granting notifications / optional battery exemption).
- TLS/mTLS/Noise not implemented — local HTTP with signed control/upload requests.
- Resumable/chunked transfers, folder sync, remote internet transfer, multi-device, and non-Android/non-macOS clients not implemented.
- Play Store and notarized macOS distribution not done.

## Next Sensible Improvements

- Add SAF-selected save location for Android receives.
- Add multi-file transfer sessions instead of one session per file.
- Add WebSocket or event stream for richer live state.
- Quick Settings tile for **Send Clipboard to Mac** (notification actions already exist).
- Mirror debug telemetry into the Mac menu-bar diagnostics.
- Add CI workflow for PR test/build checks (release workflow exists; no separate PR CI yet).
