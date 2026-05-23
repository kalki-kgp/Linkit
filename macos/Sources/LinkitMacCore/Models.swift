import Foundation

public struct ReceiverConfiguration {
    public let port: UInt16
    public let destination: URL
    public let advertiseBonjour: Bool
    public let allowDevBearerTransfers: Bool

    public init(
        port: UInt16 = 52718,
        destination: URL? = nil,
        advertiseBonjour: Bool = true,
        allowDevBearerTransfers: Bool = false
    ) {
        self.port = port
        self.advertiseBonjour = advertiseBonjour
        self.allowDevBearerTransfers = allowDevBearerTransfers
        self.destination = destination ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Linkit Drop", isDirectory: true)
    }
}

public struct ErrorResponse: Codable {
    public let error: String
    public let message: String
}

public struct InfoResponse: Codable {
    public let protocolVersion: Int
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let port: UInt16
    public let publicKey: String
    public let serviceType: String
    public let capabilities: [String]
}

public struct PairRequest: Codable {
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let publicKey: String
    public let pairingToken: String
    public let pairingChallenge: String?
    public let pairingChallengeSignature: String?
    public let receivePort: UInt16?
    public let batteryPercent: Int?
}

public struct PairResponse: Codable {
    public let protocolVersion: Int
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let publicKey: String
    public let trustedDeviceId: String
    public let status: String
}

public struct PairingPayload: Codable {
    public let v: Int
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let ip: String
    public let port: UInt16
    public let publicKey: String
    public let pairingToken: String
    public let pairingChallenge: String
    public let pairingTokenExpiresAt: String
}

public struct CreateTransferRequest: Codable {
    public let clientDeviceId: String?
    public let files: [TransferFileRequest]
}

public struct TransferFileRequest: Codable {
    public let name: String
    public let size: Int64
    public let mimeType: String?
    public let clientSha256: String?
}

public struct CreateTransferResponse: Codable {
    public let transferId: String
    public let status: String
    public let clientDeviceId: String
    public let files: [CreatedTransferFile]
    public let uploadUrl: String
    public let finalizeUrl: String
    public let statusUrl: String
    public let uploadToken: String
    public let uploadTokenExpiresAt: String
    public let expiresAt: String
}

public struct CreatedTransferFile: Codable, Equatable {
    public let index: Int
    public let name: String
    public let safeName: String
    public let size: Int64
    public let mimeType: String?
    public let status: String
    public let uploadUrl: String
    public let uploadToken: String
    public let uploadTokenExpiresAt: String
}

public struct UploadResponse: Codable {
    public let transferId: String
    public let fileIndex: Int
    public let status: String
    public let bytesReceived: Int64
    public let serverSha256: String
}

public struct FinalizeRequest: Codable, Equatable {
    public let bytesSent: Int64
    public let finalSha256: String
}

public struct FinalizeResponse: Codable, Equatable {
    public let transferId: String
    public let status: String
    public let files: [FinalizedTransferFile]
    public let savedPath: String?
    public let bytesReceived: Int64
    public let sha256: String?
    public let error: String?
    public let message: String?
}

public struct FinalizedTransferFile: Codable, Equatable {
    public let index: Int
    public let name: String
    public let size: Int64
    public let status: String
    public let savedPath: String?
    public let bytesReceived: Int64
    public let sha256: String?
    public let error: String?
}

public struct TransferStatusResponse: Codable {
    public let transferId: String
    public let status: String
    public let clientDeviceId: String
    public let expiresAt: String
    public let files: [TransferFileStatus]
    public let bytesReceived: Int64
    public let expectedSize: Int64
    public let serverSha256: String?
    public let savedPath: String?
    public let error: String?
}

public struct TransferFileStatus: Codable {
    public let index: Int
    public let name: String
    public let safeName: String
    public let size: Int64
    public let mimeType: String?
    public let status: String
    public let bytesReceived: Int64
    public let serverSha256: String?
    public let savedPath: String?
    public let error: String?
}

public struct TransferHistoryEntry: Codable, Equatable {
    public let transferId: String
    public let filename: String
    public let size: Int64
    public let senderDeviceId: String
    public let completedAt: String
    public let status: String
    public let savedPath: String?
    public let sha256: String?
    public let error: String?
}

public struct DeviceUpdateRequest: Codable {
    public let receivePort: UInt16
    public let batteryPercent: Int?
}

public struct DeviceConnectionResponse: Codable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let status: String
    public let host: String?
    public let receivePort: UInt16?
    public let batteryPercent: Int?
    public let connectedAt: String?
    public let lastSeenAt: String?
}

public struct AndroidDeviceStatusResponse: Codable, Equatable {
    public let protocolVersion: Int
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let status: String
    public let receivePort: UInt16?
    public let batteryPercent: Int?
}

public struct LinkitActionRequest: Codable, Equatable {
    public let type: String
    public let text: String

    public init(type: String, text: String) {
        self.type = type
        self.text = text
    }
}

public struct LinkitActionResponse: Codable, Equatable {
    public let status: String
    public let type: String
}

struct TransferRecord {
    let id: String
    let fileIndex: Int
    let originalName: String
    let safeName: String
    let expectedSize: Int64
    let mimeType: String?
    let clientSha256: String?
    let clientDeviceId: String
    let tempURL: URL
    let expiresAt: Date
    let uploadToken: String
    let uploadTokenExpiresAt: Date
    var uploadTokenConsumed: Bool
    var status: TransferStatus
    var bytesReceived: Int64
    var serverSha256: String?
    var savedURL: URL?
    var error: String?
    var finalizeRequest: FinalizeRequest?
    var finalizeStatusCode: Int?
    var finalizeResponse: FinalizeResponse?
}

enum TransferStatus: String {
    case created
    case uploading
    case uploaded
    case complete
    case failed
    case canceled
}

public struct HTTPFailure: Error {
    public let status: Int
    public let error: String
    public let message: String
}

extension HTTPFailure: LocalizedError {
    public var errorDescription: String? { message }
}

extension HTTPFailure {
    static func badRequest(_ error: String, _ message: String) -> HTTPFailure {
        HTTPFailure(status: 400, error: error, message: message)
    }

    static func unauthorized(_ error: String = "token_rejected", _ message: String = "Authorization bearer token was not accepted") -> HTTPFailure {
        HTTPFailure(status: 401, error: error, message: message)
    }

    static func notFound(_ message: String = "Transfer was not found") -> HTTPFailure {
        HTTPFailure(status: 404, error: "not_found", message: message)
    }

    static func conflict(_ error: String, _ message: String) -> HTTPFailure {
        HTTPFailure(status: 409, error: error, message: message)
    }
}
