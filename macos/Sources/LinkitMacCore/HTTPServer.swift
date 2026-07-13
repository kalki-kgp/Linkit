import CryptoKit
import Darwin
import Foundation

struct HTTPRequest {
    let method: String
    let target: String
    let path: String
    let headers: [String: String]
    let contentLength: Int64
    let bodyRemainder: Data
    let remoteHost: String?
}

struct HTTPResponse {
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data
}

public final class LinkitReceiverApp {
    public let configuration: ReceiverConfiguration
    public let devToken: String
    public let dropFolder: URL
    public let logFile: URL
    public let identity: LinkitIdentity

    private let logger: LinkitLogger
    private let store: TransferStore
    private let history: TransferHistoryStore
    private let server: HTTPServer
    private let bonjour: BonjourAdvertiser?
    private let trustStore: TrustStore
    private let connections: DeviceConnectionRegistry
    private let pairingManager: PairingManager
    private let outgoingClient: OutgoingTransferClient

    public init(
        configuration: ReceiverConfiguration = ReceiverConfiguration(),
        bluetoothAddressProvider: @escaping () -> String? = { nil },
        localFeaturesProvider: @escaping () -> [FeatureStatus] = { [] }
    ) throws {
        self.configuration = configuration
        self.devToken = try LinkitRandom.token()
        self.dropFolder = configuration.destination
        self.logger = try LinkitLogger()
        self.logFile = logger.fileURL
        self.identity = try IdentityStore().loadOrCreate()
        self.trustStore = try TrustStore()
        self.connections = DeviceConnectionRegistry()
        self.pairingManager = try PairingManager(identity: identity, trustStore: trustStore, connections: connections, logger: logger)
        self.history = try TransferHistoryStore()
        self.outgoingClient = OutgoingTransferClient(identity: identity, logger: logger)
        self.store = try TransferStore(destination: configuration.destination, logger: logger, history: history)
        self.store.sweepOrphans()
        self.bonjour = configuration.advertiseBonjour
            ? BonjourAdvertiser(
                port: configuration.port,
                serviceName: LinkitReceiverApp.defaultBonjourName(),
                logger: logger
            )
            : nil
        self.server = HTTPServer(
            port: configuration.port,
            token: devToken,
            allowDevBearerTransfers: configuration.allowDevBearerTransfers,
            identity: identity,
            trustStore: trustStore,
            connections: connections,
            pairingManager: pairingManager,
            store: store,
            history: history,
            logger: logger,
            bluetoothAddressProvider: bluetoothAddressProvider,
            localFeaturesProvider: localFeaturesProvider
        )
    }

    public func run() throws {
        bonjour?.start()
        try server.run()
    }

    public func pairingPayload(ip: String = LocalNetwork.bestPrivateIPv4()) -> PairingPayload {
        pairingManager.pairingPayload(ip: ip, port: configuration.port)
    }

