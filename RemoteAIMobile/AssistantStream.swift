import Foundation

// Protocol revision is independent of presentation flushes and of Swift grapheme
// counts. A delta can only extend the exact acknowledged stream revision.
final class AssistantStream {
    let id: String
    private(set) var revision: Int64
    private var chunks: [String]
    private var preview: String
    private(set) var utf8Count: Int
    private(set) var materializedBytes = 0

    init(id: String, revision: Int64, text: String) {
        self.id = id
        self.revision = revision
        chunks = [text]
        preview = String(text.prefix(2001))
        utf8Count = text.utf8.count
    }

    // Normal deltas never materialize the sealed prefix. Only explicit full-text
    // access or terminal verification pays this cost once.
    var text: String {
        materializedBytes += utf8Count
        return chunks.joined()
    }
    var presentationText: String { preview }

    func append(id: String, baseRevision: Int64, revision: Int64, delta: String) -> Bool {
        guard baseRevision >= 0, baseRevision < Int64.max,
              self.id == id, self.revision == baseRevision, revision == baseRevision + 1 else { return false }
        chunks.append(delta)
        utf8Count += delta.utf8.count
        if preview.count < 2001 { preview = String((preview + delta).prefix(2001)) }
        self.revision = revision
        return true
    }
}
