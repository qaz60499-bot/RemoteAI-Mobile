import XCTest
@testable import RemoteAIMobile

private actor StatusResponseTransport: Transport {
    private let result: JSONValue

    init(result: JSONValue) { self.result = result }

    var isConnected: Bool { true }
    func connect() async throws {}
    func disconnect() async {}
    func execute(_ command: RemoteCommand) async throws -> CommandResponseEnvelope {
        CommandResponseEnvelope(ok: true, result: result, error: nil, idempotentReplay: nil)
    }
    func eventStream() async -> AsyncStream<RemoteEvent> {
        AsyncStream { $0.finish() }
    }
    func healthStream() async -> AsyncStream<TransportHealthEvent> {
        AsyncStream { $0.finish() }
    }
}

final class CodexDirectoryTests: XCTestCase {
    func testDesktopCreateAvailabilityUsesCurrentServerCapabilityAndKeepsLegacyMetadataCompatible() throws {
        var instance = InstanceDescriptor(id: "codex.8", runtimeId: "runtime.codex", name: "Codex8", subtitle: nil)
        XCTAssertNil(instance.createSessionUnavailableReason)
        instance.config["createSessionUnavailableReason"] = .string("  请先在 Codex Desktop Project 创建 Chat。\n")
        let decoded = try JSONDecoder.remoteAI.decode(InstanceDescriptor.self,
            from: JSONEncoder.remoteAI.encode(instance))
        XCTAssertEqual(decoded.createSessionUnavailableReason, "请先在 Codex Desktop Project 创建 Chat。")
        instance.config["createSessionUnavailableReason"] = .string(" \n ")
        XCTAssertNil(instance.createSessionUnavailableReason)
    }

    private func session(_ id: String, cwd: String?, time: TimeInterval = 1) -> SessionDescriptor {
        SessionDescriptor(id: id, instanceId: "codex.8", title: "Same title", state: .idle,
                          updatedAt: Date(timeIntervalSince1970: time), workingDirectory: cwd, threadId: id)
    }

