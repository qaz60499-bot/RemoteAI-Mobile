import CryptoKit
import XCTest
@testable import RemoteAIMobile

private func attachmentTestSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private actor AttachmentIntegrityFixture: Transport {
    enum DownloadDigestMode: Sendable {
        case actual
        case omitted
        case constant(String)
        case inconsistentAfterFirst(String)
    }

    private struct Upload {
        let name: String
        let contentType: String
        let sizeBytes: Int
        var data: Data
        var nextIndex: Int
    }

    private var connected = true
    private var uploadCounter = 0
    private var attachmentCounter = 0
    private var uploads: [String: Upload] = [:]
    private var completedUploadPayloads: [Data] = []
    private var processedCommands: [UUID: CommandResponseEnvelope] = [:]
    private var commandHistory: [RemoteCommand] = []
    private let downloadData: Data
    private let downloadDigestMode: DownloadDigestMode
    private let uploadDigestOverride: String?

    init(
        downloadData: Data = Data("attachment fixture".utf8),
        downloadDigestMode: DownloadDigestMode = .actual,
        uploadDigestOverride: String? = nil
    ) {
        self.downloadData = downloadData
        self.downloadDigestMode = downloadDigestMode
        self.uploadDigestOverride = uploadDigestOverride
    }

    var isConnected: Bool { connected }
    func connect() async throws { connected = true }
    func disconnect() async { connected = false }
    func eventStream() async -> AsyncStream<RemoteEvent> { AsyncStream { $0.finish() } }
    func healthStream() async -> AsyncStream<TransportHealthEvent> { AsyncStream { $0.finish() } }

    func commandIds() -> [UUID] { commandHistory.map(\.commandId) }
    func uploadedPayloads() -> [Data] { completedUploadPayloads }

    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        commandHistory.append(command)
        if let previous = processedCommands[command.commandId] {
            return CommandResponseEnvelope(ok: previous.ok, result: previous.result, error: previous.error, idempotentReplay: true)
        }

        let response: CommandResponseEnvelope
        switch command.action {
        case "beginAttachmentUpload":
            uploadCounter += 1
            let uploadId = "upload-\(uploadCounter)"
            uploads[uploadId] = Upload(
                name: command.payload["name"]?.stringValue ?? "attachment.bin",
                contentType: command.payload["contentType"]?.stringValue ?? "application/octet-stream",
                sizeBytes: Int(command.payload["sizeBytes"]?.intValue ?? 0),
                data: Data(),
                nextIndex: 0
            )
            response = try success(AttachmentUploadTicket(uploadId: uploadId, chunkBytes: 16 * 1024, maxAttachmentBytes: 128 * 1024 * 1024))

        case "uploadAttachmentChunk":
            let uploadId = command.payload["uploadId"]?.stringValue ?? ""
            let index = Int(command.payload["index"]?.intValue ?? -1)
            guard var upload = uploads[uploadId], index == upload.nextIndex,
                  let encoded = command.payload["dataBase64"]?.stringValue,
                  let bytes = Data(base64Encoded: encoded) else {
                return failure("INVALID_COMMAND", "Invalid fixture upload chunk")
            }
            upload.data.append(bytes)
            upload.nextIndex += 1
            uploads[uploadId] = upload
            response = successObject(["nextIndex": .number(Double(upload.nextIndex)), "receivedBytes": .number(Double(upload.data.count))])

        case "finishAttachmentUpload":
            let uploadId = command.payload["uploadId"]?.stringValue ?? ""
            guard let upload = uploads.removeValue(forKey: uploadId), upload.data.count == upload.sizeBytes else {
                return failure("INVALID_COMMAND", "Incomplete fixture upload")
            }
            attachmentCounter += 1
            let attachmentId = "attachment-fixture-\(attachmentCounter)"
            let digest = uploadDigestOverride ?? attachmentTestSHA256(upload.data)
            let descriptor = RemoteAttachmentDescriptor(
                attachmentId: attachmentId,
                name: upload.name,
                contentType: upload.contentType,
                sizeBytes: upload.sizeBytes,
                sha256: digest
            )
            completedUploadPayloads.append(upload.data)
            response = try success(descriptor)

        case "discardAttachmentUpload":
            if let uploadId = command.payload["uploadId"]?.stringValue { uploads.removeValue(forKey: uploadId) }
            response = successObject(["discarded": .bool(true)])

        case "readMessageAttachmentChunk":
            let index = Int(command.payload["index"]?.intValue ?? -1)
            let chunkBytes = 16 * 1024
            let offset = index * chunkBytes
            guard index >= 0, offset < downloadData.count else { return failure("INVALID_COMMAND", "Invalid fixture download chunk") }
            let end = min(downloadData.count, offset + chunkBytes)
            let data = downloadData.subdata(in: offset..<end)
            let sha256: String?
            switch downloadDigestMode {
            case .actual:
                sha256 = attachmentTestSHA256(downloadData)
            case .omitted:
                sha256 = nil
            case .constant(let value):
                sha256 = value
            case .inconsistentAfterFirst(let value):
                sha256 = index == 0 ? attachmentTestSHA256(downloadData) : value
            }
            let chunk = MessageAttachmentChunk(
                attachmentId: command.payload["attachmentId"]?.stringValue ?? "webasset-feedface-10",
                name: command.payload["attachmentName"]?.stringValue ?? "fixture.bin",
                contentType: "application/octet-stream",
                sizeBytes: downloadData.count,
                sha256: sha256,
                index: index,
                chunkBytes: chunkBytes,
                dataBase64: data.base64EncodedString(),
                hasMore: end < downloadData.count
            )
            response = try success(chunk)

        default:
            return failure("INVALID_COMMAND", "Unsupported fixture command: \(command.action)")
        }
        processedCommands[command.commandId] = response
        return response
    }

    private func success<T: Encodable>(_ value: T) throws -> CommandResponseEnvelope {
        CommandResponseEnvelope(ok: true, result: try JSONValue.encode(value), error: nil, idempotentReplay: nil)
    }

    private func successObject(_ value: [String: JSONValue]) -> CommandResponseEnvelope {
        CommandResponseEnvelope(ok: true, result: .object(value), error: nil, idempotentReplay: nil)
    }

    private func failure(_ code: String, _ message: String) -> CommandResponseEnvelope {
        CommandResponseEnvelope(ok: false, result: nil,
                                error: RemoteErrorPayload(code: code, message: message, retryable: false, details: nil),
                                idempotentReplay: nil)
    }
}

