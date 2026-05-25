# Linkit MVP Protocol

The MVP path is:

1. macOS shows a QR payload with Mac identity, IP, port, public key, and a short-lived pairing token.
2. Android scans QR or enters IP/port/token manually.
3. Android posts `/v1/pair` with its P-256 public key.
4. macOS stores the Android device as trusted.
5. Android signs transfer control requests.
6. File bytes upload with a single-use upload token and are verified by streamed SHA-256 before final save.
7. Reconnect treats Bonjour as address discovery only; Android verifies the Mac private key with `/v1/identity/proof` before saving a rediscovered endpoint.
8. Paired devices can also send signed local text/link actions over `/v1/actions`.

## Signed Control Headers

Control requests after pairing use P-256 ECDSA + SHA-256:

```txt
X-Linkit-Device-Id: <android device id>
X-Linkit-Timestamp: <unix ms>
X-Linkit-Nonce: <random nonce>
X-Linkit-Signature: <base64 DER ECDSA signature>
```

Canonical string:

```txt
METHOD
/path/only
timestamp
nonce
hex_sha256(request_body)
```

The receiver verifies:

- trusted device id,
- timestamp within `±60s`,
- nonce unused for `120s`,
- P-256 signature against the trusted peer public key.

## Mac Identity Proof

Android uses identity proof after Bonjour rediscovery and before stale-presence demotion. The request is intentionally small and does not replace signed control requests:

```txt
POST /v1/identity/proof
```

Request:

```json
{
  "challenge": "random-client-challenge"
}
```

Response:

```json
{
  "protocolVersion": 1,
  "deviceId": "paired-mac-device-id",
  "deviceName": "Krishna Mac",
  "platform": "macos",
  "publicKey": "base64...",
  "challenge": "random-client-challenge",
  "signature": "base64 DER ECDSA signature"
}
```

The signature is over:

```txt
LINKIT_IDENTITY_PROOF
deviceId
publicKey
challenge
```

Android rejects the endpoint unless `deviceId`, `publicKey`, `challenge`, and the signature all match the already paired Mac.

## Pairing QR

The QR payload is JSON:

```json
{
  "v": 1,
  "deviceId": "mac-device-id",
  "deviceName": "Krishna's MacBook Air",
  "platform": "macos",
  "ip": "192.168.1.10",
  "port": 52718,
  "publicKey": "base64-x963-p256-public-key",
  "pairingToken": "short-lived-token",
  "pairingChallenge": "single-use-random-challenge",
  "pairingTokenExpiresAt": "2026-05-13T18:51:07Z"
}
```

The token/challenge TTL is 2 minutes. Android signs a canonical pairing challenge with its P-256 private key before `POST /v1/pair`; the Mac verifies that signature against the Android public key (and against the Mac's own server-side `expected.challenge`, not whatever the client echoed) before it stores trust.

The pair-request canonical string is:

```txt
LINKIT_PAIR
<macDeviceId>
<androidDeviceId>
<androidPublicKey>     # base64 x963 representation, byte-identical to the QR payload
<pairingToken>
<pairingChallenge>
```

`POST /v1/pair` body includes `pairingChallenge` and `pairingChallengeSignature` (base64 DER ECDSA over `SHA256(canonical)`) alongside the existing `deviceId`/`deviceName`/`platform`/`publicKey`/`pairingToken` fields.

## Upload

The file `PUT` streams the body unsigned, but the upload slot is signed by the paired device key:

```txt
PUT /v1/transfers/:id/files/:index
X-Linkit-Upload-Token: <single-use token>
X-Linkit-Client-Device-Id: <paired Android device id>
X-Linkit-Device-Id: <paired Android device id>
X-Linkit-Timestamp: <unix-ms>
X-Linkit-Nonce: <random>
X-Linkit-Signature: ECDSA_SHA256("UPLOAD\n<deviceId>\n<transferId>\n<fileIndex>\n<uploadToken>\n<contentLength>\n<timestamp>\n<nonce>")
Content-Length: <expected size>
```

The receiver binds the token to `transferId`, `fileIndex`, `expectedSize`, `clientDeviceId`, expiry, single-use state, and the upload signature.

## Cancel

Transfers can be canceled with a signed control request:

```txt
DELETE /v1/transfers/:id
```

The receiver validates the signed control headers, confirms the requester owns the transfer, marks the session `canceled`, and removes the in-flight temp file. For Mac → Android sends, the Mac also aborts its local upload task before sending the remote cancel.

## Text And Link Actions

Paired devices can send small local actions without wrapping them as fake files:

```txt
POST /v1/actions
Content-Type: application/json
```

Body:

```json
{
  "type": "clipboard",
  "text": "hello"
}
```

Supported action types:

- `clipboard` — set the other device clipboard to plain text.
- `text` — plain-text handoff; currently treated like clipboard receive.
- `open_url` — open an `http` or `https` URL on the other device.

Rules:

- Request body is signed with the normal signed control headers.
- `text` must be 1 byte to 128 KB.
- `open_url` only accepts `http` and `https`.
- Actions stay on the LAN; there is no cloud relay.

Android clipboard limitation: Android 10+ does not allow ordinary background apps to read clipboard contents unless the app is focused or is the active input method. Linkit can receive clipboard text in the background, but automatic Android → Mac clipboard watching is foreground-only. Use the Android share sheet or the explicit **Send Clipboard** action for background copies.