    public func pairingPayloadJSON(ip: String = LocalNetwork.bestPrivateIPv4()) -> String {
        let payload = pairingPayload(ip: ip)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public func trustedDevices() -> [TrustedDevice] {
        trustStore.allDevices()
    }

    public func connectedDevices() -> [ConnectedDevice] {
        connections.allConnected()
    }

    public func disconnectDevice(_ deviceId: String) {
        connections.disconnect(deviceId: deviceId)
    }

    public func refreshConnectedDevice(_ deviceId: String) throws -> ConnectedDevice {
        guard let connected = connections.connectedDevice(id: deviceId),
              let trusted = trustStore.trustedDevice(id: deviceId)
        else {
            throw HTTPFailure.badRequest("device_not_connected", "Device is not connected")
        }
        let target = TrustedDevice(
            deviceId: trusted.deviceId,
            deviceName: trusted.deviceName,
            platform: trusted.platform,
            publicKey: trusted.publicKey,
            pairedAt: trusted.pairedAt,
            lastKnownHost: connected.host,
            receivePort: connected.receivePort,
            pairingSecret: trusted.pairingSecret
        )
        let status = try outgoingClient.status(of: target)
        return connections.refreshStatus(deviceId: deviceId, batteryPercent: status.batteryPercent, features: status.features) ?? connected
    }

    public func forgetDevice(_ deviceId: String) throws {
        _ = try trustStore.remove(deviceId: deviceId)
        connections.disconnect(deviceId: deviceId)
    }

    public func sendFilesToFirstAndroid(
        _ files: [URL],
        cancellation: LinkitCancellationToken? = nil,
        onProgress: ((OutgoingTransferProgress) -> Void)? = nil
    ) throws -> [OutgoingTransferResult] {
        try outgoingClient.send(files: files, to: firstConnectedAndroid(), cancellation: cancellation, onProgress: onProgress)
    }

    public func sendActionToFirstAndroid(_ action: LinkitActionRequest) throws -> LinkitActionResponse {
        try outgoingClient.sendAction(action, to: firstConnectedAndroid())
    }

    public func fetchPhonebookFromFirstAndroid() throws -> PhonebookResponse {
        try outgoingClient.fetchPhonebook(of: firstConnectedAndroid())
    }

    public func cancelIncomingTransfer(_ transferId: String) throws {
        _ = try store.cancel(id: transferId)
    }

    private func firstConnectedAndroid() throws -> TrustedDevice {
        if let connected = connections.allConnected().first(where: { $0.platform.lowercased() == "android" }),
           let trusted = trustStore.trustedDevice(id: connected.deviceId) {
            return TrustedDevice(
                deviceId: trusted.deviceId,
                deviceName: trusted.deviceName,
                platform: trusted.platform,
                publicKey: trusted.publicKey,
                pairedAt: trusted.pairedAt,
                lastKnownHost: connected.host,
                receivePort: connected.receivePort,
                pairingSecret: trusted.pairingSecret
            )
        }
        // The presence sweep may have marked the phone disconnected during a screen-off
        // Wi-Fi lull even though it can still be reached. Probe its last-known address and,
        // if it answers, treat it as connected again instead of failing the drop outright.
        if let revived = reviveTrustedAndroid() {
            return revived
        }
        throw HTTPFailure.badRequest("missing_android_receiver", "Connect your Android first by opening Linkit or scanning the QR, then drop the file again")
    }

    private func reviveTrustedAndroid() -> TrustedDevice? {
        let candidates = trustStore.allDevices().filter {
            $0.platform.lowercased() == "android" && $0.lastKnownHost != nil && $0.receivePort != nil
        }
        for candidate in candidates {
            guard let host = candidate.lastKnownHost, let port = candidate.receivePort else { continue }
            guard let status = try? outgoingClient.status(of: candidate) else { continue }
            _ = connections.markConnected(
                device: candidate,
                host: host,
                receivePort: port,
                batteryPercent: status.batteryPercent,
                features: status.features
            )
            logger.info("revived Android \(candidate.deviceId) at \(host):\(port) for outgoing send")
            return candidate
        }
        return nil
    }

    public func recentTransfers(limit: Int = 10) -> [TransferHistoryEntry] {
        history.recent(limit: limit)
    }

    private static func defaultBonjourName() -> String {
        let host = Host.current().localizedName ?? "Mac"
        return "Linkit \(host)"
    }
}

final class HTTPServer {
    private let port: UInt16
    private let token: String
    private let allowDevBearerTransfers: Bool
    private let identity: LinkitIdentity
    private let trustStore: TrustStore
    private let connections: DeviceConnectionRegistry
    private let pairingManager: PairingManager
    private let signedVerifier: SignedRequestVerifier
    private let store: TransferStore
    private let history: TransferHistoryStore
    private let logger: LinkitLogger
    private let bluetoothAddressProvider: () -> String?
    private let localFeaturesProvider: () -> [FeatureStatus]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Bound concurrent connections so a LAN peer cannot exhaust threads/FDs before auth.
    private static let maxConcurrentConnections = 16
    /// Per-connection inactivity timeout (recv/send) to defeat slowloris-style stalls.
    private static let socketTimeoutSeconds = 60
    private let connectionLimiter = DispatchSemaphore(value: HTTPServer.maxConcurrentConnections)

