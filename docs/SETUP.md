# Linkit Setup

Developer / sideload instructions for running Linkit locally.

**Latest release:** [v0.6.1](https://github.com/kalki-kgp/Linkit/releases/latest) — download `linkit-release.apk` and `linkit-macos.zip`, or use **Check for Updates** in the Mac menu / Android app settings.

## Installing the macOS app

Linkit's Mac app is **ad-hoc code-signed but not Apple-notarized** — notarization requires a paid Apple Developer account, and Linkit is free. The app is safe (the source is in this repo and you can build it yourself), but because it isn't notarized, Gatekeeper warns the first time you open a downloaded copy. This is a **one-time** step:

1. Download `linkit-macos.zip` from the [latest release](https://github.com/kalki-kgp/Linkit/releases/latest) and unzip it.
2. Move `Linkit.app` to `/Applications`.
3. Open it once. macOS says *"Apple could not verify 'Linkit' is free of malware."* Click **Done** — **not** "Move to Trash".
4. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Linkit message, then confirm with **Open**.

After that first allow it launches normally and the in-app updater works without prompting again.

Prefer the terminal? Remove the quarantine flag instead of steps 3–4:

```sh
xattr -dr com.apple.quarantine /Applications/Linkit.app
open /Applications/Linkit.app
```

The most paranoia-friendly option is to **build from source** (below) — a locally built app is never quarantined.

## Run the Mac app

Menu-bar app (recommended):

```sh
cd macos
swift run LinkitMacMenu
```

Terminal-only receiver (dev/smoke):

```sh
cd macos
swift run LinkitMacReceiver
```

## Install the Android app

Debug build (development):

```sh
cd android
./gradlew installDebug
```

Or:

```sh
./scripts/install-android-debug.sh
```

Open the app once after install so the background receiver service starts.

**First-run prompts (Android):**

- **Notifications** (Android 13+) — required for the foreground receiver notification.
- **Battery optimization exemption** (one-time) — keeps the receiver + Wi-Fi alive when the screen is off; strongly recommended on Doze-heavy devices.
- **Phone permissions** — only if you use call control from the Mac.
- **Bluetooth** — only if you use experimental call-audio routing to the Mac.

The receiver runs as a foreground service; a quiet **Linkit ready** notification sits in the shade. Tap **Stop** on the notification to disable; reopen the app to re-enable.

## Pair

1. Mac menu bar → **Show Pairing QR**.
2. Android app → **Scan QR**.

Manual token pairing is disabled — QR pairing includes a signed one-time challenge.

The menu-bar icon reflects pairing and connection state once paired.

## Send files

**Phone → Mac:** pick files in the app, or tap **Share** in any Android app and choose Linkit. Files land in `~/Downloads/Linkit Drop` on the Mac.

**Mac → Phone:** drag files onto the **Linkit** menu-bar icon. Files land in `Downloads/Linkit Drop` on the phone even when the app is in the background, as long as the foreground receiver service is running.

**Cancel:** Mac transfer popup **Cancel** aborts Mac → Android uploads and sends a signed cancel to Android. Android → Mac cancel removes the in-flight temp file on the Mac receiver.

## Clipboard and link handoff

All handoff uses signed local requests. Nothing goes through a cloud service.

**Mac → Android:**

- **Send Clipboard Text to Android**
- **Open Clipboard Link on Android** (`http` / `https` only)
- **Clipboard Text Sync: On** — watches the Mac clipboard

**Android → Mac:**

- **Send Clipboard** / **Open Link on Mac** in the app
- Share sheet → plain text or URL to Linkit
- **Clipboard Sync: On** — foreground-only (Android 10+ clipboard privacy)
- Receiver notification → **Send Clipboard** / **Open Link** action buttons

## Phone control

On Android, open the Phone section and tap **Enable phone controls**. Grant phone permissions as needed (call state, call log, contacts, direct call, answer calls).

Mac menu bar:

- **Call Number on Android...**
- **Answer** / **Decline** / **Hang Up Android Call**
- Incoming calls can show Answer / Decline / Dismiss on the Mac (with caller ID when Android grants call log + contacts).

This is **call control only** over the signed LAN channel. Cellular audio stays on the phone unless you set up Bluetooth call audio (below).

## Bluetooth call audio (experimental)

1. Pair phone and Mac over **classic Bluetooth** (separate from Wi-Fi Linkit pairing).
2. Mac menu → **Set Up Call Audio...** — shares the Mac Bluetooth address with Android.
3. On Android, enable call audio when prompted (Bluetooth bond).
4. Mac menu → **Move Call Audio to Mac** / **Move Call Audio to Phone** during a call.

Uses macOS `IOBluetooth` Hands-Free Profile. Requires macOS 13+ and a Mac with Bluetooth.

## Reconnect after network change

When Wi-Fi, hotspot, or SSID changes, the Mac's IP may change. Linkit recovers **without re-pairing**:

- Android runs Bonjour filtered by the paired Mac name, verifies the candidate with signed `POST /v1/identity/proof`, updates the stored IP/port, and re-registers its receiver.
- This runs from the **foreground receiver service** (when registration fails), on **app resume**, on **network callbacks**, on the **Reconnect** button, and periodically while **paired but offline** (~30 s).
- macOS probes Android on network path changes and persists the last-known Android endpoint for sends.

Both sides converge on paired vs connected state within ~30–60 s of a real disconnect.

## In-app updates

Both apps check GitHub `releases/latest/download/linkit-*-update.json` by default.

- **Mac:** menu → **Check for Updates** — downloads zip, verifies SHA-256, swaps `Linkit.app`, relaunches.
- **Android:** in-app update flow — downloads APK; you must approve installation. Update APK must be signed with the same release key as the installed app.

Override manifest URL at build time:

```sh
LINKIT_UPDATE_MANIFEST_URL=https://... ./scripts/build-macos-app.sh
LINKIT_ANDROID_UPDATE_MANIFEST_URL=https://... ./scripts/build-android-release.sh
```

## Debug panel (Android)

Tap the **Linkit** wordmark on Home **seven times** quickly. Available in debug and release builds.

Shows process CPU, per-UID network bytes, foreground-service uptime, battery samples, event log, and a 500-line log ring. **Copy full report** for issue pasting; **Copy `adb dumpsys batterystats` command** for ground-truth mAh on a host.

## Where things live

```txt
~/Downloads/Linkit Drop                          # received files (Mac)
~/Downloads/Linkit Drop/.tmp                     # in-flight uploads
~/Library/Logs/Linkit/transfer.log               # debug log
~/Library/Application Support/Linkit/            # trusted devices + history
```

Android receives: `Downloads/Linkit Drop` on the phone.

## Verification

```sh
./scripts/verify.sh                  # swift test + Mac build + Android tests + debug APK
./scripts/smoke-signed-transfer.sh   # signed transfer stack without a phone
```

## Packaging (local)

Mac app bundle:

```sh
./scripts/build-macos-app.sh
open dist/Linkit.app
```

Install to `/Applications`:

```sh
./scripts/install-macos-app.sh
open /Applications/Linkit.app
```

Signed Android release APK:

```sh
./scripts/build-android-release.sh
adb install -r dist/linkit-release.apk
```

First run creates `android/linkit-release.keystore` and `android/keystore.properties` (gitignored). Copy `android/keystore.properties.example` for your own keystore.

Package updater manifests manually (example for v0.6.1):

```sh
LINKIT_VERSION=0.6.1 \
LINKIT_BUILD=7 \
LINKIT_UPDATE_ASSET_BASE_URL=https://github.com/kalki-kgp/Linkit/releases/download/v0.6.1 \
./scripts/package-macos-update.sh

LINKIT_VERSION=0.6.1 \
LINKIT_VERSION_CODE=7 \
LINKIT_ANDROID_UPDATE_ASSET_BASE_URL=https://github.com/kalki-kgp/Linkit/releases/download/v0.6.1 \
./scripts/package-android-update.sh
```

Outputs: `dist/linkit-macos.zip`, `dist/linkit-macos-update.json`, `dist/linkit-release.apk`, `dist/linkit-android-update.json`.

## Automated GitHub release

Workflow: `.github/workflows/release.yml`

**Recommended:** GitHub Actions → **Release** → **Run workflow** with:

- `version_name` — e.g. `0.6.1`
- `version_code` — integer **must increase** (Android `versionCode` and macOS build); v0.6.1 = `7`
- `release_notes` — short text for updater manifests

Required secrets: `LINKIT_ANDROID_KEYSTORE_BASE64`, `LINKIT_ANDROID_KEYSTORE_PASSWORD`, `LINKIT_ANDROID_KEY_ALIAS`, `LINKIT_ANDROID_KEY_PASSWORD`.

```sh
base64 -i android/linkit-release.keystore | pbcopy   # create keystore secret once
```

Tag-only pushes (`git push origin v*`) also trigger the workflow, but `version_code` becomes the workflow run number — prefer **workflow dispatch** so `version_code` stays aligned with releases.

Asset layout per tag `v0.6.1`:

```txt
https://github.com/kalki-kgp/Linkit/releases/download/v0.6.1/linkit-macos.zip
https://github.com/kalki-kgp/Linkit/releases/download/v0.6.1/linkit-release.apk
```

Apps fetch latest manifests:

```txt
https://github.com/kalki-kgp/Linkit/releases/latest/download/linkit-macos-update.json
https://github.com/kalki-kgp/Linkit/releases/latest/download/linkit-android-update.json
```

Manifests point at immutable tag-specific binaries; the `latest` URL tracks the newest release.

## Bonjour discovery

Receiver advertises `_linkit._tcp.local.`:

```sh
dns-sd -B _linkit _tcp
```

Bonjour is address discovery only — rediscovered endpoints must pass signed identity proof before trust updates.

## Further reading

Wire format and feature details live in the code (`LinkitMacCore`, `AndroidDropReceiver`, `LinkitClient`) and [`current-state.md`](current-state.md).
