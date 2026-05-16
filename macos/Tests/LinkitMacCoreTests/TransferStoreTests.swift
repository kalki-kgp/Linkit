import CryptoKit
import XCTest
@testable import LinkitMacCore

final class TransferStoreTests: XCTestCase {
    func testUploadTokenIsBoundToClientDeviceAndContentLength() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let create = try fixture.store.create(request: createRequest(name: "token.txt", size: 5, clientDeviceId: "phone-a"))

        XCTAssertThrowsError(
            try fixture.store.beginUpload(
                id: create.transferId,
                index: 0,
                contentLength: 5,
                uploadToken: create.uploadToken,
                clientDeviceId: "phone-b"
            )
        ) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "client_device_mismatch")
        }

        XCTAssertThrowsError(
            try fixture.store.beginUpload(
                id: create.transferId,
                index: 0,
                contentLength: 4,
                uploadToken: create.uploadToken,
                clientDeviceId: "phone-a"
            )
        ) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "content_length_mismatch")
        }
    }

    func testFinalizeReplayReturnsSameSavedResult() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let data = Data("phase one\n".utf8)
        let sha = SHA256.hash(data: data).linkitHex
        let create = try fixture.uploadReadyTransfer(name: "finalize.txt", data: data, clientDeviceId: "phone-a")
        let finalize = FinalizeRequest(bytesSent: Int64(data.count), finalSha256: sha)

        let first = try fixture.store.finalize(id: create.transferId, request: finalize)
        let second = try fixture.store.finalize(id: create.transferId, request: finalize)

        XCTAssertEqual(first.0, 200)
        XCTAssertEqual(second.0, 200)
        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.1.savedPath!)), data)
    }

    func testSuccessfulFinalizeAddsHistoryEntry() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let data = Data("history\n".utf8)
        let sha = SHA256.hash(data: data).linkitHex
        let create = try fixture.uploadReadyTransfer(name: "history.txt", data: data, clientDeviceId: "phone-a")

        _ = try fixture.store.finalize(
            id: create.transferId,
            request: FinalizeRequest(bytesSent: Int64(data.count), finalSha256: sha)
        )

        let recent = fixture.history.recent(limit: 1)
        XCTAssertEqual(recent.first?.transferId, create.transferId)
        XCTAssertEqual(recent.first?.filename, "history.txt")
        XCTAssertEqual(recent.first?.status, "complete")
        XCTAssertEqual(recent.first?.sha256, sha)
    }

    func testTransferNotificationsReportBeginAndFinish() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let beginExpectation = expectation(description: "begin upload notification")
        let finishExpectation = expectation(description: "finish notification")
        var beginFilename: String?
        var finishStatus: String?

        let beginObserver = NotificationCenter.default.addObserver(
            forName: .linkitTransferDidBeginUpload,
            object: nil,
            queue: nil
        ) { notification in
            beginFilename = notification.userInfo?[LinkitTransferNotification.filenameKey] as? String
            beginExpectation.fulfill()
        }
        let finishObserver = NotificationCenter.default.addObserver(
            forName: .linkitTransferDidFinish,
            object: nil,
            queue: nil
        ) { notification in
            finishStatus = notification.userInfo?[LinkitTransferNotification.statusKey] as? String
            finishExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(beginObserver)
            NotificationCenter.default.removeObserver(finishObserver)
        }

        let data = Data("notify\n".utf8)
        let sha = SHA256.hash(data: data).linkitHex
        let create = try fixture.store.create(request: createRequest(name: "notify.txt", size: data.count, clientDeviceId: "phone-a"))
        let record = try fixture.store.beginUpload(
            id: create.transferId,
            index: 0,
            contentLength: Int64(data.count),
            uploadToken: create.uploadToken,
            clientDeviceId: "phone-a"
        )
        try data.write(to: record.tempURL)
        _ = try fixture.store.completeUpload(id: create.transferId, bytesReceived: Int64(data.count), sha256: sha)
        _ = try fixture.store.finalize(
            id: create.transferId,
            request: FinalizeRequest(bytesSent: Int64(data.count), finalSha256: sha)
        )

        wait(for: [beginExpectation, finishExpectation], timeout: 2)
        XCTAssertEqual(beginFilename, "notify.txt")
        XCTAssertEqual(finishStatus, "complete")
    }

    func testFailedFinalizeReplayReturnsSameFailure() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let data = Data("wrong hash\n".utf8)
        let create = try fixture.uploadReadyTransfer(name: "bad.txt", data: data, clientDeviceId: "phone-a")
        let badFinalize = FinalizeRequest(bytesSent: Int64(data.count), finalSha256: String(repeating: "0", count: 64))

        let first = try fixture.store.finalize(id: create.transferId, request: badFinalize)
        let second = try fixture.store.finalize(id: create.transferId, request: badFinalize)

        XCTAssertEqual(first.0, 400)
        XCTAssertEqual(second.0, 400)
        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(first.1.error, "sha256_mismatch")
    }

    func testConcurrentFinalizeAllocatesCollisionNames() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let data = Data("same name\n".utf8)
        let sha = SHA256.hash(data: data).linkitHex
        let first = try fixture.uploadReadyTransfer(name: "note.txt", data: data, clientDeviceId: "phone-a")
        let second = try fixture.uploadReadyTransfer(name: "note.txt", data: data, clientDeviceId: "phone-a")
        let finalize = FinalizeRequest(bytesSent: Int64(data.count), finalSha256: sha)

        let expectation = expectation(description: "both finalize calls finish")
        expectation.expectedFulfillmentCount = 2

        let lock = NSLock()
        var results: [Result<FinalizeResponse, Error>] = []
        for transferId in [first.transferId, second.transferId] {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try fixture.store.finalize(id: transferId, request: finalize).1 }
                lock.lock()
                results.append(result)
                lock.unlock()
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5)

        let paths = try results.map { try $0.get().savedPath! }
        let names = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(names, ["note.txt", "note (1).txt"])
    }

    private func createRequest(name: String, size: Int, clientDeviceId: String) -> CreateTransferRequest {
        CreateTransferRequest(
            clientDeviceId: clientDeviceId,
            files: [
                TransferFileRequest(
                    name: name,
                    size: Int64(size),
                    mimeType: "text/plain",
                    clientSha256: nil
                )
            ]
        )
    }
}

private final class StoreFixture {
    let destination: URL
    let history: TransferHistoryStore
    let store: TransferStore

    init() throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-store-tests-\(UUID().uuidString)", isDirectory: true)
        history = try TransferHistoryStore(baseFolder: destination.appendingPathComponent("support", isDirectory: true))
        store = try TransferStore(destination: destination, logger: LinkitLogger(), history: history)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: destination)
    }

    func uploadReadyTransfer(name: String, data: Data, clientDeviceId: String) throws -> CreateTransferResponse {
        let create = try store.create(
            request: CreateTransferRequest(
                clientDeviceId: clientDeviceId,
                files: [
                    TransferFileRequest(
                        name: name,
                        size: Int64(data.count),
                        mimeType: "text/plain",
                        clientSha256: nil
                    )
                ]
            )
        )
        let record = try store.beginUpload(
            id: create.transferId,
            index: 0,
            contentLength: Int64(data.count),
            uploadToken: create.uploadToken,
            clientDeviceId: clientDeviceId
        )
        try data.write(to: record.tempURL)
        _ = try store.completeUpload(
            id: create.transferId,
            bytesReceived: Int64(data.count),
            sha256: SHA256.hash(data: data).linkitHex
        )
        return create
    }
}
