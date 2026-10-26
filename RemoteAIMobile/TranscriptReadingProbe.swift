#if DEBUG
import SwiftUI
import UIKit

// UI-mock observation only. Weak markers never set scroll position or layout.
final class ChatTranscriptReadingTrace {
    private final class Row {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }
    private var rows: [String: Row] = [:]
    weak var scroll: UIScrollView?
    weak var stream: AssistantStream?
    var loadedRowCount = 0
    var capturedAnchor: String?
    var anchorLayoutFields: [String: String] = [:]
    private var snapshotQueries = 0
    @MainActor func register(_ view: UIView, key: String) { rows[key] = Row(view) }
    @MainActor func snapshot() -> [String: String] {
        guard let scroll else { return ["readingRow": "unattached"] }
        let top = scroll.bounds.minY + scroll.adjustedContentInset.top
        let bottom = scroll.bounds.maxY - scroll.adjustedContentInset.bottom
        let frames = rows.compactMap { key, row -> (String, CGRect)? in
            guard let view = row.view, view.window != nil else { return nil }
            return (key, view.convert(view.bounds, to: scroll))
        }
        let visible = frames.filter { $0.0 != "__top__" && $0.1.maxY > top && $0.1.minY < bottom }
            .sorted { $0.1.minY < $1.1.minY }.first
        var result: [String: String] = [:]
        result["readingRow"] = visible?.0 ?? "none"
        result["readingStreamBytes"] = String(stream?.utf8Count ?? 0)
        result["readingLoadedRows"] = String(loadedRowCount)
        result["readingIntra"] = visible.map { String(Double(top - $0.1.minY)) } ?? "nan"
        result["readingRowHeight"] = visible.map { String(Double($0.1.height)) } ?? "nan"
        result["readingOffset"] = String(Double(scroll.contentOffset.y))
        result["readingHeight"] = String(Double(scroll.contentSize.height))
        result["readingViewport"] = String(Double(bottom - top))
        result["readingDragging"] = String(scroll.isDragging)
        result["readingDecelerating"] = String(scroll.isDecelerating)
        result["readingUptime"] = String(ProcessInfo.processInfo.systemUptime)
        if let capturedAnchor {
            let anchor = frames.first(where: { $0.0 == capturedAnchor })
            result["readingAnchorAttached"] = String(anchor != nil)
            if let anchor {
                result["readingAnchorContentY"] = String(Double(anchor.1.minY))
                result["readingAnchorViewportY"] = String(Double(anchor.1.minY - top))
                result["readingAnchorHeight"] = String(Double(anchor.1.height))
            }
        }
        result.merge(anchorLayoutFields, uniquingKeysWith: { _, new in new })
        if let sentinel = frames.first(where: { $0.0 == "__top__" }) {
            result["readingTopY"] = String(Double(sentinel.1.minY - top))
        }
        return result
    }
    @MainActor func accessibilitySnapshot() -> String {
        let fields = snapshot()
        if snapshotQueries < 64 {
            snapshotQueries += 1
            DiagnosticsLog.shared.record("chat_transcript_reading_snapshot_probe", fields: fields)
        }
        return fields.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: ";")
    }
}

struct ChatTranscriptReadingRowProbe: UIViewRepresentable {
    let trace: ChatTranscriptReadingTrace
    let key: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = false
        trace.register(view, key: key)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { trace.register(view, key: key) }
}
#endif
