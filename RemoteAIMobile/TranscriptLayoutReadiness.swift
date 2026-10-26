import SwiftUI
import UIKit

struct TranscriptLayoutGeneration: Equatable {
    let sessionID: String
    let firstRowID: String?
    let rowCount: Int
    let browseRevision: UInt64
    let loading: Bool
}

// Samples pagination readiness only while one intent is pending; tail queries
// read the current native marker without observing or positioning the scroll view.
// ScrollViewProxy remains the sole owner of programmatic positioning.
@MainActor
final class TranscriptLayoutReadiness: NSObject {
    private weak var scroll: UIScrollView?
    private weak var rootMarker: UIView?
    private weak var tailMarker: TranscriptTailVisibilityProbe.Marker?
    private var bindingID: UUID?
    private var designatedBindingID: UUID?
    private var requestedNativeGeneration: TranscriptLayoutGeneration?
    private var nativeGeneration: TranscriptLayoutGeneration?
    private var nativeLayoutSize: CGSize = .zero
    private weak var nativeWindow: UIWindow?
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

    func registerRootMarker(id: UUID) {
        designatedBindingID = id
        bindingID = nil
        scroll = nil
        rootMarker = nil
        requestedNativeGeneration = nil
        nativeGeneration = nil
        nativeLayoutSize = .zero
        nativeWindow = nil
    }
    func bind(_ scroll: UIScrollView, root: UIView, id: UUID) {
        guard designatedBindingID == id else { return }
        let changed = self.scroll !== scroll || rootMarker !== root || bindingID != id
        self.scroll = scroll
        rootMarker = root
        bindingID = id
        if changed { requestedNativeGeneration = nil; invalidateNativeLayout(id: id) }
    }
    func unbind(id: UUID) {
        guard bindingID == id else { return }
        invalidateNativeLayout(id: id)
        scroll = nil
        rootMarker = nil
        bindingID = nil
        requestedNativeGeneration = nil
        finish(false)
    }
    func prepareRootLayout(_ generation: TranscriptLayoutGeneration, id: UUID) {
        guard bindingID == id, requestedNativeGeneration != generation else { return }
        requestedNativeGeneration = generation
        invalidateNativeLayout(id: id)
    }
    func invalidateNativeLayout(id: UUID) {
        guard bindingID == id else { return }
        nativeGeneration = nil
        nativeWindow = nil
        nativeLayoutSize = .zero
    }
    func rootDidLayout(_ generation: TranscriptLayoutGeneration, size: CGSize, id: UUID) {
        guard bindingID == id, requestedNativeGeneration == generation,
              let rootMarker, let scroll, let window = rootMarker.window,
              window === scroll.window, rootMarker.isDescendant(of: scroll),
              rootMarker.bounds.size == size else { return }
        nativeGeneration = generation
        nativeLayoutSize = size
        nativeWindow = window
    }
    func rendered(_ generation: TranscriptLayoutGeneration, size: CGSize) {
        self.generation = generation
        renderedSize = size
    }
    func registerTailMarker(_ marker: TranscriptTailVisibilityProbe.Marker) {
        // Registration happens only at creation, never from an obsolete update.
        tailMarker = marker
    }
    func unregisterTailMarker(id: UUID) {
        guard tailMarker?.bindingID == id else { return }
        tailMarker = nil
    }
    func tailIsVisible(for expected: TranscriptLayoutGeneration) -> Bool? {
        guard requestedNativeGeneration == expected,
              let scroll, let rootMarker, rootMarker.window != nil,
              rootMarker.window === scroll.window, rootMarker.isDescendant(of: scroll),
              let marker = tailMarker, marker.generation == expected,
              marker.window === scroll.window, marker.window != nil else { return nil }
        var parent = marker.superview
        while let view = parent, !(view is UIScrollView) { parent = view.superview }
        guard parent === scroll else { return nil }
        let frame = marker.convert(marker.bounds, to: scroll)
        let top = scroll.bounds.minY + scroll.adjustedContentInset.top
        let bottom = scroll.bounds.maxY - scroll.adjustedContentInset.bottom
        guard frame.minY.isFinite, frame.maxY.isFinite, frame.width.isFinite,
              frame.width > 0, frame.height > 0, top.isFinite, bottom.isFinite,
              bottom > top else { return nil }
        // Read actual marker coordinates, not the lazy stack's estimated extent.
        return frame.minY >= top - 1 && frame.maxY <= bottom + 1
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
    // A native layout acknowledgment can still have the old allocation. Require
    // capacity for the measured generation, never equality across layout layers.
    func isReady(for expected: TranscriptLayoutGeneration) -> Bool {
        guard generation == expected, !expected.loading,
              requestedNativeGeneration == expected, nativeGeneration == expected,
              let scroll, scroll.window != nil,
              let rootMarker, rootMarker.window === scroll.window, rootMarker.isDescendant(of: scroll),
              !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating,
              scroll.bounds.width > 0, scroll.bounds.height > 0,
              renderedSize.width.isFinite, renderedSize.height.isFinite,
              renderedSize.width > 0, renderedSize.height > 0,
              scroll.contentSize.width.isFinite, scroll.contentSize.height.isFinite,
              scroll.contentSize.width > 0, scroll.contentSize.height > 0,
              let window = rootMarker.window, nativeWindow === window,
              rootMarker.bounds.size == nativeLayoutSize,
              nativeLayoutSize.width.isFinite, nativeLayoutSize.height.isFinite,
              nativeLayoutSize.width > 0, nativeLayoutSize.height > 0 else { return false }
        let scale = window.screen.scale
        return (nativeLayoutSize.width * scale).rounded() >= (renderedSize.width * scale).rounded()
            && (nativeLayoutSize.height * scale).rounded() >= (renderedSize.height * scale).rounded()
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
            fields["nativeGenerationMatches"] = String(nativeGeneration == pending.expected)
            fields["nativeLayoutWidth"] = String(Double(nativeLayoutSize.width))
            fields["nativeLayoutHeight"] = String(Double(nativeLayoutSize.height))
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
    let generation: TranscriptLayoutGeneration
    func makeUIView(context: Context) -> Marker { Marker(readiness: readiness, generation: generation) }
    func updateUIView(_ view: Marker, context: Context) { view.updateGeneration(generation) }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.readiness.unbind(id: view.bindingID) }

    final class Marker: UIView {
        let readiness: TranscriptLayoutReadiness
        let bindingID = UUID()
        private var generation: TranscriptLayoutGeneration
        init(readiness: TranscriptLayoutReadiness, generation: TranscriptLayoutGeneration) {
            self.readiness = readiness
            self.generation = generation
            super.init(frame: .zero)
            readiness.registerRootMarker(id: bindingID)
            isAccessibilityElement = false
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var bounds: CGRect {
            didSet { if bounds.size != oldValue.size { readiness.invalidateNativeLayout(id: bindingID) } }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            readiness.invalidateNativeLayout(id: bindingID)
            attach()
            setNeedsLayout()
        }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            readiness.invalidateNativeLayout(id: bindingID)
            attach()
            setNeedsLayout()
        }
        func updateGeneration(_ generation: TranscriptLayoutGeneration) {
            let changed = self.generation != generation
            self.generation = generation
            attach()
            if changed { setNeedsLayout() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Only save a receipt here. The pending frame observer resumes the
            // caller; this callback never changes SwiftUI state or positions.
            readiness.rootDidLayout(generation, size: bounds.size, id: bindingID)
        }
        private func attach() {
            guard window != nil else { readiness.unbind(id: bindingID); return }
            var parent = superview
            while let view = parent {
                if let scroll = view as? UIScrollView {
                    readiness.bind(scroll, root: self, id: bindingID)
                    readiness.prepareRootLayout(generation, id: bindingID)
                    return
                }
                parent = view.superview
            }
        }
    }
}

// A measurement only: no state callback, scroll writer, observer, or frame loop.
struct TranscriptTailVisibilityProbe: UIViewRepresentable {
    let readiness: TranscriptLayoutReadiness
    let generation: TranscriptLayoutGeneration
    func makeUIView(context: Context) -> Marker { Marker(readiness: readiness, generation: generation) }
    func updateUIView(_ view: Marker, context: Context) { view.generation = generation }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.readiness.unregisterTailMarker(id: view.bindingID) }

    final class Marker: UIView {
        let readiness: TranscriptLayoutReadiness
        let bindingID = UUID()
        var generation: TranscriptLayoutGeneration
        init(readiness: TranscriptLayoutReadiness, generation: TranscriptLayoutGeneration) {
            self.readiness = readiness
            self.generation = generation
            super.init(frame: .zero)
            isAccessibilityElement = false
            isUserInteractionEnabled = false
            readiness.registerTailMarker(self)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
