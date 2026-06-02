# Linkit Phase 1 Protocol

Phase 1 keeps Android on manual IP, but makes the receiver behave like a real transfer-session server.

## Discovery

The macOS receiver advertises:

```txt
_linkit._tcp.local.
```

Debug with:

```sh
dns-sd -B _linkit._tcp local
```

TXT records:

```txt
v=1
phase=1
api=/v1
```

## Session Shape

`POST /v1/transfers` still accepts one file in the Android UI, but responses are shaped as a session containing files:

```json
{
  "transferId": "tr_...",
  "status": "created",
  "clientDeviceId": "android-phase1-manual",
  "files": [
    {
      "index": 0,
      "name": "photo.jpg",
      "safeName": "photo.jpg",
      "size": 1234567,
      "mimeType": "image/jpeg",
      "status": "created",
      "uploadUrl": "/v1/transfers/tr_.../files/0",
      "uploadToken": "...",
      "uploadTokenExpiresAt": "2026-05-13T18:30:00Z"
    }
  ],
  "uploadUrl": "/v1/transfers/tr_.../files/0",
  "finalizeUrl": "/v1/transfers/tr_.../finalize",
  "statusUrl": "/v1/transfers/tr_...",
  "uploadToken": "...",
  "uploadTokenExpiresAt": "2026-05-13T18:30:00Z",
  "expiresAt": "2026-05-13T19:25:00Z"
}
```

The top-level `uploadUrl` and `uploadToken` stay for Phase 0 client compatibility.

## Upload Token Binding

Upload requires:

```txt
Authorization: Bearer <launch-token>
X-Linkit-Upload-Token: <single-use-upload-token>
X-Linkit-Client-Device-Id: <same clientDeviceId used at create>
Content-Length: <expected file size>
```

The receiver validates the upload token against:

- `transferId`
- `fileIndex`
- `expectedSize`
- `clientDeviceId`
- token expiry
- single-use state

`PUT` bodies are still not signed in Phase 1.

## Finalize

Finalize remains idempotent. The response also includes `files[]`:

```json
{
  "transferId": "tr_...",
  "status": "complete",
  "files": [
    {
      "index": 0,
      "name": "photo.jpg",
      "size": 1234567,
      "status": "complete",
      "savedPath": "/Users/onepiece/Downloads/Linkit Drop/photo.jpg",
      "bytesReceived": 1234567,
      "sha256": "...",
      "error": null
    }
  ],
  "savedPath": "/Users/onepiece/Downloads/Linkit Drop/photo.jpg",
  "bytesReceived": 1234567,
  "sha256": "...",
  "error": null,
  "message": null
}
```

Replaying the same finalize payload returns the same saved result or same failure. Replaying with a different payload returns `409 finalize_payload_mismatch`.

## Later Signed Actions

The current private build has moved beyond Phase 1 for paired devices:

- transfer cancel uses signed `DELETE /v1/transfers/:id`;
- text, clipboard, and URL handoff use signed `POST /v1/actions`;
- Mac → Android clipboard watching can run from the Mac menu-bar app;
- Android → Mac clipboard watching is foreground-only because Android 10+ blocks background clipboard reads for ordinary apps.

See [`mvp.md`](mvp.md) for the current signed action shape.
