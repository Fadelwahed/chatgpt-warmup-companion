import Foundation

// App 0.6.7 pause reminder (F12): while scheduling stays paused for a day or more and alerts are on,
// one notification, then at most one a day, until scheduling is resumed. Nothing here reads or sends.

/// When the app first saw scheduling paused for one installation, and when it last reminded.
public struct PauseRecord: Codable, Equatable, Sendable {
    /// `AlertScope` fingerprint, never a raw ID.
    public var installation: String
    /// Engine wall-clock milliseconds when the app first saw scheduling paused.
    public var since: Int
    /// The schedule revision of that paused status. Resuming and pausing again (even between two
    /// reads) changes it, so a new pause never inherits an old one's timing. An edit while paused
    /// changes it too, which only restarts the day.
    public var revision: Int
    /// Engine wall-clock milliseconds of the last reminder macOS accepted.
    public var lastReminded: Int?

    public init(installation: String, since: Int, revision: Int = 0, lastReminded: Int? = nil) {
        self.installation = installation
        self.since = since
        self.revision = revision
        self.lastReminded = lastReminded
    }
}

public enum PauseReminder {
    public static let intervalMs = 24 * 3600 * 1000

    /// Enabled → nil. Paused with no record, or a record for another installation or schedule
    /// revision → a new record with since = now. Otherwise the record unchanged.
    public static func update(
        _ record: PauseRecord?, installation: String, scheduleEnabled: Bool, revision: Int, now: Int
    ) -> PauseRecord? {
        if scheduleEnabled { return nil }
        guard let record, record.installation == installation, record.revision == revision else {
            return PauseRecord(installation: installation, since: now, revision: revision)
        }
        return record
    }

    /// True when now - since >= intervalMs and (lastReminded == nil or now - lastReminded >= intervalMs).
    /// A clock earlier than since or lastReminded is never due, and neither is a saved time so far out
    /// of range that the difference overflows (a damaged preference must not crash every launch).
    public static func due(_ record: PauseRecord?, now: Int) -> Bool {
        guard let record, self.elapsed(from: record.since, to: now) else { return false }
        guard let last = record.lastReminded else { return true }
        return self.elapsed(from: last, to: now)
    }

    private static func elapsed(from start: Int, to now: Int) -> Bool {
        let (difference, overflow) = now.subtractingReportingOverflow(start)
        return !overflow && difference >= self.intervalMs
    }

    /// Whether a reminder for `record` may still be posted, given the newest status the app has read
    /// (nil when none). A newer read that shows scheduling resumed, or a different revision (resumed
    /// and paused again, or edited), means this record's pause is over. When the newest read failed
    /// or the engine binding is not verified, the pause cannot be confirmed, so nothing is posted.
    public static func stillApplies(
        _ record: PauseRecord, latestVerified: Bool, latestEnabled: Bool?, latestRevision: Int?
    ) -> Bool {
        guard latestVerified else { return false }
        guard let latestEnabled else { return true }
        return !latestEnabled && latestRevision == record.revision
    }

    /// "Scheduling is still paused" and the time it was first seen paused, in POSIX digits and the
    /// Gregorian calendar in `zone` ("Sat 22 Nov at 10:15"). The app passes the Mac's own zone: `since`
    /// is the Mac's clock, and an unlabeled time must be the Mac's (0.6.7 review round 3).
    public static func content(since: Int, zone: TimeZone) -> (title: String, body: String) {
        let when = FriendlyTime.formatter("EEE d MMM 'at' HH:mm", zone: zone)
            .string(from: Date(timeIntervalSince1970: Double(since) / 1000))
        return (
            title: "Scheduling is still paused",
            body: "Warm-up has been paused since \(when). No automatic warm-ups run until you resume it."
        )
    }
}