final class AttachmentIntegrityTests: XCTestCase {
    func testUploadReplayIDsBindToPayloadAndRemainStableForExactRetry() async throws {
        let fixture = AttachmentIntegrityFixture()
        let operationId = UUID()
        let firstData = Data("original file bytes".utf8)
        let changedData = Data("replacement file bytes".utf8)
        let first = PendingAttachment(name: "report.txt", contentType: "text/plain", data: firstData)
        let changed = PendingAttachment(name: "report.txt", contentType: "text/plain", data: changedData)

        let firstDescriptor = try await fixture.uploadAttachment(
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
            attachment: first, operationId: operationId, attachmentIndex: 0
        )
        let afterFirst = await fixture.commandIds()
        let changedDescriptor = try await fixture.uploadAttachment(
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
            attachment: changed, operationId: operationId, attachmentIndex: 0
        )
        let afterChanged = await fixture.commandIds()
        let changedCommandIds = Array(afterChanged.dropFirst(afterFirst.count))
        let exactRetryDescriptor = try await fixture.uploadAttachment(
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
            attachment: changed, operationId: operationId, attachmentIndex: 0
        )
        let afterExactRetry = await fixture.commandIds()
        let retryCommandIds = Array(afterExactRetry.dropFirst(afterChanged.count))

        XCTAssertNotEqual(afterFirst, changedCommandIds, "Same index and operation ID must not alias different bytes")
        XCTAssertEqual(changedCommandIds, retryCommandIds, "An exact same-payload retry must keep deterministic command IDs")
        XCTAssertEqual(firstDescriptor.sha256, attachmentTestSHA256(firstData))
        XCTAssertEqual(changedDescriptor.sha256, attachmentTestSHA256(changedData))
        XCTAssertEqual(exactRetryDescriptor, changedDescriptor, "The exact retry should replay its committed descriptor")
        let uploadedPayloads = await fixture.uploadedPayloads()
        XCTAssertEqual(uploadedPayloads, [firstData, changedData])
    }

