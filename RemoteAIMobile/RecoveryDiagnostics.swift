import Foundation

struct StopIdentityEvidence: Equatable {
    let expectedGenerationKey: String?
    let observedGenerationKey: String?
    let currentGenerationKey: String?
    let state: String
    let source: String?
    let observedAt: Date?
    let pageVerified: Bool

    static func decode(_ value: JSONValue?) -> StopIdentityEvidence? {
        guard let object = value?.objectValue,
              let rawState = object["state"]?.stringValue else { return nil }
        func nonemptyString(_ key: String) -> String? {
            guard let raw = object[key]?.stringValue else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return StopIdentityEvidence(
            expectedGenerationKey: nonemptyString("expectedGenerationKey"),
            observedGenerationKey: nonemptyString("observedGenerationKey"),
            currentGenerationKey: nonemptyString("currentGenerationKey"),
            state: rawState.trimmingCharacters(in: .whitespacesAndNewlines),
            source: nonemptyString("source"),
            observedAt: nonemptyString("observedAt").flatMap(RemoteAIDate.parse),
            pageVerified: object["pageVerified"]?.boolValue == true
        )
    }

    var hasVerifiedCurrentIdentity: Bool {
        ["matched", "changed"].contains(state)
            && source == "chatgpt-extension-observer"
            && pageVerified
            && observedAt != nil
            && currentGenerationKey?.isEmpty == false
            && currentGenerationKey == observedGenerationKey
    }

    var pageIdentityVerified: Bool {
        source == "chatgpt-extension-observer" && pageVerified
    }

    var hasVerifiedIdentityChange: Bool {
        state == "changed" && hasVerifiedCurrentIdentity
    }
}

struct StopLifecycleDiagnostic: Equatable {
    enum Code: String {
        case staleGeneration = "stale_generation"
        case identityChanged = "stop_identity_changed"
        case identityUnavailable = "stop_identity_unavailable"
        case notConfirmed = "stop_not_confirmed"
        case statusUnverified = "stop_status_unverified"
    }

    enum Recovery: String {
        case needsComputerVerification = "needs_computer_verification"
        case readyForExplicitStop = "ready_for_explicit_stop"
        case statusVerificationRequired = "status_verification_required"
    }

    enum Action: String {
        case verifyOnComputer = "verify_on_computer"
        case explicitlyStopVerifiedCurrentRun = "explicitly_stop_verified_current_run"
        case stopAfterStatusCheck = "stop_after_status_check"
    }

    let code: Code
    let observedAt: Date
    let recovery: Recovery
    let action: Action?
    let state: String?
    let source: String?
    let pageVerified: Bool
    let generationIdentityRefreshed: Bool
    let message: String
}

struct ConnectionFailureEpisode: Equatable {
    let fingerprint: String
    let startedAt: Date
    private(set) var lastObservedAt: Date
    private(set) var occurrenceCount: Int
    private(set) var lastPresenceRefreshAttemptAt: Date?
    private(set) var presenceRefreshAttemptCount: Int

    var code: String { fingerprint }
    var observedAt: Date { lastObservedAt }

    static func offlineProbeDelay(occurrenceCount: Int) -> TimeInterval {
        let exponent = min(4, max(0, occurrenceCount - 1))
        return min(60, 5 * pow(2, Double(exponent)))
    }

    var nextPresenceRefreshDelay: TimeInterval {
        Self.offlineProbeDelay(occurrenceCount: presenceRefreshAttemptCount + 1)
    }

    func isPresenceRefreshDue(at date: Date) -> Bool {
        let reference = lastPresenceRefreshAttemptAt ?? startedAt
        return date.timeIntervalSince(reference) >= nextPresenceRefreshDelay
    }

    init(fingerprint: String, observedAt: Date) {
        self.fingerprint = fingerprint
        self.startedAt = observedAt
        self.lastObservedAt = observedAt
        self.occurrenceCount = 1
        self.lastPresenceRefreshAttemptAt = nil
        self.presenceRefreshAttemptCount = 0
    }

    mutating func recordPresenceRefreshAttempt(at date: Date) {
        lastPresenceRefreshAttemptAt = date
        presenceRefreshAttemptCount += 1
    }

    @discardableResult
    mutating func observe(fingerprint: String, at observedAt: Date) -> Bool {
        guard self.fingerprint == fingerprint else { return false }
        lastObservedAt = max(lastObservedAt, observedAt)
        occurrenceCount += 1
        return true
    }

    func summaryFields(recoveredAt: Date, source: String) -> [String: String] {
        [
            "failureCode": fingerprint,
            "occurrenceCount": String(occurrenceCount),
            "startedAt": RemoteAIDate.string(startedAt),
            "lastObservedAt": RemoteAIDate.string(lastObservedAt),
            "recoveredAt": RemoteAIDate.string(recoveredAt),
            "durationMs": String(max(0, Int(recoveredAt.timeIntervalSince(startedAt) * 1_000))),
            "resolutionSource": source,
        ]
    }
}
