import XCTest
@testable import RemoteAIMobile

final class ChatIntegrityDiagnosticsTests: XCTestCase {
    func testUTF8DigestAndLayerComparisonExposeNoTranscriptBody() {
        let body = "你好👋"
        let message = ChatMessage(
            id: "row-17",
            sessionId: "session-a",
            sequence: 17,
            role: .assistant,
            kind: .text,
            text: body,
            toolName: nil,
            toolStatus: nil,
            detail: nil,
            createdAt: Date()
        )
        let input = ChatMessageIntegrityInput(message)
        let presentation = ChatMessageIntegrityDigest.snapshot([input], layer: "presentation-model")[0]
        let cache = ChatMessageIntegrityDigest.snapshot([input], layer: "cache")[0]

        XCTAssertEqual(presentation.sha256, "fccee0f37ea1d7db8d02b8577915629619b23ecd04b0f5c00808a01eb8f9c48c")
        XCTAssertEqual(presentation.utf16Length, 4, "Emoji contributes two UTF-16 code units")
        XCTAssertEqual(presentation.utf8Bytes, 10)
        XCTAssertEqual(presentation.sha256, cache.sha256, "Matching text must hash identically across layers")
        XCTAssertEqual(presentation.rowId, cache.rowId)
        XCTAssertEqual(presentation.sequence, cache.sequence)
        XCTAssertEqual(presentation.layer, "presentation-model")
        XCTAssertEqual(cache.layer, "cache")
        XCTAssertNotEqual(presentation, cache, "Layer remains explicit in each diagnostic row")

        let changedMessage = ChatMessage(
            id: "row-17",
            sessionId: "session-a",
            sequence: 17,
            role: .assistant,
            kind: .text,
            text: body + "!",
            toolName: nil,
            toolStatus: nil,
            detail: nil,
            createdAt: Date()
        )
        let changed = ChatMessageIntegrityDigest.snapshot(
            [ChatMessageIntegrityInput(changedMessage)],
            layer: "cache"
        )[0]
        XCTAssertNotEqual(presentation.sha256, changed.sha256, "Changed source text must change its digest")
        XCTAssertFalse(presentation.diagnosticFields.values.joined(separator: "|").contains(body))
        XCTAssertEqual(Set(presentation.diagnosticFields.keys), Set([
            "rowId", "sessionId", "role", "sequence", "utf16Length", "utf8Bytes", "sha256", "layer", "status"
        ]))
    }
}
