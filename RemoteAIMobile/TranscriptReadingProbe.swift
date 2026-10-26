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
        var result = [
            "readingRow": visible?.0 ?? "none",
            "readingStreamBytes": String(stream?.utf8Count ?? 0),
            "readingLoadedRows": String(loadedRowCount),
            "readingIntra": visible.map { String(Double(top - $0.1.minY)) } ?? "nan",
            "readingRowHeight": visible.map { String(Double($0.1.height)) } ?? "nan",
            "readingOffset": String(Double(scroll.contentOffset.y)),
            "readingHeight": String(Double(scroll.contentSize.height)),
            "readingViewport": String(Double(bottom - top)),
            "readingDragging": String(scroll.isDragging),
            "readingDecelerating": String(scroll.isDecelerating),
            "readingUptime": String(ProcessInfo.processInfo.systemUptime)
        ]
        if let sentinel = frames.first(where: { $0.0 == "__top__" }) {
            result["readingTopY"] = String(Double(sentinel.1.minY - top))
        }
        return result
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
