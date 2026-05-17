# MVP Hardening Branch

Branch: `reverse-sharing`

This branch keeps the private MVP flow intact and adds daily-use polish:

- macOS transfer history persisted in `~/Library/Application Support/Linkit/transfer-history.json`
- Recent transfers and diagnostics in the macOS menu-bar menu
- Dark compact Android UI tuned for quick pairing/sending
- Local `.app` packaging script for the menu-bar receiver
- Signed smoke test script for pair/create/upload/finalize without a phone
- Symmetric Mac-to-Android sharing with signed upload slots and QR challenge pairing

Known hardening follow-up: macOS still stores its MVP P-256 private key as a `0600` file under Application Support. Move it to Keychain or Secure Enclave before distributing beyond personal builds.

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
