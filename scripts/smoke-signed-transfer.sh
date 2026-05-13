#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-52719}"
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
        } else {
            result = .success(HTTPResult(status: (response as! HTTPURLResponse).statusCode, data: data ?? Data()))
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

let payload = try json(Data(ProcessInfo.processInfo.environment["PAYLOAD"]!.utf8))
let token = payload["pairingToken"] as! String
let port = ProcessInfo.processInfo.environment["PORT"]!
let base = "http://127.0.0.1:\(port)"

let privateKey = P256.Signing.PrivateKey()
let publicKey = privateKey.publicKey.x963Representation.base64EncodedString()
let deviceId = String(hex(Data(SHA256.hash(data: privateKey.publicKey.x963Representation))).prefix(32))

let pairBody = try jsonBody([
    "deviceId": deviceId,
    "deviceName": "signed-smoke",
    "platform": "android",
    "publicKey": publicKey,
    "pairingToken": token
])
var pair = URLRequest(url: URL(string: base + "/v1/pair")!)
pair.httpMethod = "POST"
pair.httpBody = Data(pairBody.utf8)
pair.setValue("application/json", forHTTPHeaderField: "Content-Type")
let pairResponse = try request(pair)
precondition(pairResponse.status == 200, String(data: pairResponse.data, encoding: .utf8)!)

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
let uploadUrl = file["uploadUrl"] as! String
let uploadToken = file["uploadToken"] as! String
var upload = URLRequest(url: URL(string: base + uploadUrl)!)
upload.httpMethod = "PUT"
upload.httpBody = bytes
upload.setValue(uploadToken, forHTTPHeaderField: "X-Linkit-Upload-Token")
upload.setValue(deviceId, forHTTPHeaderField: "X-Linkit-Client-Device-Id")
upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
let uploadResponse = try request(upload)
precondition(uploadResponse.status == 200, String(data: uploadResponse.data, encoding: .utf8)!)

let finalizeUrl = createJson["finalizeUrl"] as! String
let finalizeBody = try jsonBody(["bytesSent": bytes.count, "finalSha256": sha])
let finalize = try request(signed(method: "POST", url: base + finalizeUrl, path: finalizeUrl, body: finalizeBody, key: privateKey, deviceId: deviceId))
precondition(finalize.status == 200, String(data: finalize.data, encoding: .utf8)!)

let savedPath = (try json(finalize.data))["savedPath"] as! String
let saved = try Data(contentsOf: URL(fileURLWithPath: savedPath))
precondition(saved == bytes)
print(savedPath)
SWIFT
