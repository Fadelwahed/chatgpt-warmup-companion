import Foundation

// App 0.6.10 compatibility alert (work order 125): while alerts are on and the engine reports
// compatibility other than "ready", one notification per blocking episode, before a warm-up is lost.
// Nothing here reads or sends.

/// One blocking episode for one installation, and whether macOS accepted its alert.
public struct CompatibilityRecord: Codable, Equatable, Sendable {
    /// `AlertScope` fingerprint, never a raw ID.
    public var installation: String
    /// The engine's `compatibilityBlockedSince` (engine wall-clock milliseconds); nil when the engine
    /// gave none.
    public var since: Int?
    /// True once macOS accepted the alert for this episode.
    public var announced: Bool

    public init(installation: String, since: Int?, announced: Bool = false) {
        self.installation = installation
        self.since = since
        self.announced = announced
    }
}

public enum CompatibilityAlert {
    public static let ready = "ready"

    /// Ready → nil, which ends the episode. Blocked with no record, a record for another installation,
    /// or a different non-nil `since` → a new record, not announced. A record without `since` and a
    /// status that now has one → the value adopted and `announced` kept, so it does not alert twice.
    /// Otherwise the record unchanged.
    public static func update(
        _ record: CompatibilityRecord?, installation: String, compatibility: String, blockedSince: Int?
    ) -> CompatibilityRecord? {
        if compatibility == self.ready { return nil }
        guard let record, record.installation == installation else {
            return CompatibilityRecord(installation: installation, since: blockedSince)
        }
        guard let blockedSince else { return record }
        guard let since = record.since else {
            return CompatibilityRecord(installation: installation, since: blockedSince, announced: record.announced)
        }
        if since != blockedSince {
            return CompatibilityRecord(installation: installation, since: blockedSince)
        }
        return record
    }

    /// True when there is a record that macOS has not yet accepted an alert for.
    public static func due(_ record: CompatibilityRecord?) -> Bool {
        guard let record else { return false }
        return !record.announced
    }

    /// Whether the alert for `record` may still be posted, given the newest status the app has read.
    /// An unverified binding, no newest status, or a newest status that is ready means no. So does a
    /// newest `blockedSince` that differs from the record's: that is another episode.
    public static func stillApplies(
        _ record: CompatibilityRecord, latestVerified: Bool, latestCompatibility: String?, latestBlockedSince: Int?
    ) -> Bool {
        guard latestVerified, let latestCompatibility, latestCompatibility != self.ready else { return false }
        if let latestBlockedSince, let since = record.since, latestBlockedSince != since { return false }
        return true
    }

    /// No path, revision, hash or account.
    public static func content() -> (title: String, body: String) {
        (
            title: "Warm-up is blocked",
            body: "codex-router changed and needs a review. Upcoming warm-ups will be skipped until then."
        )
    }
}
