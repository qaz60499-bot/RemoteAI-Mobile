import XCTest
@testable import RemoteAIMobile

final class WritingBlockFenceTests: XCTestCase {
    func testFencedWritingBlockPreservesExactBodyAndSurroundingMarkdown() {
        let body = "第一段\n\n    保留缩进\nCopy\nEdit\nExit\n```swift\nlet value = 42\n```\n末段\n"
        let text = "前置说明。\n\n\(fencedWritingBlock(body))\n\n尾部说明。"

        let segments = MessageContentSegment.parse(text)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].text, "前置说明。\n\n")
        XCTAssertTrue(segments[1].isEditBlock)
        XCTAssertFalse(segments[1].isCode)
        XCTAssertEqual(segments[1].text, body)
        XCTAssertEqual(segments[2].text, "\n\n尾部说明。")
    }

    func testRepeatedBlocksKeepBodiesAndCopyDropsOnlyTransportWrappers() {
        let body = "中文块\n    缩进\nCopy\nEdit\n```text\ninner fence\n```\n"
        let text = "Before\n\n\(fencedWritingBlock(body))\n\nBetween\n\n\(fencedWritingBlock(body))\n\nAfter"

        XCTAssertEqual(MessageContentSegment.parse(text).filter(\.isEditBlock).map(\.text), [body, body])
        XCTAssertEqual(MessageContentSegment.editBlocks(in: text).map(\.text), [body, body])
        XCTAssertEqual(MessageContentSegment.copyableText(text), "Before\n\n\(body)\n\nBetween\n\n\(body)\n\nAfter")
    }

    func testInlineWritingBlockHonorsNewlineFlagsAndDoesNotAddSeparators() {
        let body = "完整正文\n    保留缩进"
        let text = "前置\(fencedWritingBlock(body, leadingNewline: true, trailingNewline: true))后置"

        XCTAssertEqual(MessageContentSegment.editBlocks(in: text).map(\.text), [body])
        XCTAssertEqual(MessageContentSegment.copyableText(text), "前置\(body)后置")
    }

    func testBodyTrailingWhitespaceAndLineEndingsRemainExact() {
        for body in ["结尾空格  ", "结尾回车\r", "结尾换行\n", "结尾CRLF\r\n"] {
            let text = fencedWritingBlock(body)
            XCTAssertEqual(MessageContentSegment.editBlocks(in: text).map(\.text), [body])
            XCTAssertEqual(MessageContentSegment.copyableText(text), body)
        }
    }

    func testReservedFenceInsideOrdinaryMarkdownCodeIsNotAWritingBlock() {
        let text = "````markdown\n```remoteai-writing-block-v1\nnot a Writing Block\n```\n````\nAfter"

        XCTAssertFalse(MessageContentSegment.parse(text).contains(where: \.isEditBlock))
        XCTAssertEqual(MessageContentSegment.copyableText(text), text)
    }

    func testIncompleteWritingFenceHidesOpeningMarkerAndKeepsStreamedBodyCopyable() {
        let body = "正在生成的正文\n    保留缩进\nCopy\nEdit"
        let opening = "````remoteai-writing-block-v1 p0t0\n"
        let streamedText = "说明。\n\n\(opening)\(body)"

        XCTAssertEqual(MessageContentSegment.parse(streamedText).map(\.text), ["说明。\n\n"])
        XCTAssertEqual(MessageContentSegment.copyableText(streamedText), "说明。\n\n\(body)")
        XCTAssertFalse(MessageContentSegment.copyableText(streamedText).contains(WritingBlockFenceParser.language))
    }

    func testEditWordInsideMarkdownCodeFenceRemainsCode() {
        let text = "Before\n```text\nEdit\n\nnot a writing block\n```\nAfter"
        let segments = MessageContentSegment.parse(text)

        XCTAssertFalse(segments.contains(where: \.isEditBlock))
        XCTAssertTrue(segments.contains(where: { $0.isCode && $0.text.contains("Edit") }))
    }

    private func fencedWritingBlock(
        _ body: String,
        leadingNewline: Bool = false,
        trailingNewline: Bool = false
    ) -> String {
        var currentBackticks = 0
        var longestBacktickRun = 0
        for character in body {
            if character == "`" {
                currentBackticks += 1
                longestBacktickRun = max(longestBacktickRun, currentBackticks)
            } else {
                currentBackticks = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestBacktickRun + 1))
        let flags = "p\(leadingNewline ? 1 : 0)t\(trailingNewline ? 1 : 0)"
        let prefix = leadingNewline ? "\n" : ""
        let suffix = trailingNewline ? "\n" : ""
        return "\(prefix)\(fence)remoteai-writing-block-v1 \(flags)\n\(body)\n\(fence)\(suffix)"
    }
}
