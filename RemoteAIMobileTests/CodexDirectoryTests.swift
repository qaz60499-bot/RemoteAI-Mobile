import XCTest
@testable import RemoteAIMobile

final class CodexDirectoryTests: XCTestCase {
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
}
