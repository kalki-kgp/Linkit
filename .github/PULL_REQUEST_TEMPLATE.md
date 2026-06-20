## Summary

<!-- What does this change and why? -->

## Checklist

- [ ] I ran `./scripts/verify.sh` (swift test + Mac build + Android unit tests + debug build).
- [ ] **Lockstep:** if this touches signing, canonical strings, the encryption layer,
      routes, the QR/pairing payload, or the protocol version, I changed **both** the
      Swift (`macos/`) and Kotlin (`android/`) sides and they stay byte-for-byte compatible.
- [ ] For protocol/transfer changes, I ran `./scripts/smoke-signed-transfer.sh` and/or
      updated the golden-vector tests.
- [ ] I updated `docs/current-state.md` if behavior changed.
- [ ] Commit messages are short single-line subjects (no body, no `Co-Authored-By`).
- [ ] I agree to the contributor terms in [CONTRIBUTING.md](../CONTRIBUTING.md).