    func testDirectoryIdentityKeepsThreadsAndSeparatesProjectsWithIdenticalTitles() {
        let rows = [
            session("a", cwd: "D:\\Work\\Alpha", time: 2),
            session("b", cwd: "d:/work/alpha/", time: 3),
            session("c", cwd: "D:\\Work\\Beta"),
            session("ordinary", cwd: nil)
        ]
        let groups = CodexDirectoryGroup.make(rows)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.sessions.map(\.id), ["b", "a"])
        XCTAssertEqual(Set(groups.flatMap { $0.sessions.map(\.threadId) }), Set(["a", "b", "c"]))
        XCTAssertNil(rows.last?.codexDirectoryKey)
        XCTAssertEqual(session("extended", cwd: "\\\\?\\D:\\Work\\Alpha").codexDirectoryKey, rows.first?.codexDirectoryKey)
    }

    func testLinuxPathsRemainCaseSensitiveAndMetadataCacheIsBackwardCompatible() throws {
        XCTAssertNotEqual(session("a", cwd: "/work/Alpha").codexDirectoryKey,
                          session("b", cwd: "/work/alpha").codexDirectoryKey)
        let legacy = session("old", cwd: nil)
        let encoded = try JSONEncoder.remoteAI.encode(legacy)
        let decoded = try JSONDecoder.remoteAI.decode(SessionDescriptor.self, from: encoded)
        XCTAssertNil(decoded.workingDirectory)
        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertNil(decoded.statusSource)
        XCTAssertNil(decoded.statusReason)
        XCTAssertNil(decoded.statusObservedAt)
    }

    func testDesktopStatusProvenanceMapsListAndTargetedStatusAndKeepsOldWireCompatible() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rowObject: [String: Any] = [
            "sessionId": "thread-unloaded",
            "runtimeId": "runtime.codex",
            "instanceId": "codex.8",
            "externalId": "native-thread-id",
            "title": "Desktop Thread",
            "canonicalUrl": NSNull(),
            "status": "unknown",
            "statusSource": "codex-desktop-unloaded",
            "statusReason": "The selected Thread is not loaded by a Codex Desktop owner",
            "statusObservedAt": RemoteAIDate.string(observedAt),
            "metadata": [String: Any](),
            "createdAt": RemoteAIDate.string(observedAt),
            "updatedAt": RemoteAIDate.string(observedAt),
            "lastVisited": NSNull(),
        ]
        let rowData = try JSONSerialization.data(withJSONObject: rowObject)
        let serverSession = try JSONDecoder.remoteAI.decode(ServerSession.self, from: rowData)
        let listed = serverSession.descriptor
        XCTAssertEqual(listed.statusSource, "codex-desktop-unloaded")
        XCTAssertEqual(listed.statusReason, "The selected Thread is not loaded by a Codex Desktop owner")
        XCTAssertEqual(listed.statusObservedAt, observedAt)
        XCTAssertEqual(listed.unknownStatusExplanation, "尚未载入 Codex Desktop")
        XCTAssertFalse(listed.unknownStatusExplanation?.contains("The selected Thread") == true)

        var legacyRowObject = rowObject
        legacyRowObject.removeValue(forKey: "statusSource")
        legacyRowObject.removeValue(forKey: "statusReason")
        legacyRowObject.removeValue(forKey: "statusObservedAt")
        let legacyServerSession = try JSONDecoder.remoteAI.decode(
            ServerSession.self,
            from: JSONSerialization.data(withJSONObject: legacyRowObject)
        )
        XCTAssertNil(legacyServerSession.statusSource)
        XCTAssertNil(legacyServerSession.statusReason)
        XCTAssertNil(legacyServerSession.statusObservedAt)
        XCTAssertNil(legacyServerSession.descriptor.statusSource)

        let statusTransport = StatusResponseTransport(result: .object([
            "sessionId": .string("thread-unloaded"),
            "status": .string("unknown"),
            "statusSource": .string("codex-desktop-unavailable"),
            "statusReason": .string("Desktop owner connection failed"),
            "statusObservedAt": .string(RemoteAIDate.string(observedAt)),
            "metadata": .object([:]),
        ]))
        let snapshot = try await statusTransport.sessionStatus(
            machineId: "my-pc",
            runtimeId: "runtime.codex",
            instanceId: "codex.8",
            sessionId: "thread-unloaded"
        )
        XCTAssertEqual(snapshot.statusSource, "codex-desktop-unavailable")
        XCTAssertEqual(snapshot.statusReason, "Desktop owner connection failed")
        XCTAssertEqual(snapshot.statusObservedAt, observedAt)

        var targeted = listed
        targeted.state = snapshot.state
        targeted.statusSource = snapshot.statusSource
        targeted.statusReason = snapshot.statusReason
        targeted.statusObservedAt = snapshot.statusObservedAt
        XCTAssertEqual(targeted.unknownStatusExplanation, "无法连接 Codex Desktop")
    }

    func testUnknownStatusExplanationIsLimitedToUnknownRows() {
        var row = session("unqueried", cwd: nil)
        row.state = .unknown
        row.statusSource = "codex-desktop-not-queried"
        XCTAssertEqual(row.unknownStatusExplanation, "尚未核验 Desktop 状态")
        row.statusSource = "codex-desktop-stale-cache"
        XCTAssertEqual(row.unknownStatusExplanation, "Desktop 状态已过期")
        row.state = .busy
        XCTAssertNil(row.unknownStatusExplanation)
    }
    func testNativeMessageAliasesAndUnknownStatePreserveTheirIdentity() throws {
        let row = ServerMessage(messageId: "original-client-id", sessionId: "original-thread", role: "user",
                                content: "same prompt", externalId: "native-api-id", createdAt: Date(timeIntervalSince1970: 1))
        let message = row.chatMessage
        XCTAssertEqual(message.id, "original-client-id")
        XCTAssertEqual(message.providerMessageId, "native-api-id")
        XCTAssertEqual(SessionState.server("unknown"), .unknown)
        let encoded = try JSONEncoder.remoteAI.encode(message)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "providerMessageId")
        let decoded = try JSONDecoder.remoteAI.decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.providerMessageId)
        XCTAssertEqual(decoded.id, message.id)
    }

    // Captured through the real Windows CommandRouter and Desktop owner on 2026-10-28.
    // Thread identities and workspace paths are anonymized; wire keys and values are preserved.
    func testCapturedDesktopWireKeepsListAndTargetedStatusConsistent() async throws {
        let data = Data(#"""
        [
          {
            "before": {
              "sessionId": "codex-codex-8-fixture-0",
              "runtimeId": "runtime.codex",
              "instanceId": "codex.8",
              "externalId": "fixture-0",
              "title": "Selected native Thread",
              "canonicalUrl": null,
              "status": "unknown",
              "metadata": {
                "cwd": "D:\\Work\\Project",
                "originator": "Codex Desktop"
              },
              "projectAlias": null,
              "createdAt": "2026-10-28T15:47:35.265Z",
              "updatedAt": "2026-10-28T15:47:35.266Z",
              "lastVisited": null,
              "statusSource": "codex-desktop-not-queried",
              "statusObservedAt": null,
              "statusReason": "No Desktop owner status has been requested for this Chat",
              "statusLastKnown": null,
              "statusFresh": false
            },
            "status": {
              "sessionId": "codex-codex-8-fixture-0",
              "status": "generating",
              "running": true,
              "statusSource": "codex-desktop-owner",
              "observedAt": "2026-10-28T17:29:55.377Z",
              "statusObservedAt": "2026-10-28T17:29:55.377Z",
              "statusReason": null,
              "statusLastKnown": "generating",
              "providerError": null,
              "updatedAt": "2026-10-28T15:47:35.266Z",
              "externalId": "fixture-0"
            },
            "after": {
              "sessionId": "codex-codex-8-fixture-0",
              "runtimeId": "runtime.codex",
              "instanceId": "codex.8",
              "externalId": "fixture-0",
              "title": "Selected native Thread",
              "canonicalUrl": null,
              "status": "generating",
              "metadata": {
                "cwd": "D:\\Work\\Project",
                "originator": "Codex Desktop"
              },
              "projectAlias": null,
              "createdAt": "2026-10-28T15:47:35.265Z",
              "updatedAt": "2026-10-28T15:47:35.266Z",
              "lastVisited": null,
              "statusSource": "codex-desktop-owner",
              "statusObservedAt": "2026-10-28T17:29:55.377Z",
              "statusReason": null,
              "statusLastKnown": "generating",
              "statusFresh": true
            }
          },
          {
            "before": {
              "sessionId": "codex-codex-8-fixture-1",
              "runtimeId": "runtime.codex",
              "instanceId": "codex.8",
              "externalId": "fixture-1",
              "title": "Selected native Thread",
              "canonicalUrl": null,
              "status": "unknown",
              "metadata": {
                "cwd": "D:\\Work\\Project",
                "originator": "Codex Desktop"
              },
              "projectAlias": null,
              "createdAt": "2026-10-24T05:16:07.279Z",
              "updatedAt": "2026-10-24T05:16:07.279Z",
              "lastVisited": null,
              "statusSource": "codex-desktop-not-queried",
              "statusObservedAt": null,
              "statusReason": "No Desktop owner status has been requested for this Chat",
              "statusLastKnown": null,
              "statusFresh": false
            },
            "status": {
              "sessionId": "codex-codex-8-fixture-1",
              "status": "unknown",
              "running": null,
              "statusSource": "codex-desktop-unloaded",
              "observedAt": "2026-10-28T17:29:55.438Z",
              "statusObservedAt": "2026-10-28T17:29:55.438Z",
              "statusReason": "The selected Thread is not loaded by a Codex Desktop owner",
              "statusLastKnown": null,
              "providerError": null,
              "updatedAt": "2026-10-24T05:16:07.279Z",
              "externalId": "fixture-1"
            },
            "after": {
              "sessionId": "codex-codex-8-fixture-1",
              "runtimeId": "runtime.codex",
              "instanceId": "codex.8",
              "externalId": "fixture-1",
              "title": "Selected native Thread",
              "canonicalUrl": null,
              "status": "unknown",
              "metadata": {
                "cwd": "D:\\Work\\Project",
                "originator": "Codex Desktop"
              },
              "projectAlias": null,
              "createdAt": "2026-10-24T05:16:07.279Z",
              "updatedAt": "2026-10-24T05:16:07.279Z",
              "lastVisited": null,
              "statusSource": "codex-desktop-unloaded",
              "statusObservedAt": "2026-10-28T17:29:55.438Z",
              "statusReason": "The selected Thread is not loaded by a Codex Desktop owner",
              "statusLastKnown": null,
              "statusFresh": true
            }
          }
        ]
        """#.utf8)
        let samples = try XCTUnwrap(try JSONDecoder.remoteAI.decode(JSONValue.self, from: data).arrayValue)
        XCTAssertEqual(samples.count, 2)
        for sample in samples {
            let object = try XCTUnwrap(sample.objectValue)
            let before = try JSONDecoder.remoteAI.decode(ServerSession.self,
                from: JSONEncoder.remoteAI.encode(try XCTUnwrap(object["before"])))
            let after = try JSONDecoder.remoteAI.decode(ServerSession.self,
                from: JSONEncoder.remoteAI.encode(try XCTUnwrap(object["after"])))
            let transport = StatusResponseTransport(result: try XCTUnwrap(object["status"]))
            let snapshot = try await transport.sessionStatus(machineId: "test-machine", runtimeId: "runtime.codex",
                instanceId: "codex.8", sessionId: before.descriptor.id)
            XCTAssertEqual(before.descriptor.state, .unknown)
            XCTAssertEqual(snapshot.state, after.descriptor.state)
            XCTAssertEqual(snapshot.statusSource, after.descriptor.statusSource)
            XCTAssertEqual(snapshot.statusReason, after.descriptor.statusReason)
            XCTAssertEqual(snapshot.statusObservedAt, after.descriptor.statusObservedAt)
            XCTAssertEqual(snapshot.updatedAt, after.updatedAt, "Real content revision must survive targeted status decoding")
            XCTAssertEqual(before.descriptor.workingDirectory, after.descriptor.workingDirectory)
            if snapshot.statusSource == "codex-desktop-owner" {
                XCTAssertEqual(snapshot.state, .busy)
                XCTAssertNil(after.descriptor.unknownStatusExplanation)
            } else {
                XCTAssertEqual(snapshot.state, .unknown)
                XCTAssertEqual(after.descriptor.unknownStatusExplanation, "尚未载入 Codex Desktop")
            }
        }
    }
}
