import Foundation

public enum SequenceApplyResult: Equatable, Sendable {
    case applied
    case duplicate
    case gap(expected: Int64, received: Int64)
}

public struct SequenceTracker: Sendable {
    public private(set) var lastSequence: Int64
    private var appliedEventIDs: Set<String>

    public init(lastSequence: Int64 = 0) {
        self.lastSequence = lastSequence
        self.appliedEventIDs = []
    }

    public mutating func apply(_ event: ProtocolV1.Event) -> SequenceApplyResult {
        if appliedEventIDs.contains(event.eventId) || event.sequence <= lastSequence {
            return .duplicate
        }

        let expected = lastSequence + 1
        guard event.sequence == expected else {
            return .gap(expected: expected, received: event.sequence)
        }

        appliedEventIDs.insert(event.eventId)
        lastSequence = event.sequence
        return .applied
    }

    public mutating func reset(to sequence: Int64) {
        lastSequence = sequence
        appliedEventIDs.removeAll(keepingCapacity: true)
    }
}
