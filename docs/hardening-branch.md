# MVP Hardening Branch

Branch: `reverse-sharing`

This branch keeps the private MVP flow intact and adds daily-use polish:

- macOS transfer history persisted in `~/Library/Application Support/Linkit/transfer-history.json`
- Recent transfers and diagnostics in the macOS menu-bar menu
- macOS private identity key stored in Keychain, with one-time migration from the old `mac-identity.p256` file
- Preferences window with launch-at-login control for packaged `.app` builds
- Dark compact Android UI tuned for quick pairing/sending
- Hotspot/flaky-network hints in the Android pairing/connection flow
- Local `.app` packaging script for the menu-bar receiver
- Signed smoke test script for pair/create/upload/finalize without a phone
- Symmetric Mac-to-Android sharing with signed upload slots and QR challenge pairing
- Cancel button in the macOS transfer popup, wired to local abort and signed remote cancellation where applicable
- Signed text/link action channel for clipboard text, plain-text handoff, and opening links on the other device
- Mac menu actions for sending clipboard text, opening clipboard links on Android, and Mac-side clipboard text sync
- Android app/share-sheet actions for sending clipboard text and opening links on the Mac

Known hardening follow-up: Keychain storage is in place for personal builds. Secure Enclave-backed keys are still a later distribution hardening option.

Android clipboard note: Android 10+ only lets ordinary apps read clipboard contents while focused or acting as the active input method. Mac → Android clipboard sync can run from the menu-bar app. Android → Mac automatic clipboard sync is foreground-only; background Android copies should use the Linkit share sheet or the explicit **Send Clipboard** button.

## Commands

```sh
./scripts/verify.sh
./scripts/smoke-signed-transfer.sh
./scripts/build-macos-app.sh
open dist/Linkit.app
```

## Useful Files

```txt
~/Downloads/Linkit Drop
~/Downloads/Linkit Drop/.tmp
~/Library/Logs/Linkit/transfer.log
~/Library/Application Support/Linkit/trusted-devices.json
~/Library/Application Support/Linkit/transfer-history.json
```
