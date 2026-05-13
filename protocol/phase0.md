# Linkit Phase 0 Protocol

Phase 0 proves one Android-to-macOS transfer path without pairing UX.

## Transport

- Plain HTTP over private LAN or link-local network.
- macOS receiver listens on fixed port `52718`.
- Every `/v1/transfers` request requires:

```txt
Authorization: Bearer <launch-generated-dev-token>
```

- `GET /v1/info` is intentionally unauthenticated so Android can test reachability.
- The dev token is generated on every receiver launch and printed locally.

## Error Shape

All non-2xx JSON errors use:

```json
{
  "error": "token_rejected",
  "message": "Authorization bearer token was not accepted"
}
```

## Create Transfer

```txt
POST /v1/transfers
```

```json
{
  "clientDeviceId": "android-phase0",
  "files": [
    {
      "name": "photo.jpg",
      "size": 1234567,
      "mimeType": "image/jpeg",
      "clientSha256": null
    }
  ]
}
```

Phase 0 accepts exactly one file per transfer.

Response:

```json
{
  "transferId": "tr_...",
  "uploadUrl": "/v1/transfers/tr_.../files/0",
  "finalizeUrl": "/v1/transfers/tr_.../finalize",
  "statusUrl": "/v1/transfers/tr_...",
  "uploadToken": "...",
  "uploadTokenExpiresAt": "2026-05-13T18:30:00Z",
  "expiresAt": "2026-05-13T19:25:00Z"
}
```

## Upload File

```txt
PUT /v1/transfers/:id/files/:index
Authorization: Bearer <launch-token>
X-Linkit-Upload-Token: <single-use-upload-token>
Content-Length: <size>
Content-Type: application/octet-stream
```

The receiver writes to:

```txt
~/Downloads/Linkit Drop/.tmp/<transferId>-<index>.part
```

It hashes bytes while streaming and never buffers the whole file in memory.

Response:

```json
{
  "transferId": "tr_...",
  "fileIndex": 0,
  "bytesReceived": 1234567,
  "serverSha256": "..."
}
```

## Finalize

```txt
POST /v1/transfers/:id/finalize
```

```json
{
  "bytesSent": 1234567,
  "finalSha256": "..."
}
```

The receiver only publishes the file if:

- uploaded bytes equal expected size,
- `bytesSent` equals expected size,
- streamed server SHA-256 equals `finalSha256`,
- optional `clientSha256` from create also matches.

Final publication uses same-volume atomic no-overwrite rename into:

```txt
~/Downloads/Linkit Drop
```

Finalize is idempotent. Replaying the same finalize payload after success or failure returns the same saved result or same failure.

## Status

```txt
GET /v1/transfers/:id
```

```json
{
  "transferId": "tr_...",
  "status": "complete",
  "bytesReceived": 1234567,
  "expectedSize": 1234567,
  "serverSha256": "...",
  "savedPath": "/Users/onepiece/Downloads/Linkit Drop/photo.jpg",
  "error": null
}
```

## Cancel

```txt
DELETE /v1/transfers/:id
```

Cancellation marks the transfer canceled and removes its `.part` file.

## Expiry And Cleanup

- Session expiry: 1 hour.
- Upload token expiry: 5 minutes or session expiry, whichever is sooner.
- Receiver startup removes `.tmp/*.part` files older than 1 hour.
