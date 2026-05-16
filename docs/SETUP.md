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

Or enter the Mac's private LAN IP, port `52718`, and pairing token manually.

The status item icon flips to `link.circle.fill` and the title becomes `Linkit (1)` once paired.

## Send files

**Phone → Mac:** pick files in the app, or tap **Share** in any Android app and choose Linkit. Files land in `~/Downloads/Linkit Drop` on the Mac.

**Mac → Phone:** drag files onto the `Linkit` menu-bar item. Files land in `Downloads/Linkit Drop` on the phone.

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

## Bonjour discovery

The receiver advertises `_linkit._tcp.local.`:

```sh
dns-sd -B _linkit._tcp local
```

## Protocol details

- [`../protocol/phase0.md`](../protocol/phase0.md) — Phase 0 spike
- [`../protocol/phase1.md`](../protocol/phase1.md) — session integrity + Bonjour
- [`../protocol/mvp.md`](../protocol/mvp.md) — signed trust + pairing + share + reverse drop
