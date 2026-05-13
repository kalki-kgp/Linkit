# Linkit

Native Android-to-macOS local file transfer.

MVP is runnable:

1. Start the macOS menu-bar receiver:

```sh
cd macos
swift run LinkitMacMenu
```

Or run the terminal receiver:

```sh
cd macos
swift run LinkitMacReceiver
```

2. Use `Show Pairing QR` from the menu bar, or copy the terminal pairing payload/token.
3. Install/open the Android debug app:

```sh
cd android
./gradlew installDebug
```

4. In Android, scan the QR or enter Mac private LAN IP, port `52718`, and pairing token.
5. Pick files or share from Android Files/Photos/WhatsApp into Linkit.

The receiver saves verified files into:

```txt
~/Downloads/Linkit Drop
```

Temp uploads stay inside:

```txt
~/Downloads/Linkit Drop/.tmp
```

Debug log:

```txt
~/Library/Logs/Linkit/transfer.log
```

Recent transfer history:

```txt
~/Library/Application Support/Linkit/transfer-history.json
```

## Verification

```sh
./scripts/verify.sh
```

Smoke the signed pairing/transfer path without a phone:

```sh
./scripts/smoke-signed-transfer.sh
```

## Local Packaging

Build a local menu-bar app bundle:

```sh
./scripts/build-macos-app.sh
open dist/Linkit.app
```

Install the Android debug build:

```sh
./scripts/install-android-debug.sh
```

Protocol details:

- [`protocol/phase0.md`](protocol/phase0.md)
- [`protocol/phase1.md`](protocol/phase1.md)
- [`protocol/mvp.md`](protocol/mvp.md)

The Phase 1 receiver also advertises `_linkit._tcp.local.`:

```sh
dns-sd -B _linkit._tcp local
```
