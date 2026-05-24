# Linkit Setup

Developer / sideload instructions for running Linkit locally.

## Run the Mac receiver

Menu-bar app (recommended):

```sh
cd macos
swift run LinkitMacMenu
```

Terminal-only receiver:

```sh
cd macos
swift run LinkitMacReceiver
```

## Install the Android app

```sh
cd android
./gradlew installDebug
```

Open the app once after install so the background receiver service starts. On Android 13+, grant the notification permission prompt — the receiver runs as a foreground service, so a silent "Linkit ready" notification will sit at the bottom of the shade. Tap **Stop** to disable; reopen the app to re-enable.

## Pair

1. Mac menu bar → **Show Pairing QR**.
2. Android app → **Scan QR**.

Scan the QR from the Mac menu-bar app. Manual token pairing is disabled because QR pairing includes a signed one-time challenge.

The status item icon flips to `link.circle.fill` and the title becomes `Linkit (1)` once paired.

## Send files

**Phone → Mac:** pick files in the app, or tap **Share** in any Android app and choose Linkit. Files land in `~/Downloads/Linkit Drop` on the Mac.

**Mac → Phone:** open Linkit on Android so the foreground receiver is running, then drag files onto the `Linkit` menu-bar item. Files land in `Downloads/Linkit Drop` on the phone.

The Mac transfer popup has a **Cancel** button. Canceling a Mac → Android transfer aborts the local upload and sends a signed cancel request to Android. Canceling an Android → Mac transfer marks the receiver session canceled and removes the in-flight temp file.

## Clipboard and link handoff

All text/link handoff uses signed local requests over the paired LAN connection. Nothing goes through a cloud service.

**Mac → Android:**

- Mac menu bar → **Send Clipboard Text to Android** copies the current Mac clipboard text onto Android.
- Mac menu bar → **Open Clipboard Link on Android** opens the current Mac clipboard URL on Android. Only `http` and `https` links are accepted.
- Mac menu bar → **Clipboard Text Sync: On** watches the Mac clipboard and pushes text changes to Android.

**Android → Mac:**

- Android app → **Send Clipboard** sends the current Android clipboard text to the Mac clipboard.
- Android app → **Open Link on Mac** opens the current Android clipboard URL on the Mac.
- Android share sheet → share plain text to Linkit to copy it to the Mac clipboard.
- Android share sheet → share an `http` or `https` URL to Linkit to open it on the Mac.
- Android app → **Clipboard Sync: On** watches clipboard changes only while Linkit is open/focused.

Android 10+ blocks ordinary background apps from reading clipboard contents unless the app is focused or is the active input method. Linkit's Android → Mac automatic sync is therefore foreground-only by design. For background Android copies, use the Android share sheet or open Linkit and tap **Send Clipboard**.

## Reconnect after network change

If you toggle Wi-Fi, switch SSIDs, or turn the phone hotspot on/off, the paired Mac's IP may change. The Android app handles this without re-pairing:

- On app open or resume, Android runs a 5-second Bonjour query filtered by the paired Mac's name and updates the stored IP/port before re-registering its receiver.
- The device card on Home shows **Paired, offline** with a **Reconnect** button whenever the Mac stops responding. Tap it to run the same flow on demand.

Both sides converge on the same connection state. The Mac probes Android every ~30 s with a signed `GET /v1/devices/self/status`; Android marks the Mac offline after ~90 s of silence.

## Debug panel (Android)

Tap the **Linkit** wordmark on the Home top bar seven times in quick succession to open the hidden Debug screen. Available in both debug and signed-release builds.

Sections:

- **Process** — uid/pid, process uptime, CPU time since process start and since baseline (with % of wall time).
- **Network (this UID)** — Rx/Tx bytes from `TrafficStats.getUidRxBytes/Tx` for the Linkit UID only, since process start and since baseline.
- **Battery** — current system %, baseline %, delta, baseline-taken timestamp, last 8 samples (each tagged with the reason it was captured, e.g. `LinkitReceiverService start`).
- **Foreground services** — running `LinkitReceiverService` / `LinkitSendService` windows with durations, and the last 8 completed windows.
- **Events** — last 40 reconnect/discovery/presence/fgs/client events.
- **Logs** — last 80 of a 500-line ring buffer (`DebugTelemetry.log/i/w/e`).

Buttons:

- **Reset baseline** — resets the CPU/network/battery baseline counters without restarting the process.
- **Clear logs** — empties the log ring.
- **Copy full report** — copies a plaintext digest of every section to the clipboard for pasting into an issue.
- **Copy `adb dumpsys batterystats` command** — copies `adb shell dumpsys batterystats --charged tech.kalkikgp.linkit` for ground-truth per-app mAh on a host machine.

In-app readings are PID/UID-scoped proxies. They isolate Linkit from other heavy apps running on the device, but for actual battery mAh you still need the adb command above.

## Where things live

```txt
~/Downloads/Linkit Drop                          # received files (Mac)
~/Downloads/Linkit Drop/.tmp                     # in-flight uploads
~/Library/Logs/Linkit/transfer.log               # debug log
~/Library/Application Support/Linkit/            # trusted devices + history
```

## Verification

Smoke the whole stack without a phone:

```sh
./scripts/verify.sh
./scripts/smoke-signed-transfer.sh
```

## Packaging

Build a local `.app` bundle:

```sh
./scripts/build-macos-app.sh
open dist/Linkit.app
```

Install into `/Applications`:

```sh
./scripts/install-macos-app.sh
open /Applications/Linkit.app
```

Install the Android debug build:

```sh
./scripts/install-android-debug.sh
```

Build a signed release APK for sideloading:

```sh
./scripts/build-android-release.sh
adb install dist/linkit-release.apk
```

The first run creates a local keystore at `android/linkit-release.keystore` and `android/keystore.properties` (both gitignored). Copy `android/keystore.properties.example` if you want to use your own keystore/passwords instead.

## Bonjour discovery

The receiver advertises `_linkit._tcp.local.`:

```sh
dns-sd -B _linkit._tcp local
```

## Protocol details

- [`../protocol/phase0.md`](../protocol/phase0.md) — Phase 0 spike
- [`../protocol/phase1.md`](../protocol/phase1.md) — session integrity + Bonjour
- [`../protocol/mvp.md`](../protocol/mvp.md) — signed trust + pairing + share + reverse drop
