import Foundation
import Testing

@testable import WarmupCore

/// Work order 132: one alert the day before the last booked wake.
@Suite struct WakeExpiryAlert {
    static let installation = AlertScope.fingerprint(installation: "install_wake")
    static let today = "2026-12-01"

    static func plan(_ last: String?, repeating: Bool = false) -> WakePlan {
        WakePlan(bySlot: [:], lastBookedDay: last, hasRepeating: repeating)
    }

    static func record(_ plan: WakePlan, after stored: WakeExpiryRecord? = nil) -> WakeExpiryRecord? {
        WakeExpiry.update(stored, installation: Self.installation, plan: plan)
    }

    static func due(_ record: WakeExpiryRecord?, _ plan: WakePlan, enabled: Bool = true) -> Bool {
        WakeExpiry.due(record, plan: plan, scheduleEnabled: enabled, today: Self.today)
    }

    @Test func dueWhenTheLastBookedDayIsTomorrowOrToday() {
        let tomorrow = Self.plan("2026-12-02")
        #expect(Self.due(Self.record(tomorrow), tomorrow))
        let today = Self.plan("2026-12-01")
        #expect(Self.due(Self.record(today), today))
    }

    @Test func notDueTwoDaysAhead() {
        let later = Self.plan("2026-12-03")
        #expect(!Self.due(Self.record(later), later))
    }

    @Test func notDueOnceAnnouncedAndDueAgainAfterALaterDay() throws {
        let tomorrow = Self.plan("2026-12-02")
        var record = try #require(Self.record(tomorrow))
        record.announced = true
        let kept = Self.record(tomorrow, after: record)
        #expect(kept == record)
        #expect(!Self.due(kept, tomorrow))
        // An unknown read keeps the announcement, so the same day never alerts twice.
        let afterUnknown = Self.record(.unknown, after: record)
        #expect(afterUnknown == record)
        #expect(!Self.due(Self.record(tomorrow, after: afterUnknown), tomorrow))
        // The script was rerun: a later last day is a new record. Announced the day before it ends.
        let rerun = Self.plan("2026-12-09")
        let fresh = try #require(Self.record(rerun, after: record))
        #expect(fresh.lastBookedDay == "2026-12-09")
        #expect(!fresh.announced)
        #expect(WakeExpiry.due(fresh, plan: rerun, scheduleEnabled: true, today: "2026-12-08"))
        // Another installation starts its own record.
        let other = WakeExpiry.update(record, installation: "other", plan: tomorrow)
        #expect(other?.announced == false)
    }

    @Test func dueTheDayBeforeAcrossAYearBoundary() throws {
        let newYear = Self.plan("2027-01-01")
        let record = try #require(Self.record(newYear))
        #expect(WakeExpiry.due(record, plan: newYear, scheduleEnabled: true, today: "2026-12-31"))
        #expect(WakeExpiry.due(record, plan: newYear, scheduleEnabled: true, today: "2027-01-01"))
        #expect(!WakeExpiry.due(record, plan: newYear, scheduleEnabled: true, today: "2026-12-30"))
        let text = WakeExpiry.content(lastBookedDay: "2027-01-01", today: "2026-12-31")
        #expect(text.title == "Wake bookings end tomorrow")
    }

    @Test func notDueWithARepeatingWakePausedUnknownOrNoBookings() {
        let repeating = Self.plan("2026-12-02", repeating: true)
        #expect(!Self.due(Self.record(repeating), repeating))
        let tomorrow = Self.plan("2026-12-02")
        #expect(!Self.due(Self.record(tomorrow), tomorrow, enabled: false))
        #expect(!Self.due(Self.record(tomorrow), .unknown))
        #expect(Self.record(.unknown) == nil)
        let none = Self.plan(nil)
        #expect(Self.record(none) == nil)
        #expect(!Self.due(nil, none))
        // No bookings at all drops the record: a Mac kept awake needs none.
        let stored = Self.record(tomorrow)
        #expect(Self.record(none, after: stored) == nil)
    }

    @Test func stillAppliesRechecksTheNewestPlan() throws {
        let tomorrow = Self.plan("2026-12-02")
        let record = try #require(Self.record(tomorrow))
        func applies(_ plan: WakePlan, verified: Bool = true, enabled: Bool? = true) -> Bool {
            WakeExpiry.stillApplies(
                record, latestVerified: verified, latestEnabled: enabled, latestPlan: plan, today: Self.today)
        }
        #expect(applies(tomorrow))
        #expect(!applies(Self.plan("2026-12-09")), "the script was rerun")
        #expect(!applies(tomorrow, verified: false))
        #expect(!applies(tomorrow, enabled: false))
        #expect(!applies(tomorrow, enabled: nil))
        #expect(!applies(.unknown))
        #expect(!applies(Self.plan("2026-12-02", repeating: true)))
    }

    @Test func contentNamesTheDayAndNothingElse() {
        let tomorrow = WakeExpiry.content(lastBookedDay: "2026-12-02", today: Self.today)
        #expect(tomorrow.title == "Wake bookings end tomorrow")
        #expect(
            tomorrow.body
                == "After Wed 2 Dec the Mac will not wake for warm-ups. Run schedule-wakes again to book the next "
                + "4 weeks.")
        let today = WakeExpiry.content(lastBookedDay: "2026-12-02", today: "2026-12-02")
        #expect(today.title == "Wake bookings end today")
        for text in [tomorrow.title, tomorrow.body, today.title, today.body] {
            #expect(!text.contains("/"))
            #expect(!text.contains("install_"))
            // The body names "4 weeks"; apart from that and the date, no digits.
            let rest = text.replacingOccurrences(of: "Wed 2 Dec", with: "")
                .replacingOccurrences(of: "next 4 weeks", with: "")
            #expect(!rest.contains { $0.isNumber })
        }
        #expect(Fixes051.offending([tomorrow.title, tomorrow.body]).isEmpty)
    }

    @Test func theRecordStoresNoRawIdentifier() throws {
        let record = try #require(Self.record(Self.plan("2026-12-02")))
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!json.contains("install_"))
        #expect(try JSONDecoder().decode(WakeExpiryRecord.self, from: Data(json.utf8)) == record)
    }
}
