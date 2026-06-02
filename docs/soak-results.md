# Linkit Soak Test Results

Use this once before trusting Linkit as a daily tool. Run both paths with the same 1 GB file.

## Test File

```sh
mkfile -n 1g ~/Downloads/linkit-soak-1gb.bin
shasum -a 256 ~/Downloads/linkit-soak-1gb.bin
```

On Android, use any existing 1 GB file or copy this one to the phone first.

## Same Wi-Fi

| Direction | Network | File size | Time | Average speed | Battery start/end | Result | Notes |
|-----------|---------|-----------|------|---------------|-------------------|--------|-------|
| Android -> Mac | Local run | 1 GB | 49s | 21.9 MB/s | Not recorded | Pass | Created `2026-05-23T13:47:11Z`, finalized `2026-05-23T13:48:00Z`; SHA-256 matched; `.tmp` empty. |
| Mac -> Android | Local run | 1 GB | Not captured | Not captured | Not recorded | Pass | Mac log recorded `sent file to Android` at `2026-05-23T12:58:17Z` with `1073741824` bytes. |

## Phone Hotspot

Turn on the Android hotspot, connect the Mac to that hotspot, open Linkit on both devices, then scan a fresh Mac QR if the cached IP is stale.

| Direction | Network | File size | Time | Average speed | Battery start/end | Result | Notes |
|-----------|---------|-----------|------|---------------|-------------------|--------|-------|
| Android -> Mac | Phone hotspot | 1 GB | Not captured | Not captured | Not recorded | User-confirmed pass | Record exact timing on the next hotspot run. |
| Mac -> Android | Phone hotspot | 1 GB | Not captured | Not captured | Not recorded | User-confirmed pass | Record exact timing on the next hotspot run. |

## 2026-05-23 Evidence

```txt
Source SHA-256:
49bc20df15e412a64472421e13fe86ff1c5165e18b2afccf160d4dc19fe68a14  /Users/onepiece/Downloads/linkit-soak-1gb.bin

Android -> Mac SHA-256:
49bc20df15e412a64472421e13fe86ff1c5165e18b2afccf160d4dc19fe68a14  /Users/onepiece/Downloads/Linkit Drop/linkit-soak-1gb.bin

Mac temp folder:
~/Downloads/Linkit Drop/.tmp was empty after completion.
```

## Pass Criteria

- Transfer completes without app crash.
- Destination file exists in the expected Linkit Drop folder.
- SHA-256 matches the source file.
- No stuck temp file remains after success.
- Failure, if any, is visible in app status or logs.

## Useful Checks

```sh
shasum -a 256 ~/Downloads/Linkit\ Drop/linkit-soak-1gb.bin
ls -lah ~/Downloads/Linkit\ Drop/.tmp
tail -100 ~/Library/Logs/Linkit/transfer.log
```
