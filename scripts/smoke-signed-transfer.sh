#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${PORT:-}" ]]; then
  PORT="$(jot -r 1 49152 61000 2>/dev/null || shuf -i 49152-61000 -n 1)"
fi
DROP="${DROP:-/tmp/linkit-smoke-drop}"
LOG="$(mktemp /tmp/linkit-smoke-receiver.XXXXXX)"

rm -rf "$DROP"

cleanup() {
  if [[ -n "${RECEIVER_PID:-}" ]]; then
    kill "$RECEIVER_PID" >/dev/null 2>&1 || true
    wait "$RECEIVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT/macos"
swift run LinkitMacReceiver --port "$PORT" --destination "$DROP" --no-bonjour >"$LOG" 2>&1 &
RECEIVER_PID=$!

for _ in {1..80}; do
  if grep -q '^Pairing payload: ' "$LOG"; then
    break
  fi
  sleep 0.1
done

PAYLOAD="$(sed -n 's/^Pairing payload: //p' "$LOG" | tail -n 1)"
if [[ -z "$PAYLOAD" ]]; then
  cat "$LOG"
  echo "receiver did not print a pairing payload" >&2
  exit 1
fi

PAYLOAD="$PAYLOAD" PORT="$PORT" swift - <<'SWIFT'
import CryptoKit
import Foundation

struct HTTPResult { let status: Int; let data: Data }

func request(_ request: URLRequest) throws -> HTTPResult {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<HTTPResult, Error>!
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            result = .failure(error)
        } else if let http = response as? HTTPURLResponse {
            result = .success(HTTPResult(status: http.statusCode, data: data ?? Data()))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return try result.get()
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func jsonBody(_ object: Any) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
}

func json(_ data: Data) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

func signed(method: String, url: String, path: String, body: String, key: P256.Signing.PrivateKey, deviceId: String) -> URLRequest {
    let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let bodyHash = hex(Data(SHA256.hash(data: Data(body.utf8))))
    let canonical = [method, path, timestamp, nonce, bodyHash].joined(separator: "\n")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    let signature = try! key.signature(for: digest).derRepresentation.base64EncodedString()

    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    request.setValue(deviceId, forHTTPHeaderField: "X-Linkit-Device-Id")
    request.setValue(timestamp, forHTTPHeaderField: "X-Linkit-Timestamp")
    request.setValue(nonce, forHTTPHeaderField: "X-Linkit-Nonce")
    request.setValue(signature, forHTTPHeaderField: "X-Linkit-Signature")
    if !body.isEmpty {
        request.httpBody = Data(body.utf8)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    }
    return request
}

func pairChallengeCanonical(macDeviceId: String, androidDeviceId: String, androidPublicKey: String, pairingToken: String, challenge: String) -> String {
    ["LINKIT_PAIR", macDeviceId, androidDeviceId, androidPublicKey, pairingToken, challenge].joined(separator: "\n")
}

func uploadCanonical(deviceId: String, transferId: String, fileIndex: Int, uploadToken: String, contentLength: Int, timestamp: String, nonce: String) -> String {
    ["UPLOAD", deviceId, transferId, "\(fileIndex)", uploadToken, "\(contentLength)", timestamp, nonce].joined(separator: "\n")
}

func signUpload(_ request: inout URLRequest, deviceId: String, transferId: String, uploadToken: String, contentLength: Int, key: P256.Signing.PrivateKey) {
    let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let canonical = uploadCanonical(
        deviceId: deviceId,
        transferId: transferId,
        fileIndex: 0,
        uploadToken: uploadToken,
        contentLength: contentLength,
        timestamp: timestamp,
        nonce: nonce
    )
    let digest = SHA256.hash(data: Data(canonical.utf8))
    let signature = try! key.signature(for: digest).derRepresentation.base64EncodedString()
    request.setValue(deviceId, forHTTPHeaderField: "X-Linkit-Device-Id")
    request.setValue(timestamp, forHTTPHeaderField: "X-Linkit-Timestamp")
    request.setValue(nonce, forHTTPHeaderField: "X-Linkit-Nonce")
    request.setValue(signature, forHTTPHeaderField: "X-Linkit-Signature")
}

let payload = try json(Data(ProcessInfo.processInfo.environment["PAYLOAD"]!.utf8))
let token = payload["pairingToken"] as! String
let challenge = payload["pairingChallenge"] as! String
let macDeviceId = payload["deviceId"] as! String
let port = ProcessInfo.processInfo.environment["PORT"]!
let base = "http://127.0.0.1:\(port)"

let privateKey = P256.Signing.PrivateKey()
let publicKey = privateKey.publicKey.x963Representation.base64EncodedString()
let deviceId = String(hex(Data(SHA256.hash(data: privateKey.publicKey.x963Representation))).prefix(32))
let pairCanonical = pairChallengeCanonical(
    macDeviceId: macDeviceId,
    androidDeviceId: deviceId,
    androidPublicKey: publicKey,
    pairingToken: token,
    challenge: challenge
)
let pairSignature = try privateKey.signature(for: SHA256.hash(data: Data(pairCanonical.utf8))).derRepresentation.base64EncodedString()

let pairBody = try jsonBody([
    "deviceId": deviceId,
    "deviceName": "signed-smoke",
    "platform": "android",
    "publicKey": publicKey,
    "pairingToken": token,
    "pairingChallenge": challenge,
    "pairingChallengeSignature": pairSignature
])
var pair = URLRequest(url: URL(string: base + "/v1/pair")!)
pair.httpMethod = "POST"
pair.httpBody = Data(pairBody.utf8)
pair.setValue("application/json", forHTTPHeaderField: "Content-Type")
let pairResponse = try request(pair)
precondition(pairResponse.status == 200, String(data: pairResponse.data, encoding: .utf8)!)

var bad = signed(method: "GET", url: base + "/v1/history", path: "/v1/history", body: "", key: privateKey, deviceId: deviceId)
bad.setValue("bad-signature", forHTTPHeaderField: "X-Linkit-Signature")
let badResponse = try request(bad)
precondition(badResponse.status == 401, "bad signature should return 401")

let bytes = Data("signed smoke\n".utf8)
let sha = hex(Data(SHA256.hash(data: bytes)))
let createBody = try jsonBody([
    "clientDeviceId": deviceId,
    "files": [[
        "name": "signed-smoke.txt",
        "size": bytes.count,
        "mimeType": "text/plain",
        "clientSha256": NSNull()
    ]]
])
let create = try request(signed(method: "POST", url: base + "/v1/transfers", path: "/v1/transfers", body: createBody, key: privateKey, deviceId: deviceId))
precondition(create.status == 201, String(data: create.data, encoding: .utf8)!)

let createJson = try json(create.data)
let file = (createJson["files"] as! [[String: Any]])[0]
let transferId = createJson["transferId"] as! String
let uploadUrl = "/v1/transfers/\(transferId)/files/0"
let uploadToken = file["uploadToken"] as! String
var upload = URLRequest(url: URL(string: base + uploadUrl)!)
upload.httpMethod = "PUT"
upload.httpBody = bytes
upload.setValue(uploadToken, forHTTPHeaderField: "X-Linkit-Upload-Token")
upload.setValue(deviceId, forHTTPHeaderField: "X-Linkit-Client-Device-Id")
upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
signUpload(&upload, deviceId: deviceId, transferId: transferId, uploadToken: uploadToken, contentLength: bytes.count, key: privateKey)
let uploadResponse = try request(upload)
precondition(uploadResponse.status == 200, String(data: uploadResponse.data, encoding: .utf8)!)

let finalizeUrl = "/v1/transfers/\(transferId)/finalize"
let finalizeBody = try jsonBody(["bytesSent": bytes.count, "finalSha256": sha])
let finalize = try request(signed(method: "POST", url: base + finalizeUrl, path: finalizeUrl, body: finalizeBody, key: privateKey, deviceId: deviceId))
precondition(finalize.status == 200, String(data: finalize.data, encoding: .utf8)!)

let savedPath = (try json(finalize.data))["savedPath"] as! String
let saved = try Data(contentsOf: URL(fileURLWithPath: savedPath))
precondition(saved == bytes)
print(savedPath)
SWIFT
