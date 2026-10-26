import SwiftUI
import UIKit

struct TranscriptLayoutGeneration: Equatable {
    let sessionID: String
    let firstRowID: String?
    let rowCount: Int
    let browseRevision: UInt64
    let loading: Bool
}

// Observes the existing scroll view only while one pagination intent is pending.
// ScrollViewProxy remains the sole owner of programmatic positioning.
@MainActor
final class TranscriptLayoutReadiness: NSObject {
    private weak var scroll: UIScrollView?
    private weak var rootMarker: UIView?
    private var bindingID: UUID?
    private var generation: TranscriptLayoutGeneration?
    private var renderedSize: CGSize = .zero
    private var pending: (id: UUID, expected: TranscriptLayoutGeneration, deadline: TimeInterval, continuation: CheckedContinuation<Bool, Never>)?
    private var displayLink: CADisplayLink?
    nonisolated override init() { super.init() }

    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: TranscriptLayoutReadiness?
        init(_ owner: TranscriptLayoutReadiness) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) { owner?.sample(now: ProcessInfo.processInfo.systemUptime) }
    }

    func bind(_ scroll: UIScrollView, root: UIView, id: UUID) {
        self.scroll = scroll
        rootMarker = root
        bindingID = id
    }
    func unbind(id: UUID) {
        guard bindingID == id else { return }
        scroll = nil
        rootMarker = nil
        bindingID = nil
        finish(false)
    }
    func rendered(_ generation: TranscriptLayoutGeneration, size: CGSize) {
        self.generation = generation
        renderedSize = size
    }
    var isWaiting: Bool { pending != nil }

    func wait(for expected: TranscriptLayoutGeneration) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                finish(false)
                pending = (id, expected, ProcessInfo.processInfo.systemUptime + 5, continuation)
                let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }
    private func cancel(id: UUID) {
        guard pending?.id == id else { return }
        finish(false)
    }
    func sample(now: TimeInterval) {
        guard let pending else { return }
        guard now < pending.deadline else { finish(false); return }
        guard isReady(for: pending.expected) else { return }
        finish(true)
    }
    // GeometryReader and this mounted root marker describe the same region.
    // UIScrollView.contentSize can include a different lazy-layout extent.
    func isReady(for expected: TranscriptLayoutGeneration) -> Bool {
        guard generation == expected, !expected.loading,
              let scroll, scroll.window != nil,
              let rootMarker, rootMarker.window === scroll.window, rootMarker.isDescendant(of: scroll),
              !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating,
              scroll.bounds.width > 0, scroll.bounds.height > 0,
              renderedSize.width.isFinite, renderedSize.height.isFinite,
              renderedSize.width > 0, renderedSize.height > 0,
              scroll.contentSize.width.isFinite, scroll.contentSize.height.isFinite,
              scroll.contentSize.width > 0, scroll.contentSize.height > 0,
              let window = rootMarker.window else { return false }
        let scale = window.screen.scale
        return abs((rootMarker.bounds.width * scale).rounded() - (renderedSize.width * scale).rounded()) <= 1
            && abs((rootMarker.bounds.height * scale).rounded() - (renderedSize.height * scale).rounded()) <= 1
    }

    private func finish(_ ready: Bool) {
        #if DEBUG
        if let pending {
            var fields: [String: String] = [:]
            fields["ready"] = String(ready)
            fields["expectedRows"] = String(pending.expected.rowCount)
            fields["renderedRows"] = generation.map { String($0.rowCount) } ?? "none"
            fields["renderedLoading"] = generation.map { String($0.loading) } ?? "none"
            fields["generationMatches"] = String(generation == pending.expected)
            fields["renderedWidth"] = String(Double(renderedSize.width))
            fields["nativeWidth"] = scroll.map { String(Double($0.contentSize.width)) } ?? "none"
            if let rootMarker, let scroll {
                fields["nativeRootAttached"] = String(rootMarker.window != nil && rootMarker.window === scroll.window && rootMarker.isDescendant(of: scroll))
                fields["nativeRootScale"] = rootMarker.window.map { String(Double($0.screen.scale)) } ?? "none"
            } else { fields["nativeRootAttached"] = "false" }
            fields["renderedHeight"] = String(Double(renderedSize.height))
            fields["nativeRootHeight"] = rootMarker.map { String(Double($0.bounds.height)) } ?? "none"
            fields["nativeRootWidth"] = rootMarker.map { String(Double($0.bounds.width)) } ?? "none"
            fields["nativeHeight"] = scroll.map { String(Double($0.contentSize.height)) } ?? "none"
            fields["nativeTracking"] = scroll.map { String($0.isTracking) } ?? "none"
            fields["nativeDragging"] = scroll.map { String($0.isDragging) } ?? "none"
            fields["nativeDecelerating"] = scroll.map { String($0.isDecelerating) } ?? "none"
            DiagnosticsLog.shared.record("chat_pagination_readiness", fields: fields)
        }
        #endif
        displayLink?.invalidate()
        displayLink = nil
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(returning: ready)
    }
}

struct TranscriptLayoutReadinessProbe: UIViewRepresentable {
    let readiness: TranscriptLayoutReadiness
    func makeUIView(context: Context) -> Marker { Marker(readiness: readiness) }
    func updateUIView(_ view: Marker, context: Context) { view.attach() }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.readiness.unbind(id: view.bindingID) }

    final class Marker: UIView {
        let readiness: TranscriptLayoutReadiness
        let bindingID = UUID()
        init(readiness: TranscriptLayoutReadiness) {
            self.readiness = readiness
            super.init(frame: .zero)
            isAccessibilityElement = false
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
        func attach() {
            var parent = superview
            while let view = parent {
                if let scroll = view as? UIScrollView { readiness.bind(scroll, root: self, id: bindingID); return }
                parent = view.superview
            }
        }
    }
}
