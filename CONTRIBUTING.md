# Contributing to Linkit

Thanks for your interest. Linkit is a small, private Android↔Mac local link, and
contributions are welcome — but there are a few things that are non-negotiable
because of how the project works.

## Before you start

- Read [`docs/SETUP.md`](docs/SETUP.md) for the dev environment and build scripts.
- Read [`docs/current-state.md`](docs/current-state.md) for the feature snapshot.
- The architecture and invariants are in [`CLAUDE.md`](CLAUDE.md) — especially the
  trust/crypto model. **Read it before touching anything protocol-related.**

## The lockstep rule (most important)

The two apps share **one wire format** implemented twice — in Swift (`macos/`) and
Kotlin (`android/`). Any change to **signing, canonical strings, the encryption
layer, routes, the QR/pairing payload, or the protocol version** must land on
**both** sides in the same PR and stay byte-for-byte compatible. A PR that changes
one side only will be rejected. The golden-vector tests (`*ProtocolVectors*`) exist
to catch divergence — keep them green and extend them when you change the format.

## Checks before you open a PR

Run the full local verification:

```sh
./scripts/verify.sh        # swift test + Mac build + Android unit tests + debug build
```

For protocol/transfer changes, also run:

```sh
./scripts/smoke-signed-transfer.sh
```

## Style

- Commit messages: short single-line subject, no body, no `Co-Authored-By` trailer.
- Match the surrounding code's naming, structure, and comment density.
- Don't commit secrets. `android/keystore.properties`, `android/local.properties`,
  and `*.keystore` are gitignored — keep it that way.

## Contributor license terms (please read)

Linkit is licensed to the public under the **GNU GPLv3** (see [`LICENSE`](LICENSE)).
To keep the project able to evolve (including future relicensing or dual-licensing
decisions made by the maintainer), contributions are accepted under the following
terms. **By submitting a contribution** (pull request, patch, or code in an issue),
you agree that:

1. You are the author of the contribution, or otherwise have the right to submit it,
   and you submit it of your own free will.
2. You license your contribution to the public under the **GPLv3**, the same license
   as the project.
3. You **additionally** grant the maintainer (Krishna, [@kalki-kgp](https://github.com/kalki-kgp))
   a perpetual, worldwide, royalty-free, irrevocable, non-exclusive license to use,
   reproduce, modify, sublicense, **relicense, and distribute** your contribution as
   part of Linkit, under the GPLv3 **or any other license the maintainer later
   chooses** for the project.
4. You grant no trademark rights; **"Linkit"** and its logo remain the maintainer's.
5. You provide the contribution "as is", without warranty of any kind.

This is what lets the project stay genuinely open source today while keeping the
door open to relicensing decisions later. If you can't agree to these terms, please
don't submit a contribution.
