# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Linkit is

A private, cloud-free local device link between **one** Android phone and **one** Mac. It moves files, clipboard text, links, and phone-call control directly over the LAN / phone hotspot using signed HTTP requests. No accounts, no relay server, no internet data path. Two native apps share one symmetric wire format implemented separately in Swift and Kotlin.

The README is product-facing. **`docs/current-state.md`** is the technical feature snapshot (keep it updated when shipping). When behavior and docs disagree, trust the code and update the docs.

**Latest release:** v0.9.1 on GitHub Releases (in-app updaters on both platforms).

## Repository layout

- `macos/` — Swift Package (`swift-tools-version: 5.9`, macOS 13+). Three targets:
  - `LinkitMacCore` (library) — all protocol, HTTP server, trust, transfer, identity logic. Almost all real Mac logic lives here and is the only target with unit tests.
  - `LinkitMacMenu` (executable) — the shipped menu-bar app (`LSUIElement`). Packaged into `dist/Linkit.app` by build scripts.
  - `LinkitMacReceiver` (executable) — headless terminal receiver, used for dev/smoke tests.
- `android/` — Gradle/Kotlin app, package `tech.kalkikgp.linkit`, Compose UI, minSdk 26 / target+compile 36. Single `app` module; all sources flat in `android/app/src/main/java/tech/kalkikgp/linkit/`.
- `scripts/` — build / package / smoke-test shell scripts.
- `docs/` — `current-state.md`, `SETUP.md` (developer setup).
- `dist/` — local build output (`Linkit.app`, `linkit-release.apk`, update manifests). **Gitignored**; release binaries live on GitHub Releases.

## Build, test, run

Mac (from `macos/`):
```sh
swift run LinkitMacMenu        # run the menu-bar app
swift run LinkitMacReceiver    # run the headless receiver
swift test                     # all LinkitMacCore tests
swift test --filter SignedRequestVerifierTests        # one test case/class
```

Android (from `android/`):
```sh
./gradlew installDebug                 # build + install debug to connected device
./gradlew testDebugUnitTest            # JVM unit tests (src/test)
./gradlew testDebugUnitTest --tests 'tech.kalkikgp.linkit.PairingPayloadParserTest'   # one test
./gradlew assembleDebug
```

Full local verification (both platforms — `swift test`, Mac build, Android unit tests + debug build):
```sh
./scripts/verify.sh
```

Run the current release gate:
```sh
./scripts/verify.sh
```

`scripts/smoke-signed-transfer.sh` is a stale plaintext fixture and currently fails against encrypted file bodies; update it before treating it as a release check.

Packaging (see `docs/SETUP.md` for in-app-updater manifest URLs):
```sh
./scripts/build-macos-app.sh       # -> dist/Linkit.app
./scripts/build-android-release.sh # -> dist/linkit-release.apk (creates local keystore on first run)
```

Release CI: `.github/workflows/release.yml` builds both apps + updater manifests. Prefer **`workflow_dispatch`** with explicit `version_name` and `version_code` (must increase Android `versionCode`). Tag-only pushes use `GITHUB_RUN_NUMBER` for `version_code`, which may not track the app version — v0.6+ were cut via workflow dispatch.

## Architecture

### Symmetric signed-HTTP peers
Both devices run an HTTP server **and** act as a client to the other. There is no single "server" — Mac→phone and phone→Mac use the same request shapes in opposite directions.
- Mac server: `macos/Sources/LinkitMacCore/HTTPServer.swift` (raw `Darwin` sockets, routes dispatched by method+path around line 318+). Client side: `OutgoingTransferClient.swift`.
- Android server: `AndroidDropReceiver.kt` (raw `ServerSocket`, hand-rolled HTTP). Client side: `LinkitClient.kt`.

Key `/v1` routes (same on both sides): `GET /info`, `POST /identity/proof`, `POST /pair`, `POST|DELETE /devices/self` (receiver registration), `POST /actions` (clipboard/text/url/phone control), `POST /transfers` + `PUT /transfers/:id/files/:index` + `POST /transfers/:id/finalize` + `DELETE /transfers/:id`, `GET /history`.

### Trust & crypto (the core invariant)
All control requests after pairing are **P-256 ECDSA + SHA-256 signed**. Each device generates a private signing key on first run that never leaves the device (Mac: Keychain via `IdentityStore`/`IdentityAndTrust.swift`; Android: `IdentityStore.kt`). Verifier: `SignedRequestVerifier.swift` / signing in `AndroidDropReceiver` + `LinkitClient`.
- Signed-header scheme, canonical strings, pairing challenge, and `identity/proof` are implemented in `IdentityStore` / `IdentityAndTrust.swift` (Mac) and `IdentityStore.kt` / `AndroidDropReceiver` + `LinkitClient` (Android). **Read both sides before touching signing or verification.** Both implementations must match byte-for-byte (e.g. the Android public key is base64 x963 and must be byte-identical across QR payload and pair canonical string).
- Receiver rejects unless: device id is trusted, timestamp within ±60s, nonce unused for 120s, signature valid against the stored peer key.
- Pairing is QR-only (Mac shows QR → Android scans, signs a one-time challenge). Manual token pairing is intentionally disabled.

