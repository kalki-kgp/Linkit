# Linkit Current State

Last updated: 2026-07-13
**Release:** [v0.9.1](https://github.com/kalki-kgp/Linkit/releases/tag/v0.9.1)

Linkit is a private Android + macOS local device link for one phone and one Mac. It moves files, clipboard text, plain text, links, and phone-call control directly over the local network or phone hotspot. There is no account, cloud relay, or internet data path.

v0.9.1 ships the Android Home feature-status compact list and tap-to-resolve dialog. The earlier v0.9 releases shipped the bottom-navigation Android UI, customizable accent color, live cross-device feature health, and notification-listener rebind recovery. These are release features, not branch-only work.

## Distribution

- **GitHub Releases** — signed `linkit-release.apk` and `linkit-macos.zip` per tag; the current release is v0.9.1.
- **In-app updaters** — both apps fetch `releases/latest/download/linkit-*-update.json`, verify SHA-256, and install (Android requires user approval; Mac swaps `Linkit.app` and relaunches).
- **CI** — `.github/workflows/ci.yml` runs `./scripts/verify.sh` on pull requests and pushes to `main`. `.github/workflows/release.yml` runs platform tests, builds both platforms, and uploads assets. Use workflow dispatch with an explicit, increasing `version_code` (v0.9.1 = build **18**).
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
- Mac menu turns Mac → Android clipboard text sync on and off from the **Clipboard** quick-action tile. (The Mac → Android "open link" popover action was removed — it went unused; Android → Mac link opening is unaffected. The separate manual "send clipboard now" action was removed too: macOS lets Linkit read the pasteboard in the background, so an active sync already pushes every copy.) Mac → Android clipboard sync is a **sticky preference**: the poll skips sends while the phone is unreachable and a transient failure never disables it, so it survives reconnects (a failed send previously toggled the preference off).
- Android app can send current clipboard text to Mac, open the current clipboard link on Mac, and turn on foreground clipboard text sync.
- Android share sheet can send selected plain text to the Mac clipboard or open shared URLs on the Mac. `ShareTargetActivity` is `windowNoDisplay`, which the framework requires to `finish()` before `onResume()` completes — so every branch queues work on `LinkitSendService` (files *and* `text`/`open_url`) and finishes synchronously. Doing the handoff on a thread and finishing in its callback crashed the app on every shared link.
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
- **Stale call panel on disconnect:** the Mac call panel is closed and its per-call flags reset whenever the phone drops off (`teardownCallUIForLostConnection`, driven from `checkForTrustChanges` when the connected set empties). Without this a call panel raised while connected would linger after a mid-call disconnect — no further `phone_state` arrives to close it and Hang Up can't reach the phone — previously forcing an app relaunch.

### Feature Status & Health

- Each device computes a **per-feature health snapshot** (`FeatureStatus.kt` / `FeatureStatus.swift`): a list of `{id, title, state, detail}` where `state ∈ on | off | attention | unsupported`. `attention` means the user wants a feature on but it is broken (missing permission, an unbound listener, a stopped service).
- Android reports: notification mirroring, clipboard sync, phone controls, background receiver (FGS), and battery-optimization exemption. Status uses live runtime signals — real notification-listener bind state, granted permissions, whether `LinkitReceiverService` is running — not just persisted toggles, so a silently-stopped feature reports `attention` instead of a misleading `on`.
- Mac reports: clipboard sync, launch at login, transfer notifications (macOS authorization), and the receiver.
- The snapshots are **exchanged over the existing presence/registration cadence** (no new endpoints): Android → Mac in the `GET /v1/devices/self/status` response and the `POST /v1/devices/self` registration body; Mac → Android in the registration response. Each app renders both its own and the peer's self-reported health.
- **Notification-mirror reboot fix:** `NotificationMirrorService` overrides `onListenerConnected/onListenerDisconnected` to track real bind state (`NotificationMirrorState`) and calls `requestRebind`; `NotificationAccess.ensureListenerBound` re-binds a granted-but-dropped listener on app resume, receiver-service start, and when mirroring is toggled on. The OS keeps the permission grant across reboots but does not always rebind the listener — this recovers it without the user re-toggling.
- Surfaces: Android **Home → Feature status** (a compact list; tap an `attention` row for an explanation and one Fix action) and the relevant Settings detail screens; Mac **Settings → Diagnostics → Phone status** and a **popover attention row** linking to Diagnostics.

### Large-File Memory Behaviour

- All four transfer paths hold **constant memory** regardless of file size: 1 MB chunk loops with incremental SHA-256 on both receivers, `URLSession.uploadTask(with:fromFile:)` on the Mac sender, and an OkHttp `RequestBody` with a known `contentLength()` on the Android sender (a streaming body, not a buffered one). No path reads a whole file into memory. Android's `readBody` is capped by a `maxBytes` argument and is only used for JSON control bodies, never for file uploads.
- The Mac sender writes a **full-size encrypted temp copy** to `FileManager.default.temporaryDirectory` before uploading (`encryptFileToTemp`) — that is disk, not memory, and a `defer` removes it on every exit including throws. Worth knowing that sending an *N*-byte file needs *N* bytes of free temp space.
- `LinkitCancellationToken.onCancel` handlers are now **deregistered when each upload finishes**. One token spans a whole multi-file batch, so previously every file left behind a closure pinning its completed `URLSessionUploadTask` until the batch ended.
- Both senders fire their progress callback **once per 1 MB**, which on Android rebuilds the foreground notification each time. Not a leak, but it is the reason a multi-GB send does thousands of notification rebuilds; coalescing is the obvious future tweak.

### Bounded State (both platforms)

- Long-running processes prune everything that grows per event: nonce replay caches (120 s TTL + 4096 cap, both sides), transfer history (200 Mac / 100 Android), Mac mirrored-notification history (10), Android `DebugTelemetry` ring buffers (500 log lines / 120 events / 60 battery samples / 30 service windows), and Android receiver sessions (`sweepExpiredSessions` on every routed request).
- Mac `TransferStore.records` is pruned on `create` and on `sweepOrphans`, one hour past session expiry. It previously only ever grew — one `TransferRecord` per transfer for the life of the menu-bar process — while the Android side already pruned correctly. The grace window keeps finalize replay idempotent; past it an id resolves to `not_found`.

### Receiver Service Durability (Android)

- `LinkitReceiverService` is meant to outlive the UI, so four things bring it back: `START_STICKY` (low-memory kill), `onTaskRemoved` → immediate restart (swiping the app out of Recents kills the process on many OEM builds), a `BootReceiver` on `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` (reboot and in-place update — `START_STICKY` covers neither), and a **delete intent** on the persistent notification that re-posts it, since Android 13+ lets users swipe away an ongoing foreground-service notification.
- All four are gated on `LinkitPreferences.receiverEnabled()`, set whenever the service starts and cleared **only** by the notification's explicit **Stop** action. An explicitly stopped or unpaired install therefore stays stopped; boot restart additionally requires a trusted Mac. The FGS start is wrapped in `runCatching` so a refused start can never crash the app at boot.

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
- **Mac system status flows the other way** on the same registration response (`MacSystemStatus` in `MacSystemStatus.swift` → `mac` field of `DeviceConnectionResponse` → `MacSystemStatus.kt` → `MacPresence.macStatus`), so the phone knows as much about the Mac as the Mac knows about the phone. Carried: battery % + charging/AC + time-to-full, Low Power Mode, link kind (Wi-Fi/Ethernet) and Wi-Fi quality bucketed from RSSI, free space on the drop-folder volume, Linkit's DND window, and the short macOS version. Every field is optional — a desktop Mac has no battery, an Ethernet Mac no RSSI, an older Mac sends no `mac` object at all — and the phone renders "—" rather than guessing a value.
- All of it is read with **no entitlement and no consent prompt**: IOKit power sources, `NWPathMonitor`-equivalent radio state, and a volume `stat`. Worth knowing that macOS 14+ gates Wi-Fi **SSID/BSSID** behind Location but *not* signal strength, so quality works without Linkit ever asking for the network name. Readings are cached 5 s so bunched registration refreshes don't re-query.
- Both sides usually converge within ~30–60 s of a real disconnect; restored hotspot can recover as soon as refresh or rediscovery succeeds.

### Notification Action Buttons

- Android receiver notification (`Mac drops enabled on …`) carries **Send Clipboard** and **Open Link** actions.
- Tapping launches `ClipboardActionActivity` (translucent theme, real window focus). Clipboard read deferred to `onWindowFocusChanged(true)` for Android 10+.
- Result via Toast, then activity finishes.

### Do Not Disturb (Mac)

- **Left-click popover:** Do Not Disturb is a quick-action tile (it replaced the unused Mac → Android "Open Link" tile, alongside Send File and Clipboard). Clicking it opens a menu of preset quiet windows (1 / 2 / 6 / 12 / 24 hours); while active the tile turns accent-amber and the menu also offers **Turn Off Do Not Disturb**. The status-item **right-click menu** carries the same options as a **Do Not Disturb** submenu ("On until …" + **Turn Off**, checkmarked when active). Both surfaces call the shared `setDoNotDisturb(hours:)` / `disableDoNotDisturb()` and stay in lockstep.
- Engaging DND stores an expiry timestamp in `Preferences.doNotDisturbUntil` (persisted, so a window survives relaunch). While `isDoNotDisturbActive`, the Mac suppresses **transfer-received / transfer-failed / call-on-phone** notifications and the **mirrored-Android notification banner** — the Android notification is still logged to the Mac's notification history, only the on-screen banner is withheld.
- The status-icon tooltip appends "· Do Not Disturb until …", and the mirrored **Transfer notifications** feature-status reports `off` with a "Paused by Do Not Disturb until …" detail so the paired phone reflects the quiet window.
- A one-shot timer (`doNotDisturbExpiryTimer`) clears the window when it elapses and refreshes the icon; the state is also lazily expired whenever the menu opens or the app launches.

### Consumer UI (Android)

- **Bottom-navigation shell** (`TopTab` = Home · Activity · Settings) — a **floating glass pill** (`GlassBottomBar.kt`) rather than a docked bar, and the always-visible map (Android's answer to the Mac Settings sidebar). Content scrolls *underneath* it: a gradient scrim dissolves the page as it reaches the bar, the pill is translucent over that fade with a bright top edge and a soft shadow, and the selected tab lights up from behind with an accent radial glow instead of sitting in a filled indicator. Android has no backdrop-blur primitive for arbitrary composables, so this is **layered translucency, not a true frosted blur** — over the scrim the two are hard to tell apart. Every scrolling tab pads its bottom by `GlassBarContentPadding` to clear it. System back walks the hierarchy: detail → hub, then any tab → Home, then exit. Nav state survives config changes via `rememberSaveable`.
- Compose **Home** (control surface, kept short): Linkit wordmark (7-tap debug), the **Mac status card** (`MacStatusCard.kt`), the action grid (send file, send clipboard, open link) + clipboard-sync toggle, and a compact **Feature status** card at the bottom.
- **Mac status card** — the Home hero, mirroring the Mac popover's device header. A Canvas-drawn MacBook (vector shapes, no bitmap asset to theme), the Mac's name, a pulsing connection status, conditional badges (**Do Not Disturb**, **Low Power**) that appear only when true, a gear to Settings → Device, and a four-reading strip: **Battery** (% + Charging/Plugged in/Battery, red only when genuinely low *and* unplugged; "AC" on a battery-less desktop Mac), **Wi-Fi** (quality word, or "Wired"), **Free** space on the Mac's drop volume — the number that decides whether the next big send fits — and **Last sync**. Latency was deliberately left out: it is a number that moves constantly and tells you nothing you can act on. The strip dims rather than clearing when the Mac goes offline, so the last known reading plus a growing "Last sync" tells the real story. Each feature is one line (title + status dot: green on / red attention / grey off); a feature with a problem gets a **red dot + red chevron** and, on tap, a dialog explaining the issue with a single **Fix** action (notification-listener rebind / permission request / battery-exemption / receiver-restart). Recent activity and the phone/notification/background config live in the Activity and Settings tabs.
- **Activity** tab: a **two-sided timeline** (`ActivityTimeline.kt`) rather than a uniform list — a spine down the middle with received drops branching left and sends branching right, so direction is legible without reading an arrow on every row. Day chips ("Today" / "Yesterday" / a date, on **calendar** boundaries, not elapsed hours) sit on the spine; each entry is a bead (green received / accent sent) with a card carrying a thumbnail, filename, size, and clock time. Thumbnails are best-effort (`loadThumbnail` on API 29+, subsampled `BitmapFactory` below) and fall back to a file glyph on any failure. A live send appears as an inline progress card at the head of the timeline with its own Cancel — and the floating `TransferBar` is suppressed on this tab so the same progress isn't drawn twice. **Received, completed cards are tappable to open** — fires `ACTION_VIEW` on the stored content URI: the `MediaStore` Downloads URI on API 29+, a `FileProvider` URI on the legacy path. Clear lives in the header.
- **Settings** tab = **hub → detail** (`SettingsRoute`): a short hub of categories (Device, Clipboard, Notifications, Phone, Appearance, Background & battery, Updates, About) that each drill into a focused detail screen with a back arrow + large header (`SettingsDetailScaffold`) — mirroring the Mac Settings sidebar sections instead of one long scroll. **Device** detail = connection (status, address, reconnect/disconnect, pair with a different Mac, forget); cross-device feature-status health now lives on **Home** instead. **Appearance** = accent color (9 preset swatches + custom `#RRGGBB`, default `#D16B1F`) and theme (System/Light/Dark).
- **Preferences** persisted in `LinkitPreferences` (SharedPreferences-backed `StateFlow`): appearance theme override and clipboard-sync state. Theme follows the chosen appearance (was system-only); warm-paper Light/Dark palette from `LinkitPalette`.
- Pairing-only Welcome screen; debug IP/port/token hidden from normal use.
- Network hints when hotspot or flaky connectivity is detected.
- One-time prompts: notification permission (Android 13+), battery optimization exemption (keeps FGS + Wi-Fi alive on Doze), and phone permissions (call, phone state, contacts, call log) as needed. Bluetooth permissions were dropped with the call-audio feature.

### Menu Bar And UX (macOS)

- Packaged menu-bar `.app` with animated status icon (paired, transferring, success, error, pairing).
- **Popover panel** (left-click the icon): device header with name, status dot, battery, and a gear to Settings; three quick-action tiles (Send File, Clipboard, Do Not Disturb) where **Clipboard** and **DND** are stateful — accent-amber while on, neutral while off. The Clipboard tile is the **only** clipboard-sync control (the Settings → Clipboard group was removed); sync defaults to on and nothing else turns it off. Contextual Phone row (Call a Number…, Answer/Decline/Hang Up); inline transfer progress with cancel; recent transfers (each row is a **file drag source** — drag a received file straight into Finder/another app, click still opens); footer (Pairing QR, Drop Folder, Quit). Built in SwiftUI (`LinkitPanelView`) over a `PanelViewModel` bridge. Right-click gives a minimal fallback menu (Open, Settings, Updates, Quit).
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

`scripts/smoke-signed-transfer.sh` exercises the full protocol without a phone: it pairs against a headless `LinkitMacReceiver`, rejects a bad signature, seals a file body with the per-transfer key (AES-256-CTR), and verifies the received bytes round-trip.

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
- Add an instrumented Android-device smoke lane to CI; JVM tests and debug builds do not exercise foreground-service, notification-listener, or OEM battery behavior.
