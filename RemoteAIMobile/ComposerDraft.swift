import Combine
import Foundation

@MainActor
final class ComposerDraft: ObservableObject {
    typealias Loader = @MainActor (String) async -> String
    typealias Saver = @MainActor (String, String) async -> Void

    @Published var text = "" {
        didSet {
            guard !isChangingProgrammatically else { return }
            revision &+= 1
            localEditRevision &+= 1
            hasLocalEdits = true
            scheduleSave()
        }
    }

    /// Changes whenever the user edits text or the controller binds to another chat.
    /// Callers can retain this token when dispatching a send and avoid clearing newer text.
    private(set) var revision: UInt64 = 0

    private let debounceNanoseconds: UInt64
    private var boundSessionId: String?
    private var saver: Saver?
    private var bindingGeneration: UInt64 = 0
    private var localEditRevision: UInt64 = 0
    private var hasLocalEdits = false
    private(set) var isLoadResolved = false
    private var isChangingProgrammatically = false
    private var loadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    init(debounceNanoseconds: UInt64 = 300_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// Binds this controller to one chat. Loads are ignored if either the chat changes
    /// or the user edits while the load is in flight.
    func bind(sessionId: String?, load: @escaping Loader, save: @escaping Saver) {
        if boundSessionId == sessionId {
            saver = save
            return
        }

        debounceTask?.cancel()
        debounceTask = nil
        loadTask?.cancel()

        if let previousSessionId = boundSessionId,
           let previousSaver = saver,
           hasLocalEdits || isLoadResolved {
            enqueueSave(sessionId: previousSessionId, text: text, using: previousSaver)
        }

        bindingGeneration &+= 1
        revision &+= 1
        localEditRevision &+= 1
        let generation = bindingGeneration
        let loadRevision = localEditRevision
        boundSessionId = sessionId
        saver = save
        hasLocalEdits = false
        isLoadResolved = sessionId == nil
        setTextProgrammatically("")

        guard let sessionId else { return }
        let priorWrite = writeTask
        loadTask = Task { @MainActor [weak self] in
            await priorWrite?.value
            guard !Task.isCancelled else { return }
            let restoredText = await load(sessionId)
            guard !Task.isCancelled,
                  let self,
                  self.bindingGeneration == generation,
                  self.boundSessionId == sessionId else { return }

            self.isLoadResolved = true
            guard self.localEditRevision == loadRevision else { return }
            self.setTextProgrammatically(restoredText)
        }
    }

    /// Flushes the current snapshot after any older write. Safe to call on background
    /// and disappearance; while the initial load is pending, an untouched empty field
    /// is not written over the saved draft.
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        persistCurrentSnapshot()
        await writeTask?.value
    }

    /// Clears after a confirmed send only if no newer user edit or chat binding occurred.
    /// If the user typed during the send, the newer text is flushed instead.
    func clearAfterSend(ifRevision sentRevision: UInt64) async {
        guard revision == sentRevision else {
            await flush()
            return
        }

        debounceTask?.cancel()
        debounceTask = nil
        revision &+= 1
        localEditRevision &+= 1
        hasLocalEdits = true
        setTextProgrammatically("")
        persistCurrentSnapshot(force: true)
        await writeTask?.value
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        guard boundSessionId != nil, saver != nil else { return }
        let generation = bindingGeneration
        let editRevision = localEditRevision
        let debounce = debounceNanoseconds
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounce)
            } catch {
                return
            }
            guard let self,
                  self.bindingGeneration == generation,
                  self.localEditRevision == editRevision else { return }
            self.persistCurrentSnapshot()
        }
    }

    private func persistCurrentSnapshot(force: Bool = false) {
        guard let sessionId = boundSessionId, let saver,
              force || hasLocalEdits || isLoadResolved else { return }
        enqueueSave(sessionId: sessionId, text: text, using: saver)
    }

    private func enqueueSave(sessionId: String, text: String, using saver: @escaping Saver) {
        let previousWrite = writeTask
        writeTask = Task { @MainActor in
            await previousWrite?.value
            await saver(sessionId, text)
        }
    }

    private func setTextProgrammatically(_ value: String) {
        isChangingProgrammatically = true
        text = value
        isChangingProgrammatically = false
    }
}
