import Foundation

// App 0.7.0 wake expiry alert (work order 132): with alerts on, one notification the day before the
// last booked wake, once per last booked day. Modelled on `PauseReminder`. Nothing here reads or sends.

/// The last booked wake day seen for one installation, and whether macOS accepted its alert.
public struct WakeExpiryRecord: Codable, Equatable, Sendable {
    /// `AlertScope` fingerprint, never a raw ID.
    public var installation: String
    /// yyyy-MM-dd in the Mac's local time.
    public var lastBookedDay: String
    /// True once macOS accepted the alert for this day.
    public var announced: Bool

    public init(installation: String, lastBookedDay: String, announced: Bool = false) {
        self.installation = installation
        self.lastBookedDay = lastBookedDay
        self.announced = announced
    }
}

public enum WakeExpiry {
    /// An unknown plan leaves the record unchanged, so a failed read never forgets an announcement.
    /// No bookings → nil. No record, another installation or another last day (the script was rerun)
    /// → a new record, not announced. Otherwise the record unchanged.
    public static func update(_ record: WakeExpiryRecord?, installation: String, plan: WakePlan) -> WakeExpiryRecord? {
        guard plan.isKnown else { return record }
        guard let last = plan.lastBookedDay else { return nil }
        guard let record, record.installation == installation, record.lastBookedDay == last else {
            return WakeExpiryRecord(installation: installation, lastBookedDay: last)
        }
        return record
    }

    /// True when scheduling is on, the plan is known with no repeating event, its last booked day is the
    /// record's and is today or tomorrow (`today` yyyy-MM-dd, Mac local), and it was not announced.
    public static func due(_ record: WakeExpiryRecord?, plan: WakePlan, scheduleEnabled: Bool, today: String) -> Bool {
        guard let record, !record.announced else { return false }
        return self.applies(record, plan: plan, scheduleEnabled: scheduleEnabled, today: today)
    }

    /// Whether the alert for `record` may still be posted, given the newest status and plan the app has.
    /// An unverified binding or no newest status means no; so does a plan that no longer matches.
    public static func stillApplies(
        _ record: WakeExpiryRecord, latestVerified: Bool, latestEnabled: Bool?, latestPlan: WakePlan, today: String
    ) -> Bool {
        guard latestVerified, let latestEnabled else { return false }
        return self.applies(record, plan: latestPlan, scheduleEnabled: latestEnabled, today: today)
    }

    private static func applies(_ record: WakeExpiryRecord, plan: WakePlan, scheduleEnabled: Bool, today: String)
        -> Bool
    {
        guard scheduleEnabled, plan.isKnown, !plan.hasRepeating, plan.lastBookedDay == record.lastBookedDay else {
            return false
        }
        return record.lastBookedDay == today || WeekSummary.dayBefore(record.lastBookedDay) == today
    }

    /// "Wake bookings end tomorrow" (or "end today") and the last day in words. No path, ID or account.
    public static func content(lastBookedDay: String, today: String) -> (title: String, body: String) {
        let when = lastBookedDay == today ? "today" : "tomorrow"
        let day = FriendlyTime.day(lastBookedDay, today: nil)
        return (
            title: "Wake bookings end \(when)",
            body: "After \(day) the Mac will not wake for warm-ups. Run schedule-wakes again to book the next 7 days."
        )
    }
}