    init(
        port: UInt16,
        token: String,
        allowDevBearerTransfers: Bool,
        identity: LinkitIdentity,
        trustStore: TrustStore,
        connections: DeviceConnectionRegistry,
        pairingManager: PairingManager,
        store: TransferStore,
        history: TransferHistoryStore,
        logger: LinkitLogger,
        bluetoothAddressProvider: @escaping () -> String? = { nil },
        localFeaturesProvider: @escaping () -> [FeatureStatus] = { [] }
    ) {
        self.port = port
        self.token = token
        self.allowDevBearerTransfers = allowDevBearerTransfers
        self.identity = identity
        self.trustStore = trustStore
        self.connections = connections
        self.pairingManager = pairingManager
        self.signedVerifier = SignedRequestVerifier(trustStore: trustStore, logger: logger)
        self.store = store
        self.history = history
        self.logger = logger
        self.bluetoothAddressProvider = bluetoothAddressProvider
        self.localFeaturesProvider = localFeaturesProvider
    }

    func run() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(socketFD) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }
        guard listen(socketFD, SOMAXCONN) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        logger.info("receiver started port=\(port)")

        while true {
            var clientAddress = sockaddr_in()
            var clientAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(socketFD, $0, &clientAddressLength)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let remoteHost = HTTPServer.ipv4String(from: clientAddress)

            if connectionLimiter.wait(timeout: .now()) == .timedOut {
                logger.info("connection rejected port=\(port): too many concurrent connections")
                close(clientFD)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { self.connectionLimiter.signal() }
                self.handleConnection(clientFD, remoteHost: remoteHost)
            }
        }
    }

    private static func applyTimeout(to fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleConnection(_ fd: Int32, remoteHost: String?) {
        defer { close(fd) }
        HTTPServer.applyTimeout(to: fd, seconds: HTTPServer.socketTimeoutSeconds)

        do {
            guard let request = try readRequest(from: fd, remoteHost: remoteHost) else {
                return
            }
            let response = try route(request, fd: fd)
            try writeResponse(response, to: fd)
        } catch let failure as HTTPFailure {
            let response = jsonResponse(
                status: failure.status,
                body: ErrorResponse(error: failure.error, message: failure.message)
            )
            try? writeResponse(response, to: fd)
        } catch {
            logger.error("request failed error=\(error)")
            let response = jsonResponse(
                status: 500,
                body: ErrorResponse(error: "internal_error", message: "Internal receiver error")
            )
            try? writeResponse(response, to: fd)
        }
    }

    private func route(_ request: HTTPRequest, fd: Int32) throws -> HTTPResponse {
        if request.method == "GET", request.path == "/v1/info" {
            return jsonResponse(
                status: 200,
                body: InfoResponse(
                    protocolVersion: 1,
                    deviceId: identity.deviceId,
                    deviceName: Host.current().localizedName ?? "Linkit Mac",
                    platform: "macos",
                    port: port,
                    publicKey: identity.publicKey,
                    serviceType: "_linkit._tcp.local.",
                    capabilities: ["receive_files", "stream_sha256", "session_integrity", "signed_controls", "pairing", "bonjour", "identity_proof", "text_actions", "clipboard_text", "open_url", "phone_state", "call_audio", "notification_mirror"],
                    bluetoothAddress: bluetoothAddressProvider()
                )
            )
        }

        if request.method == "POST", request.path == "/v1/identity/proof" {
            let body = try readJSONBody(request, fd: fd, maxBytes: 16 * 1024)
            let proofRequest: IdentityProofRequest = try decodeJSON(body)
            return jsonResponse(status: 200, body: try identityProof(for: proofRequest))
        }

        if request.method == "POST", request.path == "/v1/pair" {
            let body = try readJSONBody(request, fd: fd, maxBytes: 32 * 1024)
            let pairRequest: PairRequest = try decodeJSON(body)
            return jsonResponse(status: 200, body: try pairingManager.pair(pairRequest, remoteHost: request.remoteHost))
        }

        if request.method == "POST", request.path == "/v1/devices/self" {
            let body = try readJSONBody(request, fd: fd, maxBytes: 16 * 1024)
            let deviceId = try authenticateControl(request, body: body)
            guard let deviceId, let remoteHost = request.remoteHost else {
                throw HTTPFailure.unauthorized("missing_device_connection", "Signed device connection is required")
            }
            let update: DeviceUpdateRequest = try decodeJSON(body)
            guard let device = trustStore.trustedDevice(id: deviceId) else {
                throw HTTPFailure.unauthorized("unknown_device", "Device is not paired")
            }
            let connected = connections.markConnected(
                device: device,
                host: remoteHost,
                receivePort: update.receivePort,
                batteryPercent: update.batteryPercent,
                features: update.features
            )
            trustStore.updateEndpoint(deviceId: deviceId, host: remoteHost, receivePort: update.receivePort)
            return jsonResponse(status: 200, body: connectionResponse(connected, status: "connected"))
        }

        if request.method == "DELETE", request.path == "/v1/devices/self" {
            let deviceId = try authenticateControl(request, body: Data())
            guard let deviceId, let device = trustStore.trustedDevice(id: deviceId) else {
                throw HTTPFailure.unauthorized("unknown_device", "Device is not paired")
            }
            connections.disconnect(deviceId: deviceId)
            return jsonResponse(
                status: 200,
                body: DeviceConnectionResponse(
                    deviceId: device.deviceId,
                    deviceName: device.deviceName,
                    platform: device.platform,
                    status: "disconnected",
                    host: nil,
                    receivePort: nil,
                    batteryPercent: nil,
                    connectedAt: nil,
                    lastSeenAt: nil,
                    features: nil
                )
            )
        }

        if request.method == "GET", request.path == "/v1/history" {
            try _ = authenticateControl(request, body: Data())
            return jsonResponse(status: 200, body: history.recent(limit: 50))
        }

        if request.method == "POST", request.path == "/v1/actions" {
            let body = try readJSONBody(request, fd: fd, maxBytes: 256 * 1024)
            let deviceId = try authenticateControl(request, body: body)
            let pairingSecret = deviceId.flatMap { trustStore.trustedDevice(id: $0)?.pairingSecret }
            let plaintext = try LinkitWireCrypto.open(pairingSecret: pairingSecret, body: body)
            let action: LinkitActionRequest = try decodeJSON(plaintext)
            return jsonResponse(status: 200, body: try handleAction(action, senderDeviceId: deviceId))
        }

        guard request.path.hasPrefix("/v1/transfers") else {
            throw HTTPFailure.notFound("Endpoint was not found")
        }

        let parts = request.path.split(separator: "/").map(String.init)

        if request.method == "POST", request.path == "/v1/transfers" {
            let body = try readJSONBody(request, fd: fd, maxBytes: 64 * 1024)
            let deviceId = try authenticateControl(request, body: body)
            let createRequest: CreateTransferRequest = try decodeJSON(body)
            return jsonResponse(status: 201, body: try store.create(request: createRequest, authenticatedDeviceId: deviceId))
        }

        guard parts.count >= 3, parts[0] == "v1", parts[1] == "transfers" else {
            throw HTTPFailure.notFound("Transfer endpoint was not found")
        }

        let transferId = parts[2]

        if request.method == "GET", parts.count == 3 {
            let deviceId = try authenticateControl(request, body: Data())
            return jsonResponse(status: 200, body: try store.status(id: transferId, requesterDeviceId: deviceId))
        }

        if request.method == "DELETE", parts.count == 3 {
            let deviceId = try authenticateControl(request, body: Data())
            return jsonResponse(status: 200, body: try store.cancel(id: transferId, requesterDeviceId: deviceId))
        }

        if request.method == "POST", parts.count == 4, parts[3] == "finalize" {
            let body = try readJSONBody(request, fd: fd, maxBytes: 16 * 1024)
            let deviceId = try authenticateControl(request, body: body)
            let finalizeRequest: FinalizeRequest = try decodeJSON(body)
            let (status, response) = try store.finalize(id: transferId, request: finalizeRequest, requesterDeviceId: deviceId)
            return jsonResponse(status: status, body: response)
        }

        if request.method == "PUT", parts.count == 5, parts[3] == "files", let index = Int(parts[4]) {
            return try handleUpload(request: request, transferId: transferId, index: index, fd: fd)
        }

        throw HTTPFailure.notFound("Transfer endpoint was not found")
    }

    private func handleUpload(request: HTTPRequest, transferId: String, index: Int, fd: Int32) throws -> HTTPResponse {
        let uploadToken = request.headers["x-linkit-upload-token"]
        let clientDeviceId = request.headers["x-linkit-client-device-id"]
        let authenticatedDeviceId = try authenticateUpload(
            request,
            transferId: transferId,
            index: index,
            uploadToken: uploadToken
        )
        let record = try store.beginUpload(
            id: transferId,
            index: index,
            contentLength: request.contentLength,
            uploadToken: uploadToken,
            clientDeviceId: authenticatedDeviceId ?? clientDeviceId
        )

        let fileFD = open(record.tempURL.path, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fileFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fileFD) }

        var hasher = SHA256()
        var received: Int64 = 0

        do {
            let pairingSecret = (authenticatedDeviceId ?? clientDeviceId).flatMap { trustStore.trustedDevice(id: $0)?.pairingSecret }
            guard let pskString = pairingSecret, let psk = Data(base64Encoded: pskString) else {
                throw HTTPFailure.unauthorized("not_paired_for_encryption", "No encryption key for this device. Re-pair to enable encryption.")
            }
            let cipher = try LinkitStreamCipher(key: LinkitSecretBox.transferKey(pairingSecret: psk, transferId: transferId, fileIndex: index))

            try consumeUploadChunk(
                cipher.update(request.bodyRemainder),
                maxBytes: record.expectedSize,
                fileFD: fileFD,
                hasher: &hasher,
                received: &received
            )
            postUploadProgress(record: record, received: received)

            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while received < record.expectedSize {
                if store.isCanceled(id: transferId) {
                    throw HTTPFailure.conflict("canceled", "Transfer was canceled")
                }
                let toRead = min(buffer.count, Int(record.expectedSize - received))
                let count = read(fd, &buffer, toRead)
                if count < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 {
                    throw HTTPFailure.badRequest("connection_closed", "Client disconnected before upload completed")
                }
                try consumeUploadChunk(
                    cipher.update(Data(buffer.prefix(count))),
                    maxBytes: record.expectedSize,
                    fileFD: fileFD,
                    hasher: &hasher,
                    received: &received
                )
                postUploadProgress(record: record, received: received)
            }

            let sha256 = hasher.finalize().linkitHex
            let upload = try store.completeUpload(id: transferId, bytesReceived: received, sha256: sha256)
            return jsonResponse(status: 200, body: upload)
        } catch let failure as HTTPFailure {
            if failure.error != "canceled" {
                store.failUpload(id: transferId, error: failure.error, message: failure.message, removeTemp: true)
            }
            throw failure
        } catch {
            store.failUpload(id: transferId, error: "upload_io_failed", message: "\(error)", removeTemp: true)
            throw error
        }
    }

    private func postUploadProgress(record: TransferRecord, received: Int64) {
        NotificationCenter.default.post(
            name: .linkitTransferDidProgress,
            object: nil,
            userInfo: [
                LinkitTransferNotification.transferIdKey: record.id,
                LinkitTransferNotification.filenameKey: record.originalName,
                LinkitTransferNotification.senderDeviceIdKey: record.clientDeviceId,
                LinkitTransferNotification.sizeKey: record.expectedSize,
                LinkitTransferNotification.bytesReceivedKey: received
            ]
        )
    }

    private func handleAction(_ action: LinkitActionRequest, senderDeviceId: String?) throws -> LinkitActionResponse {
        let normalizedType = action.type.lowercased()
        guard ["clipboard", "text", "open_url", "phone_state", "notification", "feature_resolve"].contains(normalizedType) else {
            throw HTTPFailure.badRequest("unsupported_action", "Action type is not supported")
        }
        guard !action.text.isEmpty, action.text.utf8.count <= 128 * 1024 else {
            throw HTTPFailure.badRequest("invalid_action_text", "Action text must be 1 byte to 128 KB")
        }
        // A "fix this on the Mac" nudge from the phone: `text` is a Mac feature id. The menu app
        // resolves it (e.g. re-prompts for notification permission) when it observes the post below.
        if normalizedType == "feature_resolve" {
            guard action.text.utf8.count <= 128 else {
                throw HTTPFailure.badRequest("invalid_action_text", "Feature id is too long")
            }
        }
        if normalizedType == "open_url" {
            guard let url = URL(string: action.text), ["http", "https"].contains(url.scheme?.lowercased()) else {
                throw HTTPFailure.badRequest("invalid_url", "Only http and https URLs can be opened")
            }
        }
        if normalizedType == "phone_state" {
            try validatePhoneStatePayload(action.text)
        }
        if normalizedType == "notification" {
            try validateNotificationPayload(action.text)
        }
        NotificationCenter.default.post(
            name: .linkitActionReceived,
            object: nil,
            userInfo: [
                LinkitActionNotification.typeKey: normalizedType,
                LinkitActionNotification.textKey: action.text,
                LinkitActionNotification.senderDeviceIdKey: senderDeviceId ?? ""
            ]
        )
        logger.info("received action type=\(normalizedType) bytes=\(action.text.utf8.count)")
        return LinkitActionResponse(status: "ok", type: normalizedType)
    }

    private func validatePhoneStatePayload(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String,
              ["idle", "ringing", "active"].contains(state)
        else {
            throw HTTPFailure.badRequest("invalid_phone_state", "Phone state payload is invalid")
        }
        if let number = object["number"] as? String, number.utf8.count > 64 {
            throw HTTPFailure.badRequest("invalid_phone_state", "Phone state number is too long")
        }
        if let name = object["name"] as? String, name.utf8.count > 256 {
            throw HTTPFailure.badRequest("invalid_phone_state", "Phone state name is too long")
        }
    }

    private func validateNotificationPayload(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw HTTPFailure.badRequest("invalid_notification", "Notification payload is invalid")
        }
        let title = (object["title"] as? String) ?? ""
        let body = (object["text"] as? String) ?? ""
        guard !title.isEmpty || !body.isEmpty else {
            throw HTTPFailure.badRequest("invalid_notification", "Notification needs a title or text")
        }
        if let appName = object["appName"] as? String, appName.utf8.count > 256 {
            throw HTTPFailure.badRequest("invalid_notification", "Notification app name is too long")
        }
        if title.utf8.count > 512 {
            throw HTTPFailure.badRequest("invalid_notification", "Notification title is too long")
        }
        if body.utf8.count > 4096 {
            throw HTTPFailure.badRequest("invalid_notification", "Notification text is too long")
        }
    }

    private func identityProof(for request: IdentityProofRequest) throws -> IdentityProofResponse {
        guard !request.challenge.isEmpty, request.challenge.utf8.count <= 256 else {
            throw HTTPFailure.badRequest("invalid_challenge", "Identity proof challenge must be 1 byte to 256 bytes")
        }
        let canonical = LinkitIdentityProof.canonicalString(
            deviceId: identity.deviceId,
            publicKey: identity.publicKey,
            challenge: request.challenge
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let signature = try identity.privateKey.signature(for: digest).derRepresentation.base64EncodedString()
        return IdentityProofResponse(
            protocolVersion: 1,
            deviceId: identity.deviceId,
            deviceName: Host.current().localizedName ?? "Linkit Mac",
            platform: "macos",
            publicKey: identity.publicKey,
            challenge: request.challenge,
            signature: signature
        )
    }

    private func consumeUploadChunk(
        _ data: Data,
        maxBytes: Int64,
        fileFD: Int32,
        hasher: inout SHA256,
        received: inout Int64
    ) throws {
        guard !data.isEmpty else { return }
        guard received + Int64(data.count) <= maxBytes else {
            throw HTTPFailure.badRequest("too_many_bytes", "Upload body exceeded expected size")
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = write(fileFD, base.advanced(by: written), data.count - written)
                if result < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
        hasher.update(data: data)
        received += Int64(data.count)
    }

    private func authenticateControl(_ request: HTTPRequest, body: Data) throws -> String? {
        if request.headers["x-linkit-signature"] != nil {
            return try signedVerifier.verify(request: request, body: body)
        }
        guard allowDevBearerTransfers else {
            throw HTTPFailure.unauthorized("missing_signature", "Pairing and signed control requests are required")
        }
        try requireBearer(request)
        return nil
    }

    private func authenticateUpload(_ request: HTTPRequest, transferId: String, index: Int, uploadToken: String?) throws -> String? {
        if request.headers["x-linkit-signature"] != nil {
            guard let uploadToken else {
                throw HTTPFailure.unauthorized("upload_token_rejected", "Upload token was not accepted")
            }
            let deviceId = try signedVerifier.verifyUpload(
                request: request,
                transferId: transferId,
                fileIndex: index,
                uploadToken: uploadToken,
                contentLength: request.contentLength
            )
            if let clientDeviceId = request.headers["x-linkit-client-device-id"], clientDeviceId != deviceId {
                throw HTTPFailure.unauthorized("client_device_mismatch", "Upload client device id does not match the signature")
            }
            return deviceId
        }
        guard allowDevBearerTransfers else {
            throw HTTPFailure.unauthorized("missing_upload_signature", "Signed upload request is required")
        }
        return nil
    }

    private func requireBearer(_ request: HTTPRequest) throws {
        guard let authorization = request.headers["authorization"] else {
            throw HTTPFailure.unauthorized()
        }
        guard authorization == "Bearer \(token)" else {
            throw HTTPFailure.unauthorized()
        }
    }

    private func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPFailure.badRequest("invalid_json", "Request JSON does not match the protocol schema")
        }
    }

    private func readJSONBody(_ request: HTTPRequest, fd: Int32, maxBytes: Int64) throws -> Data {
        guard request.contentLength <= maxBytes else {
            throw HTTPFailure.badRequest("body_too_large", "Request body is too large")
        }
        return try readBody(request, fd: fd)
    }

    private func readBody(_ request: HTTPRequest, fd: Int32) throws -> Data {
        var body = request.bodyRemainder
        guard Int64(body.count) <= request.contentLength else {
            throw HTTPFailure.badRequest("body_too_large", "Request body exceeded Content-Length")
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        while Int64(body.count) < request.contentLength {
            let toRead = min(buffer.count, Int(request.contentLength - Int64(body.count)))
            let count = read(fd, &buffer, toRead)
            if count < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                throw HTTPFailure.badRequest("connection_closed", "Client disconnected before request body completed")
            }
            body.append(buffer, count: count)
        }
        return body
    }

    private func readRequest(from fd: Int32, remoteHost: String?) throws -> HTTPRequest? {
        let delimiter = Data([13, 10, 13, 10])
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 8192)

        while buffer.range(of: delimiter) == nil {
            let count = read(fd, &temp, temp.count)
            if count < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                return nil
            }
            buffer.append(temp, count: count)
            if buffer.count > 64 * 1024 {
                throw HTTPFailure.badRequest("headers_too_large", "Request headers are too large")
            }
        }

        guard let headerRange = buffer.range(of: delimiter) else {
            throw HTTPFailure.badRequest("bad_request", "Missing HTTP header delimiter")
        }

        let headerData = buffer[..<headerRange.lowerBound]
        let bodyStart = headerRange.upperBound
        let remainder = Data(buffer[bodyStart...])

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPFailure.badRequest("bad_request", "Headers must be UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw HTTPFailure.badRequest("bad_request", "Missing request line")
        }

        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3 else {
            throw HTTPFailure.badRequest("bad_request", "Invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let target = requestLine[1]
        let path = parsePath(target)
        let contentLength = Int64(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0 else {
            throw HTTPFailure.badRequest("invalid_content_length", "Content-Length is invalid")
        }

        return HTTPRequest(
            method: requestLine[0],
            target: target,
            path: path,
            headers: headers,
            contentLength: contentLength,
            bodyRemainder: remainder,
            remoteHost: remoteHost
        )
    }

    private static func ipv4String(from address: sockaddr_in) -> String {
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addr = address.sin_addr
        inet_ntop(AF_INET, &addr, &host, socklen_t(INET_ADDRSTRLEN))
        return String(cString: host)
    }

    private func parsePath(_ target: String) -> String {
        if let components = URLComponents(string: target), let path = components.path.nilIfEmpty {
            return path
        }
        return target.components(separatedBy: "?").first ?? target
    }

    private func jsonResponse<T: Encodable>(status: Int, body: T) -> HTTPResponse {
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            data = Data("{\"error\":\"encoding_failed\",\"message\":\"Could not encode response\"}".utf8)
        }
        return HTTPResponse(
            status: status,
            reason: reasonPhrase(for: status),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    private func connectionResponse(_ connected: ConnectedDevice, status: String) -> DeviceConnectionResponse {
        DeviceConnectionResponse(
            deviceId: connected.deviceId,
            deviceName: connected.deviceName,
            platform: connected.platform,
            status: status,
            host: connected.host,
            receivePort: connected.receivePort,
            batteryPercent: connected.batteryPercent,
            connectedAt: connected.connectedAt,
            lastSeenAt: connected.lastSeenAt,
            features: localFeaturesProvider()
        )
    }

    private func writeResponse(_ response: HTTPResponse, to fd: Int32) throws {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(response.body)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = write(fd, base.advanced(by: written), data.count - written)
                if result < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