### Transfers
Streamed with constant memory and end-to-end SHA-256 verification; the upload slot is signed but the file body streams unsigned under a single-use upload token bound to transfer/file/size/device. Finalize is idempotent. One file per HTTP session — multi-file is done by issuing multiple sessions. Files land in `~/Downloads/Linkit Drop` (Mac) / `Downloads/Linkit Drop` (Android). Mac transfer/trust/history state: `TransferStore`, `TransferHistoryStore`, `TrustStore`, `DeviceConnectionRegistry`. Android share intents pass content URIs directly to `LinkitSendService` (no share-cache copy).

### Discovery, reconnect & presence
- Bonjour `_linkit._tcp` advertises the receiver (`BonjourAdvertiser.swift` / `BonjourDiscovery.kt`); Bonjour is **address discovery only**. After rediscovery Android re-verifies the Mac via signed `POST /v1/identity/proof` (`MacRediscovery.kt`, `MacPresence.kt`) before trusting a new IP/port — never trust a rediscovered endpoint without identity proof.
- **`MacRediscovery.kt`** — shared mutex-guarded Bonjour lookup by paired device name + identity proof + persist new endpoint. Used by `MainActivity.discoverAndReconnect()` and `LinkitReceiverService.refreshMacRegistration()` when the stored Mac address fails.
- Reconnect after Wi-Fi/hotspot changes happens without re-pairing: Android `ConnectivityManager` callbacks, resume-time rediscovery, and a paired-but-offline UI retry loop (~30 s); Mac `NWPathMonitor` (`LocalNetwork.swift` / menu app) drives re-probe and persists `lastKnownHost`/`receivePort` for Android.
- Bidirectional presence: Mac runs a periodic signed `GET /v1/devices/self/status` sweep (~30 s staleness); Android foreground service refreshes Mac registration (~20 s) and runs active identity proof after >45 s silence. Both converge on the same UI connection state.
- Android Doze resistance: foreground service holds a Wi-Fi lock; optional battery-optimization exemption prompt; partial wake lock during receive uploads.

### Android service model
`LinkitReceiverService` is a foreground service (`foregroundServiceType="specialUse"`) that owns the receiver socket, presence refresh, network monitor, Wi-Fi lock, and `PhoneCallBridge`. `LinkitSendService` (`dataSync`) handles outbound sends. The app must be opened once to start the receiver. Android receive depends on this foreground service running.

### Phone control
- **Call control** (`PhoneControl.kt` / Mac menu): signed `phone_call`, `phone_answer`, `phone_decline`, `phone_hangup` actions; Android mirrors state with `phone_state` (number, display name when call log/contacts granted). Mac shows incoming-call panel when ringing.
- **Call picker:** Mac **Call a Number…** opens a search-over-contacts/recents picker fetched via signed `GET /phonebook` (needs Android `READ_CONTACTS`/`READ_CALL_LOG`); it surfaces the permission precondition when those aren't granted. On Android, phone controls live on the Home screen.
- **Call audio stays on the phone.** Cellular audio cannot be relayed over HTTP with public Android APIs. The old experimental Bluetooth Hands-Free route (`HandsFreeBridge.swift`, `BluetoothPairAssist.kt`, `bt_pair`) was **removed** — it could never deliver Mac-side audio on Apple Silicon (SCO `kIOReturnUnsupported`). Don't re-add it.

### Notable platform constraints (don't "fix" these — they're OS limits)
- **Clipboard:** Android 10+ blocks background clipboard reads. Mac→Android clipboard push works anytime; automatic Android→Mac clipboard sync is foreground-only. `ClipboardActionActivity` defers the read to `onWindowFocusChanged(true)` so notification-button copies work.
- No TLS/mTLS/Noise — transport is plain local HTTP. Signing authenticates requests; application-layer AES-256-GCM encrypts control payloads and AES-256-CTR encrypts file bodies. Filenames, sizes, history entries, and control responses remain cleartext metadata.

### Android debug telemetry
Hidden panel: tap the **Linkit** wordmark 7× (`DebugActivity` / `DebugTelemetry` process-scoped singleton). Surfaces CPU, per-UID network bytes, FGS uptime windows, battery samples, an event log, and a 500-line ring buffer. In-app numbers are PID/UID proxies; real mAh needs `adb shell dumpsys batterystats --charged tech.kalkikgp.linkit`.

## Conventions

- Commit messages: short single-line subject, no body, no `Co-Authored-By` trailer.
- Keep `macos` (Swift) and `android` (Kotlin) protocol implementations in lockstep; a change to signing, canonical strings, routes, or the QR payload must land on both sides.
- Secrets are gitignored: `android/keystore.properties`, `android/linkit-release.keystore`, `android/local.properties` (copy `keystore.properties.example` to set up your own).
