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

Known hardening follow-up: Keychain storage is in place for personal builds. Secure Enclave-backed keys are still a later distribution hardening option.

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
