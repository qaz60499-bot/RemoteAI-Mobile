import SwiftUI
import UIKit

/// Restores the bottom position after SwiftUI finishes a content or viewport
/// layout pass, but only while the conversation is already following the tail.
struct ChatTranscriptTailFollower: UIViewRepresentable {
    let isFollowing: Bool

    func makeUIView(context: Context) -> FollowerView {
        FollowerView()
    }

    func updateUIView(_ view: FollowerView, context: Context) {
        view.isFollowing = isFollowing
        view.attachIfNeeded()
    }

    static func dismantleUIView(_ view: FollowerView, coordinator: ()) {
        view.detach()
    }

    final class FollowerView: UIView {
        var isFollowing = false {
            didSet {
                if isFollowing && !oldValue {
                    scheduleCorrection()
                }
            }
        }

        private weak var observedScrollView: UIScrollView?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var correctionScheduled = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                detach()
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.attachIfNeeded()
            }
        }

        func attachIfNeeded() {
            guard window != nil else { return }
            var ancestor = superview
            var nearestScrollView: UIScrollView?
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    nearestScrollView = scrollView
                    break
                }
                ancestor = view.superview
            }

            guard let nearestScrollView else {
                detach()
                return
            }
            guard observedScrollView !== nearestScrollView else { return }

            detach()
            observedScrollView = nearestScrollView
            contentSizeObservation = nearestScrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.scheduleCorrection()
            }
            boundsObservation = nearestScrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                self?.scheduleCorrection()
            }
            scheduleCorrection()
        }

        func detach() {
            contentSizeObservation = nil
            boundsObservation = nil
            observedScrollView = nil
            correctionScheduled = false
        }

        private func scheduleCorrection() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleCorrection()
                }
                return
            }
            guard isFollowing, !correctionScheduled else { return }
            correctionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.correctionScheduled = false
                self.correctIfNeeded()
            }
        }

        private func correctIfNeeded() {
            guard isFollowing, let scrollView = observedScrollView, scrollView.window != nil else { return }
            let panState = scrollView.panGestureRecognizer.state
            guard !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating,
                  panState != .began,
                  panState != .changed else { return }

            scrollView.layoutIfNeeded()
            let insets = scrollView.adjustedContentInset
            let bottomOffset = max(
                -insets.top,
                scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
            )
            let currentOffset = scrollView.contentOffset
            guard abs(bottomOffset - currentOffset.y) > 1 else { return }
            scrollView.setContentOffset(CGPoint(x: currentOffset.x, y: bottomOffset), animated: false)
        }
    }
}
