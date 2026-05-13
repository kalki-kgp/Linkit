import Darwin
import Foundation

final class TransferStore {
    private let lock = NSLock()
    private var records: [String: TransferRecord] = [:]
    private let destination: URL
    private let tmpFolder: URL
    private let logger: LinkitLogger
    private let history: TransferHistoryStore?
    private let sessionTTL: TimeInterval = 60 * 60
    private let uploadTokenTTL: TimeInterval = 5 * 60

    init(destination: URL, logger: LinkitLogger, history: TransferHistoryStore? = nil) throws {
        self.destination = destination
        self.tmpFolder = destination.appendingPathComponent(".tmp", isDirectory: true)
        self.logger = logger
        self.history = history
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
    }

    func sweepOrphans(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-sessionTTL)
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: tmpFolder,
            includingPropertiesForKeys: resourceKeys
        ) else {
            return
        }

        for url in urls where url.pathExtension == "part" {
            guard
                let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                values.isRegularFile == true,
                let modified = values.contentModificationDate,
                modified < cutoff
            else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: url)
                logger.info("swept orphan temp file path=\(url.path)")
            } catch {
                logger.error("failed to sweep orphan path=\(url.path) error=\(error)")
            }
        }
    }

    func create(request: CreateTransferRequest, authenticatedDeviceId: String? = nil) throws -> CreateTransferResponse {
        guard request.files.count == 1, let file = request.files.first else {
            throw HTTPFailure.badRequest("phase0_single_file_only", "Phase 0 accepts exactly one file per transfer")
        }
        guard file.size >= 0 else {
            throw HTTPFailure.badRequest("invalid_size", "File size must be non-negative")
        }

        let now = Date()
        let id = "tr_" + (try LinkitRandom.token(byteCount: 18))
        let uploadToken = try LinkitRandom.token(byteCount: 32)
        let expiresAt = now.addingTimeInterval(sessionTTL)
        let uploadTokenExpiresAt = minDate(now.addingTimeInterval(uploadTokenTTL), expiresAt)
        let safeName = FilenameSanitizer.sanitize(file.name)
        let tempURL = tmpFolder.appendingPathComponent("\(id)-0.part")

        let clientDeviceId = authenticatedDeviceId ?? normalizedClientDeviceId(request.clientDeviceId)
        if let requestDeviceId = request.clientDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestDeviceId.isEmpty,
           requestDeviceId != clientDeviceId {
            throw HTTPFailure.unauthorized("client_device_mismatch", "Signed device does not match transfer clientDeviceId")
        }

        let record = TransferRecord(
            id: id,
            fileIndex: 0,
            originalName: file.name,
            safeName: safeName,
            expectedSize: file.size,
            mimeType: file.mimeType,
            clientSha256: normalizedHash(file.clientSha256),
            clientDeviceId: clientDeviceId,
            tempURL: tempURL,
            expiresAt: expiresAt,
            uploadToken: uploadToken,
            uploadTokenExpiresAt: uploadTokenExpiresAt,
            uploadTokenConsumed: false,
            status: .created,
            bytesReceived: 0,
            serverSha256: nil,
            savedURL: nil,
            error: nil,
            finalizeRequest: nil,
            finalizeStatusCode: nil,
            finalizeResponse: nil
        )

        lock.lock()
        records[id] = record
        lock.unlock()

        logger.info("created transfer id=\(id) name=\(safeName) size=\(file.size)")

        return CreateTransferResponse(
            transferId: id,
            status: record.status.rawValue,
            clientDeviceId: record.clientDeviceId,
            files: [
                CreatedTransferFile(
                    index: record.fileIndex,
                    name: record.originalName,
                    safeName: record.safeName,
                    size: record.expectedSize,
                    mimeType: record.mimeType,
                    status: record.status.rawValue,
                    uploadUrl: "/v1/transfers/\(id)/files/0",
                    uploadToken: uploadToken,
                    uploadTokenExpiresAt: uploadTokenExpiresAt.iso8601()
                )
            ],
            uploadUrl: "/v1/transfers/\(id)/files/0",
            finalizeUrl: "/v1/transfers/\(id)/finalize",
            statusUrl: "/v1/transfers/\(id)",
            uploadToken: uploadToken,
            uploadTokenExpiresAt: uploadTokenExpiresAt.iso8601(),
            expiresAt: expiresAt.iso8601()
        )
    }

    func beginUpload(
        id: String,
        index: Int,
        contentLength: Int64,
        uploadToken: String?,
        clientDeviceId: String?
    ) throws -> TransferRecord {
        try mutate(id: id) { record in
            try validateLive(record)
            guard index == record.fileIndex else {
                throw HTTPFailure.notFound("File index was not found")
            }
            guard contentLength == record.expectedSize else {
                record.status = .failed
                record.error = "content_length_mismatch"
                throw HTTPFailure.badRequest("content_length_mismatch", "Content-Length must match the transfer size")
            }
            guard let uploadToken, uploadToken == record.uploadToken else {
                throw HTTPFailure.unauthorized("upload_token_rejected", "Upload token was not accepted")
            }
            guard normalizedClientDeviceId(clientDeviceId) == record.clientDeviceId else {
                throw HTTPFailure.unauthorized("client_device_mismatch", "Upload token is not valid for this client device")
            }
            guard Date() <= record.uploadTokenExpiresAt else {
                record.status = .failed
                record.error = "upload_token_expired"
                throw HTTPFailure.unauthorized("upload_token_expired", "Upload token expired")
            }
            guard !record.uploadTokenConsumed else {
                throw HTTPFailure.conflict("upload_token_used", "Upload token was already used")
            }
            guard record.status == .created else {
                throw HTTPFailure.conflict("invalid_state", "Transfer is not ready for upload")
            }
            record.uploadTokenConsumed = true
            record.status = .uploading
            record.bytesReceived = 0
            record.serverSha256 = nil
            record.error = nil
            return record
        }
    }

    func isCanceled(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records[id]?.status == .canceled
    }

    func completeUpload(id: String, bytesReceived: Int64, sha256: String) throws -> UploadResponse {
        try mutate(id: id) { record in
            try validateLive(record)
            guard record.status == .uploading else {
                throw HTTPFailure.conflict("invalid_state", "Transfer is not uploading")
            }
            guard bytesReceived == record.expectedSize else {
                record.status = .failed
                record.bytesReceived = bytesReceived
                record.serverSha256 = sha256
                record.error = "size_mismatch"
                removeTempQuietly(record.tempURL)
                throw HTTPFailure.badRequest("size_mismatch", "Received byte count did not match expected size")
            }
            record.status = .uploaded
            record.bytesReceived = bytesReceived
            record.serverSha256 = sha256
            logger.info("uploaded transfer id=\(id) bytes=\(bytesReceived) sha256=\(sha256)")
            return UploadResponse(
                transferId: record.id,
                fileIndex: record.fileIndex,
                status: record.status.rawValue,
                bytesReceived: record.bytesReceived,
                serverSha256: sha256
            )
        }
    }

    func failUpload(id: String, error code: String, message: String, removeTemp: Bool) {
        lock.lock()
        if var record = records[id] {
            record.status = .failed
            record.error = code
            records[id] = record
            if removeTemp {
                removeTempQuietly(record.tempURL)
            }
            appendHistory(record)
            logger.error("upload failed transfer id=\(id) error=\(code) message=\(message)")
        }
        lock.unlock()
    }

    func cancel(id: String, requesterDeviceId: String? = nil) throws -> TransferStatusResponse {
        try mutate(id: id) { record in
            try validateRequester(record, requesterDeviceId)
            record.status = .canceled
            record.error = "canceled"
            removeTempQuietly(record.tempURL)
            appendHistory(record)
            logger.info("canceled transfer id=\(id)")
            return statusResponse(record)
        }
    }

    func status(id: String, requesterDeviceId: String? = nil) throws -> TransferStatusResponse {
        try read(id: id) { record in
            try validateRequester(record, requesterDeviceId)
            return statusResponse(record)
        }
    }

    func finalize(id: String, request: FinalizeRequest, requesterDeviceId: String? = nil) throws -> (Int, FinalizeResponse) {
        try mutate(id: id) { record in
            try validateRequester(record, requesterDeviceId)
            if let existingRequest = record.finalizeRequest,
               let statusCode = record.finalizeStatusCode,
               let response = record.finalizeResponse {
                guard existingRequest == normalizedFinalize(request) else {
                    throw HTTPFailure.conflict("finalize_payload_mismatch", "Finalize was already recorded with a different payload")
                }
                return (statusCode, response)
            }

            let normalized = normalizedFinalize(request)
            record.finalizeRequest = normalized

            func finalizeFailure(_ code: String, _ message: String) -> (Int, FinalizeResponse) {
                record.status = .failed
                record.error = code
                removeTempQuietly(record.tempURL)
                let response = FinalizeResponse(
                    transferId: record.id,
                    status: record.status.rawValue,
                    files: [finalizedFile(record)],
                    savedPath: nil,
                    bytesReceived: record.bytesReceived,
                    sha256: record.serverSha256,
                    error: code,
                    message: message
                )
                record.finalizeStatusCode = 400
                record.finalizeResponse = response
                appendHistory(record)
                self.logger.error("finalize failed transfer id=\(id) error=\(code) message=\(message)")
                return (400, response)
            }

            do {
                try validateLive(record)
            } catch let httpFailure as HTTPFailure {
                return finalizeFailure(httpFailure.error, httpFailure.message)
            }

            guard record.status == .uploaded else {
                return finalizeFailure("not_uploaded", "Upload must complete before finalize")
            }
            guard request.bytesSent == record.expectedSize else {
                return finalizeFailure("bytes_sent_mismatch", "Finalize byte count does not match expected size")
            }
            guard let serverSha256 = record.serverSha256 else {
                return finalizeFailure("missing_server_hash", "Server hash was not recorded")
            }
            guard normalized.finalSha256 == serverSha256 else {
                return finalizeFailure("sha256_mismatch", "Finalize hash does not match streamed server hash")
            }
            if let clientSha256 = record.clientSha256, clientSha256 != serverSha256 {
                return finalizeFailure("client_sha256_mismatch", "Create-transfer hash does not match streamed server hash")
            }

            do {
                let finalURL = try publishTempFile(record.tempURL, safeName: record.safeName)
                record.status = .complete
                record.savedURL = finalURL
                record.error = nil
                let response = FinalizeResponse(
                    transferId: record.id,
                    status: record.status.rawValue,
                    files: [finalizedFile(record)],
                    savedPath: finalURL.path,
                    bytesReceived: record.bytesReceived,
                    sha256: serverSha256,
                    error: nil,
                    message: nil
                )
                record.finalizeStatusCode = 200
                record.finalizeResponse = response
                appendHistory(record)
                logger.info("finalized transfer id=\(id) path=\(finalURL.path)")
                return (200, response)
            } catch {
                return finalizeFailure("final_save_failed", "Could not atomically save file: \(error)")
            }
        }
    }

    private func read<T>(id: String, _ body: (TransferRecord) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[id] else {
            throw HTTPFailure.notFound()
        }
        return try body(record)
    }

    private func mutate<T>(id: String, _ body: (inout TransferRecord) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[id] else {
            throw HTTPFailure.notFound()
        }
        let result = try body(&record)
        records[id] = record
        return result
    }

    private func validateLive(_ record: TransferRecord) throws {
        guard record.status != .canceled else {
            throw HTTPFailure.conflict("canceled", "Transfer was canceled")
        }
        guard Date() <= record.expiresAt else {
            throw HTTPFailure.unauthorized("session_expired", "Transfer session expired")
        }
    }

    private func validateRequester(_ record: TransferRecord, _ requesterDeviceId: String?) throws {
        guard let requesterDeviceId else { return }
        guard requesterDeviceId == record.clientDeviceId else {
            throw HTTPFailure.unauthorized("client_device_mismatch", "Signed device does not own this transfer")
        }
    }

    private func statusResponse(_ record: TransferRecord) -> TransferStatusResponse {
        TransferStatusResponse(
            transferId: record.id,
            status: record.status.rawValue,
            clientDeviceId: record.clientDeviceId,
            expiresAt: record.expiresAt.iso8601(),
            files: [
                TransferFileStatus(
                    index: record.fileIndex,
                    name: record.originalName,
                    safeName: record.safeName,
                    size: record.expectedSize,
                    mimeType: record.mimeType,
                    status: record.status.rawValue,
                    bytesReceived: record.bytesReceived,
                    serverSha256: record.serverSha256,
                    savedPath: record.savedURL?.path,
                    error: record.error
                )
            ],
            bytesReceived: record.bytesReceived,
            expectedSize: record.expectedSize,
            serverSha256: record.serverSha256,
            savedPath: record.savedURL?.path,
            error: record.error
        )
    }

    private func finalizedFile(_ record: TransferRecord) -> FinalizedTransferFile {
        FinalizedTransferFile(
            index: record.fileIndex,
            name: record.originalName,
            size: record.expectedSize,
            status: record.status.rawValue,
            savedPath: record.savedURL?.path,
            bytesReceived: record.bytesReceived,
            sha256: record.serverSha256,
            error: record.error
        )
    }

    private func publishTempFile(_ tempURL: URL, safeName: String) throws -> URL {
        for attempt in 0..<10_000 {
            let candidateName = CollisionName.candidate(for: safeName, attempt: attempt)
            let candidate = destination.appendingPathComponent(candidateName)
            let result = tempURL.path.withCString { oldPath in
                candidate.path.withCString { newPath in
                    renameatx_np(AT_FDCWD, oldPath, AT_FDCWD, newPath, UInt32(RENAME_EXCL))
                }
            }

            if result == 0 {
                return candidate
            }
            if errno == EEXIST {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        throw HTTPFailure.conflict("too_many_collisions", "Could not allocate a destination filename")
    }

    private func removeTempQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func appendHistory(_ record: TransferRecord) {
        history?.append(
            TransferHistoryEntry(
                transferId: record.id,
                filename: record.originalName,
                size: record.expectedSize,
                senderDeviceId: record.clientDeviceId,
                completedAt: Date().iso8601(),
                status: record.status.rawValue,
                savedPath: record.savedURL?.path,
                sha256: record.serverSha256,
                error: record.error
            )
        )
    }
}

private func normalizedHash(_ value: String?) -> String? {
    guard let value else { return nil }
    let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowered.isEmpty ? nil : lowered
}

private func normalizedClientDeviceId(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "android-phase0" : trimmed
}

private func normalizedFinalize(_ request: FinalizeRequest) -> FinalizeRequest {
    FinalizeRequest(
        bytesSent: request.bytesSent,
        finalSha256: request.finalSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
}

private func minDate(_ lhs: Date, _ rhs: Date) -> Date {
    lhs <= rhs ? lhs : rhs
}
