# Linkit Current State

Last updated: 2026-06-29  
**Release:** [v0.6.1](https://github.com/kalki-kgp/Linkit/releases/tag/v0.6.1)

Linkit is a private Android + macOS local device link for one phone and one Mac. It moves files, clipboard text, plain text, links, and phone-call control directly over the local network or phone hotspot. There is no account, cloud relay, or internet data path.

> **Unreleased (`feat/mac-calling` branch):** **Bluetooth Hands-Free call audio removed** on both platforms — it could never deliver Mac-side audio on Apple Silicon (SCO unsupported), so all call-audio routing UI/logic is gone (placing/answering Android calls from the Mac still works; audio stays on the phone). Mac call picker now surfaces the Android phone-permission precondition. The Mac transfer notification is a **free-floating panel** (consistent position over full-screen apps) you can **drag the received file out of**, with a manual close button. Android moved **Phone controls** and **Notifications & background** out of Settings onto the Home screen. New Mac **Appearance** settings: customizable accent color (preset swatches + custom picker) replacing the fixed amber scheme. The Mac **Settings window was redesigned** into an accent-driven liquid-glass layout (custom sidebar + card rows, translucent `NSVisualEffectView` materials extending under the title bar). **Recent transfers are now draggable everywhere** — both the Settings → Transfers list and the menu-bar popover RECENT list are file drag sources (click still opens). On Android, **received files in Recent are tappable to open** (resolved via the stored content URI). The Mac now **posts a notification when a call starts on the phone** (an outgoing/active call the Mac didn't place).  
> **Unreleased (Android UI port):** the Android app was **restyled to match the Mac app** — accent-driven cards (`LinkitDesign.kt`: `SettingsGroupCard` / `LinkitCardRow` / `LinkitToggleRow` / `IconTile`), an accent-gradient device avatar, Mac-style quick-action tiles + a clipboard-sync toggle row on Home, and a card-language Settings screen. A **user-customizable accent color** (9 preset swatches matching the Mac + a custom `#RRGGBB` field, default `#D16B1F`) is stored in `LinkitPreferences.accentColorHex` and threaded through `LinkitTheme`'s primary, so cards, toggles, tiles, and status dots recolor — mirroring `Preferences.accentColorHex` on the Mac. The app was then **re-architected for wayfinding**: a persistent **bottom-navigation shell** (Home · Activity · Settings) replaces the single-scroll model, and Settings became a **hub of categories that drill into focused detail screens** (mirroring the Mac Settings sidebar) instead of one long page. Material Symbols vector icons throughout (no emoji).  
> **Unreleased (feature-status work):** both apps now compute and **exchange a per-feature health snapshot** so each device shows the *other* device's self-reported status (one synced source of truth). The Android notification-mirror listener now tracks its real bind state and **force-rebinds after a reboot/update** (`NotificationMirrorState` + `requestRebind`), fixing the "mirroring silently stopped after I restarted" bug — the status now reads "On, but not receiving" and is re-enablable in one tap. Feature health rides the existing exchange (Android → Mac in the `GET /v1/devices/self/status` response and the `POST /v1/devices/self` registration body; Mac → Android in the registration response) — no new routes. Surfaces: Android Settings **Feature status** group + a Home "needs attention" banner; Mac Settings → Diagnostics **Phone status** group + a popover attention row.  
> **Unreleased (`security/open-source` branch):** wire payloads are now **end-to-end encrypted** — control actions via AES-256-GCM and file contents via AES-256-CTR, keyed from the pairing-QR secret (`LinkitSecretBox` / `LinkitWireCrypto` / `LinkitStreamCipher`, cross-language golden-vector tested, device-validated to 1 GB+). Also: GPLv3 relicense + `CONTRIBUTING`/`SECURITY`/`PRIVACY`; PR CI; Mac HTTP read-timeout + connection cap; ad-hoc Mac codesign; Android Settings screen + theme.  
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
- With `READ_CALL_LOG` and `READ_CONTACTS`, incoming calls can include caller number and resolved contact display name on the Mac, and the Mac call picker can list phonebook contacts and recent calls (fetched over signed `/v1/phonebook`, kept in memory only).
- Mac menu **Phone** section: **Call a Number…** (opens a search-as-you-type picker over contacts/recents, or dial a typed number), **Answer**, **Decline**, **Hang Up**; incoming-call panel when ringing.
- When a call **starts on the phone** (goes active without first ringing and the Mac didn't place it — i.e. an outgoing call dialed on Android), the Mac posts a "Call on your phone" notification with the caller name/number when available. Calls placed from the Mac (which already show the call panel) and incoming calls answered on the phone (`ringing → active`) are excluded.
- The call picker surfaces the phone-permission precondition: when Contacts / Call log aren't granted on Android it explains how to enable them ("open Linkit and tap *Enable phone controls*"), instead of silently showing an empty list.
- Cellular call audio is **not** relayed — audio always stays on the phone. Normal third-party apps cannot capture/forward cellular audio with public permissions, so there is no Mac-side call-audio path (the experimental Bluetooth Hands-Free route was removed; see the unreleased note).

### Feature Status & Health

- Each device computes a **per-feature health snapshot** (`FeatureStatus.kt` / `FeatureStatus.swift`): a list of `{id, title, state, detail}` where `state ∈ on | off | attention | unsupported`. `attention` means the user wants a feature on but it is broken (missing permission, an unbound listener, a stopped service).
- Android reports: notification mirroring, clipboard sync, phone controls, background receiver (FGS), and battery-optimization exemption. Status uses live runtime signals — real notification-listener bind state, granted permissions, whether `LinkitReceiverService` is running — not just persisted toggles, so a silently-stopped feature reports `attention` instead of a misleading `on`.
- Mac reports: clipboard sync, launch at login, transfer notifications (macOS authorization), and the receiver.
- The snapshots are **exchanged over the existing presence/registration cadence** (no new endpoints): Android → Mac in the `GET /v1/devices/self/status` response and the `POST /v1/devices/self` registration body; Mac → Android in the registration response. Each app renders both its own and the peer's self-reported health.
- **Notification-mirror reboot fix:** `NotificationMirrorService` overrides `onListenerConnected/onListenerDisconnected` to track real bind state (`NotificationMirrorState`) and calls `requestRebind`; `NotificationAccess.ensureListenerBound` re-binds a granted-but-dropped listener on app resume, receiver-service start, and when mirroring is toggled on. The OS keeps the permission grant across reboots but does not always rebind the listener — this recovers it without the user re-toggling.
- Surfaces: Android **Settings → Feature status** (This phone + Your Mac, tap an `attention` row to jump to the OS setting that fixes it) and a Home **needs-attention banner**; Mac **Settings → Diagnostics → Phone status** and a **popover attention row** linking to Diagnostics.

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

- **Bottom-navigation shell** (`TopTab` = Home · Activity · Settings) — a persistent Material3 `NavigationBar` is the always-visible map (Android's answer to the Mac Settings sidebar). System back walks the hierarchy: detail → hub, then any tab → Home, then exit. Nav state survives config changes via `rememberSaveable`.
- Compose **Home** (control surface, kept short): Linkit wordmark (7-tap debug), device card (accent-gradient laptop avatar, name, pulsing status, reconnect), the action grid (send file, send clipboard, open link) + clipboard-sync toggle, and a compact **Feature status** card at the bottom. Each feature is one line (title + status dot: green on / red attention / grey off); a feature with a problem gets a **red dot + red chevron** and, on tap, a dialog explaining the issue with a single **Fix** action (notification-listener rebind / permission request / battery-exemption / receiver-restart). Recent activity and the phone/notification/background config live in the Activity and Settings tabs.
- **Activity** tab: received-files save location + recent transfers (**received, completed rows are tappable to open** — fires `ACTION_VIEW` on the stored content URI: the `MediaStore` Downloads URI on API 29+, a `FileProvider` URI on the legacy path), with Clear.
- **Settings** tab = **hub → detail** (`SettingsRoute`): a short hub of categories (Device, Clipboard, Notifications, Phone, Appearance, Background & battery, Updates, About) that each drill into a focused detail screen with a back arrow + large header (`SettingsDetailScaffold`) — mirroring the Mac Settings sidebar sections instead of one long scroll. **Device** detail = connection (status, address, reconnect/disconnect, pair with a different Mac, forget); cross-device feature-status health now lives on **Home** instead. **Appearance** = accent color (9 preset swatches + custom `#RRGGBB`, default `#D16B1F`) and theme (System/Light/Dark).
- **Preferences** persisted in `LinkitPreferences` (SharedPreferences-backed `StateFlow`): appearance theme override and clipboard-sync state. Theme follows the chosen appearance (was system-only); warm-paper Light/Dark palette from `LinkitPalette`.
- Pairing-only Welcome screen; debug IP/port/token hidden from normal use.
- Network hints when hotspot or flaky connectivity is detected.
- One-time prompts: notification permission (Android 13+), battery optimization exemption (keeps FGS + Wi-Fi alive on Doze), and phone permissions (call, phone state, contacts, call log) as needed. Bluetooth permissions were dropped with the call-audio feature.

### Menu Bar And UX (macOS)

- Packaged menu-bar `.app` with animated status icon (paired, transferring, success, error, pairing).
- **Popover panel** (left-click the icon): device header with name, status dot, battery, and a gear to Settings; quick-action tiles (Send File, Clipboard, Open Link); persisted clipboard-sync toggle; contextual Phone row (Call a Number…, Answer/Decline/Hang Up); inline transfer progress with cancel; recent transfers (each row is a **file drag source** — drag a received file straight into Finder/another app, click still opens); footer (Pairing QR, Drop Folder, Quit). Built in SwiftUI (`LinkitPanelView`) over a `PanelViewModel` bridge. Right-click gives a minimal fallback menu (Open, Settings, Updates, Quit).
- **Transfer notification** (`LinkitTransferPanel`): a free-floating `NSPanel` pinned to the top-right of the active screen at status-bar window level (`canJoinAllSpaces` + `fullScreenAuxiliary`), so it appears in the same place whether or not another app owns the menu bar / is full-screen. Completed Android → Mac files can be **dragged straight out of the notification** into Finder or any app (the card becomes a copy drag source showing the file icon). A close button dismisses it; it otherwise auto-dismisses 5 s after completion.
- **Settings window** (`SettingsView`): accent-driven **liquid-glass** redesign — custom dark sidebar (brand header + icon tabs with an accent gradient selection pill) and a card-style detail pane, both backed by translucent `NSVisualEffectView` materials (`.sidebar` / `.underWindowBackground`) that extend under the transparent title bar (`fullSizeContentView`). Sections: General (launch at login, clipboard sync, transfer-received notifications), **Appearance** (accent color — 9 preset swatches + custom `ColorPicker` with live preview, plus window theme Match System/Light/Dark), Devices (paired/connected list with disconnect/forget, pairing QR), Transfers (drop-folder location with Change…/Reset/Reveal/Open, recent transfers — **drag a row out to copy the file**, transfer log), Phone & Audio, Network (listening address + custom port), Diagnostics (live status, copy report, version, check for updates), About. Drag uses an AppKit `NSDraggingSource` overlay (`FileDragOverlay`), the same mechanism as the transfer notification panel.
- **Accent color** is user-customizable (`Preferences.accentColorHex`, default amber `#D16B1F`); the popover and call picker recolor to the chosen accent. The menu-bar icon stays a monochrome template that follows the system tint.
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
- Cellular call audio is not relayed — it always stays on the phone. (The experimental Bluetooth Hands-Free route was removed; it could not deliver Mac-side audio on Apple Silicon.)
- Android receive depends on the foreground receiver service (and user granting notifications / optional battery exemption).
- No TLS/mTLS/Noise — plain local HTTP, but payloads are app-layer encrypted (AES-256-GCM control actions, AES-256-CTR file contents) over signed requests. Transfer filenames/sizes and control responses are still cleartext.
- Resumable/chunked transfers, folder sync, remote internet transfer, multi-device, and non-Android/non-macOS clients not implemented.
- Play Store and notarized macOS distribution not done.

## Next Sensible Improvements

- Add SAF-selected save location for Android receives.
- Add multi-file transfer sessions instead of one session per file.
- Add WebSocket or event stream for richer live state.
- Quick Settings tile for **Send Clipboard to Mac** (notification actions already exist).
- Mirror debug telemetry into the Mac menu-bar diagnostics.
- Add CI workflow for PR test/build checks (release workflow exists; no separate PR CI yet).
