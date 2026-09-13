import Foundation
import Combine

// Protocol revision is independent of presentation flushes and of Swift grapheme
// counts. A delta can only extend the exact acknowledged stream revision.
private struct AssistantStreamPresentation: Equatable {
    let text: String
    let bytes: Int
}

final class AssistantStream: ObservableObject {
    let id: String
    let performance = StreamPerformance()
    private(set) var revision: Int64
    private var chunks: [String]
    private var preview: String
    @Published private var presentation: AssistantStreamPresentation
    var visibleText: String { presentation.text }
    var visibleBytes: Int { presentation.bytes }
    private(set) var utf8Count: Int
    private(set) var materializedBytes = 0

    init(id: String, revision: Int64, text: String) {
        self.id = id
        self.revision = revision
        chunks = [text]
        preview = String(text.suffix(2001))
        utf8Count = text.utf8.count
        presentation = AssistantStreamPresentation(text: preview, bytes: utf8Count)
    }

    // Normal deltas never materialize the sealed prefix. Only explicit full-text
    // access or terminal verification pays this cost once.
    var text: String {
        materializedBytes += utf8Count
        return chunks.joined()
    }
    var presentationText: String { preview }

    // Called by the Store's existing 90 ms flush, not once per network event.
    // Only the active row observes this object; history arrays stay untouched.
    func flushPresentation() {
        performance.published()
        let next = AssistantStreamPresentation(text: preview, bytes: utf8Count)
        if presentation != next { presentation = next }
    }

    func append(id: String, baseRevision: Int64, revision: Int64, delta: String) -> Bool {
        let began = StreamPerformance.now
        defer { performance.merge.add((StreamPerformance.now - began) * 1000) }
        guard baseRevision >= 0, baseRevision < Int64.max,
              self.id == id, self.revision == baseRevision, revision == baseRevision + 1 else { return false }
        performance.receivedDelta()
        chunks.append(delta)
        utf8Count += delta.utf8.count
        preview = String((preview + String(delta.suffix(2001))).suffix(2001))
        self.revision = revision
        return true
    }
}