    func testUploadRejectsFinishedDescriptorWithDifferentLocalDigest() async throws {
        let fixture = AttachmentIntegrityFixture(uploadDigestOverride: String(repeating: "f", count: 64))
        let attachment = PendingAttachment(name: "payload.bin", contentType: "application/octet-stream", data: Data("expected bytes".utf8))
        do {
            _ = try await fixture.uploadAttachment(
                machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
                attachment: attachment, operationId: UUID(), attachmentIndex: 0
            )
            XCTFail("A mismatched finished-upload digest must be rejected")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedData)
        }
    }

    func testDownloadsVerifyWholeAttachmentDigestAndAllowLegacyMissingDigest() async throws {
        let source = Data((0..<40_000).map { UInt8($0 % 251) })
        let fixture = AttachmentIntegrityFixture(downloadData: source)
        let downloaded = try await fixture.downloadMessageAttachment(
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
            attachmentId: "webasset-feedface-10"
        )
        XCTAssertEqual(downloaded.data, source)

        let legacyFixture = AttachmentIntegrityFixture(downloadData: source, downloadDigestMode: .omitted)
        let legacyDownloaded = try await legacyFixture.downloadMessageAttachment(
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
            attachmentId: "webasset-feedface-10"
        )
        XCTAssertEqual(legacyDownloaded.data, source, "Older servers without a digest remain readable")
    }

    func testDownloadRejectsMismatchedAndInconsistentChunkDigests() async throws {
        let source = Data((0..<40_000).map { UInt8($0 % 251) })
        let mismatched = AttachmentIntegrityFixture(
            downloadData: source,
            downloadDigestMode: .constant(String(repeating: "f", count: 64))
        )
        do {
            _ = try await mismatched.downloadMessageAttachment(
                machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
                attachmentId: "webasset-feedface-10"
            )
            XCTFail("A consistent but false whole-object digest must be rejected")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedData)
        }

        let inconsistent = AttachmentIntegrityFixture(
            downloadData: source,
            downloadDigestMode: .inconsistentAfterFirst(String(repeating: "e", count: 64))
        )
        do {
            _ = try await inconsistent.downloadMessageAttachment(
                machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
                attachmentId: "webasset-feedface-10"
            )
            XCTFail("Per-chunk digest disagreement must be rejected")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedData)
        }
    }

    func testFileDownloadVerifiesDigestWithBoundedReadsAndRemovesMismatch() async throws {
        let source = Data((0..<40_000).map { UInt8($0 % 251) })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAI-Attachment-Integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validFixture = AttachmentIntegrityFixture(downloadData: source)
        let file = try await validFixture.downloadMessageAttachmentFile(
            machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
            attachmentId: "webasset-feedface-10", destinationDirectory: directory
        )
        XCTAssertEqual(try Data(contentsOf: file.url), source)

        let badDirectory = directory.appendingPathComponent("bad", isDirectory: true)
        let badFixture = AttachmentIntegrityFixture(
            downloadData: source,
            downloadDigestMode: .constant(String(repeating: "f", count: 64))
        )
        do {
            _ = try await badFixture.downloadMessageAttachmentFile(
                machineId: "my-pc", runtimeId: "runtime.web", instanceId: "photo", sessionId: "photo-upload",
                attachmentId: "webasset-feedface-10", destinationDirectory: badDirectory
            )
            XCTFail("A file download with a mismatched digest must be rejected")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedData)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: badDirectory.path), [], "Invalid downloaded bytes must not be left as an export file")
    }
}
