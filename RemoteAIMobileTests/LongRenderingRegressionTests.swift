import XCTest
@testable import RemoteAIMobile

final class LongRenderingRegressionTests: XCTestCase {
    func testLargeMessagePreservesEditBlockBeyondInlinePreview() {
        let prefix = String(repeating: "普通说明文字。\n", count: 2_500)
        let editBody = "@DevSpace\n\n请继续执行真实项目，并复制这一整块内容。"
        let message = ChatMessage(
            id: "long-edit",
            sessionId: "session",
            sequence: 1,
            role: .assistant,
            kind: .text,
            text: prefix + "\n\nEdit\n\n" + editBody,
            toolName: nil,
            toolStatus: nil,
            detail: nil,
            createdAt: Date()
        )

        let prepared = MessageRenderCache().content(for: message)

        XCTAssertTrue(prepared.isLarge)
        XCTAssertFalse(prepared.segments.contains(where: \.isEditBlock), "The bounded preview should not be forced to carry a late Edit block")
        XCTAssertEqual(prepared.preservedEditBlocks.count, 1)
        XCTAssertEqual(prepared.preservedEditBlocks[0].text, editBody)
    }

    func testLargeEditBlockKeepsFullCopySourceWhilePreviewStaysBounded() {
        let editBody = String(repeating: "需要复制的完整 Edit 内容\n", count: 3_000)
        let blocks = MessageContentSegment.editBlocks(in: "Edit\n\n" + editBody)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, editBody.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(MessageRenderingPolicy.isLarge(blocks[0].text))
        XCTAssertLessThan(MessageRenderingPolicy.inlineText(blocks[0].text).utf8.count, 16 * 1024)
    }

    func testLongToolEditCardCopiesCanonicalFullContentNotInlinePreview() {
        let detail = String(repeating: "RemoteAIMobile/Views.swift changed line\n", count: 3_000)
        let message = ChatMessage(
            id: "tool-edit-long",
            sessionId: "session",
            sequence: 2,
            role: .tool,
            kind: .toolEvent,
            text: "",
            toolName: "Edit",
            toolStatus: "Completed",
            detail: detail,
            createdAt: Date()
        )

        let prepared = MessageRenderCache().content(for: message)

        XCTAssertTrue(MessageRenderingPolicy.isLarge(detail))
        XCTAssertLessThan(prepared.inlineDetail?.utf8.count ?? Int.max, 16 * 1024)
        XCTAssertTrue(message.toolCardCopyText.hasPrefix("Edit\nCompleted\n"))
        XCTAssertTrue(message.toolCardCopyText.hasSuffix(detail))
        XCTAssertGreaterThan(message.toolCardCopyText.utf8.count, prepared.inlineDetail?.utf8.count ?? 0)
    }

    func testReferenceFaviconAttachmentIsFilteredButRealProviderImageRemains() {
        let fake = MessageAttachment(
            attachmentId: "webasset-favicon",
            name: "ios-mcp",
            contentType: "image/*",
            sizeBytes: nil,
            previewURL: "https://www.google.com/s2/favicons?domain=https://github.com&sz=128",
            downloadURL: "https://github.com/witchan/ios-mcp"
        )
        let real = MessageAttachment(
            attachmentId: "webasset-real",
            name: "generated.png",
            contentType: "image/png",
            sizeBytes: nil,
            previewURL: "https://files.oaiusercontent.com/generated.png",
            downloadURL: nil
        )
        let message = ChatMessage(
            id: "attachments",
            sessionId: "session",
            sequence: 1,
            role: .assistant,
            kind: .text,
            text: "result",
            toolName: nil,
            toolStatus: nil,
            detail: nil,
            attachments: [fake, real],
            createdAt: Date()
        )

        XCTAssertEqual(message.resolvedAttachments.map(\.attachmentId), ["webasset-real"])
    }

    func testStreamingRowEqualityIgnoresUnrelatedParentRefreshes() {
        let stream = AssistantStream(id: "stream", revision: 0, text: "hello")
        let message = ChatMessage(
            id: "stream-message",
            sessionId: "session",
            sequence: 1,
            role: .assistant,
            kind: .text,
            text: "hello",
            toolName: nil,
            toolStatus: "Streaming",
            detail: nil,
            createdAt: Date()
        )

        let first = AssistantStreamRow(stream: stream, message: message, followTail: {})
        let second = AssistantStreamRow(stream: stream, message: message, followTail: {})
        XCTAssertEqual(first, second)

        let otherStream = AssistantStream(id: "stream", revision: 0, text: "hello")
        let third = AssistantStreamRow(stream: otherStream, message: message, followTail: {})
        XCTAssertNotEqual(first, third)
    }
}
