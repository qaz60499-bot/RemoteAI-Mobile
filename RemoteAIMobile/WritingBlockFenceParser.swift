import Foundation

/// Parses the transport wrapper used for assistant Writing Blocks. Ranges are
/// NSString (UTF-16) offsets so callers can preserve all of the original body,
/// including CRLF, trailing spaces, and nested Markdown code fences.
enum WritingBlockFenceParser {
    static let language = "remoteai-writing-block-v1"

    struct Block {
        let wrapperRange: NSRange
        let bodyRange: NSRange
    }

    struct Scan {
        var blocks: [Block] = []
        var incompleteOpeningRange: NSRange?

        var containsWritingBlock: Bool {
            !blocks.isEmpty || incompleteOpeningRange != nil
        }
    }

    private struct MarkdownFence {
        let character: unichar
        let length: Int
    }

    private struct WritingFlags {
        let leadingNewline: Bool
        let trailingNewline: Bool
    }

    private struct MarkdownLine {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    static func scan(_ value: String) -> Scan {
        guard value.contains(language) else { return Scan() }

        let source = value as NSString
        let lines = markdownLines(in: source)
        var result = Scan()
        var ordinaryFence: MarkdownFence?
        var writingFence: MarkdownFence?
        var writingFlags: WritingFlags?
        var writingStart: Int?
        var writingBodyStart = 0

        for line in lines {
            if let activeWritingFence = writingFence {
                guard isFenceCloser(line, fence: activeWritingFence, in: source) else { continue }

                var bodyEnd = line.start
                if bodyEnd > writingBodyStart, source.character(at: bodyEnd - 1) == 10 {
                    // The adapter adds one LF as fence framing. Preserve a body CR
                    // or CRLF by removing only the framing LF.
                    bodyEnd -= 1
                }
                let flags = writingFlags ?? WritingFlags(leadingNewline: false, trailingNewline: false)
                let start = writingStart ?? line.start
                let wrapperEnd = flags.trailingNewline && line.end > line.contentEnd ? line.end : line.contentEnd
                result.blocks.append(Block(
                    wrapperRange: NSRange(location: start, length: wrapperEnd - start),
                    bodyRange: NSRange(location: writingBodyStart, length: max(0, bodyEnd - writingBodyStart))
                ))
                writingFence = nil
                writingFlags = nil
                writingStart = nil
                continue
            }

            if let activeOrdinaryFence = ordinaryFence {
                if isFenceCloser(line, fence: activeOrdinaryFence, in: source) {
                    ordinaryFence = nil
                }
                continue
            }

            guard let opener = fenceOpener(in: line, from: source) else { continue }
            if opener.fence.character == 96, let flags = Self.writingFlags(from: opener.info) {
                if flags.leadingNewline,
                   line.start == 0 || source.character(at: line.start - 1) != 10 {
                    ordinaryFence = opener.fence
                    continue
                }
                writingFence = opener.fence
                writingFlags = flags
                writingStart = line.start - (flags.leadingNewline ? 1 : 0)
                writingBodyStart = line.end
            } else if opener.fence.character == 126 || !opener.info.contains("`") {
                ordinaryFence = opener.fence
            }
        }

        if let writingStart {
            result.incompleteOpeningRange = NSRange(
                location: writingStart,
                length: max(0, writingBodyStart - writingStart)
            )
        }
        return result
    }

    static func containsWritingBlock(_ value: String) -> Bool {
        scan(value).containsWritingBlock
    }

    /// Removes complete Writing Block wrappers and an unfinished opening marker,
    /// retaining the exact body and surrounding prose.
    static func copyableText(_ value: String) -> String {
        let result = scan(value)
        guard result.containsWritingBlock else { return value }

        let source = value as NSString
        var pieces: [String] = []
        var cursor = 0
        for block in result.blocks {
            if block.wrapperRange.location > cursor {
                pieces.append(source.substring(with: NSRange(
                    location: cursor,
                    length: block.wrapperRange.location - cursor
                )))
            }
            pieces.append(source.substring(with: block.bodyRange))
            cursor = NSMaxRange(block.wrapperRange)
        }
        if let opening = result.incompleteOpeningRange {
            if opening.location > cursor {
                pieces.append(source.substring(with: NSRange(
                    location: cursor,
                    length: opening.location - cursor
                )))
            }
            cursor = NSMaxRange(opening)
        }
        if cursor < source.length {
            pieces.append(source.substring(from: cursor))
        }
        return pieces.joined()
    }

    private static func writingFlags(from info: String) -> WritingFlags? {
        let parts = info.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, parts[0] == language else { return nil }
        let flags = Array(parts[1])
        guard flags.count == 4, flags[0] == "p", flags[2] == "t",
              (flags[1] == "0" || flags[1] == "1"),
              (flags[3] == "0" || flags[3] == "1") else { return nil }
        return WritingFlags(leadingNewline: flags[1] == "1", trailingNewline: flags[3] == "1")
    }

    private static func markdownLines(in value: NSString) -> [MarkdownLine] {
        var lines: [MarkdownLine] = []
        var start = 0
        while start < value.length {
            let newline = value.range(
                of: "\n",
                options: [],
                range: NSRange(location: start, length: value.length - start)
            )
            let rawEnd = newline.location == NSNotFound ? value.length : newline.location
            var contentEnd = rawEnd
            if contentEnd > start, value.character(at: contentEnd - 1) == 13 {
                contentEnd -= 1
            }
            let end = newline.location == NSNotFound ? value.length : newline.location + 1
            lines.append(MarkdownLine(start: start, contentEnd: contentEnd, end: end))
            start = end
        }
        return lines
    }

    private static func fenceOpener(
        in line: MarkdownLine,
        from value: NSString
    ) -> (fence: MarkdownFence, info: String)? {
        var cursor = line.start
        var indentation = 0
        while cursor < line.contentEnd, value.character(at: cursor) == 32 {
            cursor += 1
            indentation += 1
            if indentation > 3 { return nil }
        }
        guard cursor < line.contentEnd else { return nil }
        let character = value.character(at: cursor)
        guard character == 96 || character == 126 else { return nil }
        var count = 0
        while cursor + count < line.contentEnd, value.character(at: cursor + count) == character {
            count += 1
        }
        guard count >= 3 else { return nil }
        let suffixStart = cursor + count
        let suffix = suffixStart < line.contentEnd
            ? value.substring(with: NSRange(location: suffixStart, length: line.contentEnd - suffixStart))
            : ""
        let info = suffix.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return (MarkdownFence(character: character, length: count), info)
    }

    private static func isFenceCloser(_ line: MarkdownLine, fence: MarkdownFence, in value: NSString) -> Bool {
        var cursor = line.start
        var indentation = 0
        while cursor < line.contentEnd, value.character(at: cursor) == 32 {
            cursor += 1
            indentation += 1
            if indentation > 3 { return false }
        }
        var count = 0
        while cursor + count < line.contentEnd, value.character(at: cursor + count) == fence.character {
            count += 1
        }
        guard count >= fence.length else { return false }
        cursor += count
        while cursor < line.contentEnd {
            let character = value.character(at: cursor)
            guard character == 32 || character == 9 else { return false }
            cursor += 1
        }
        return true
    }
}
