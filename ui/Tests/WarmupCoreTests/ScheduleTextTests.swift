import Foundation
import Testing

@testable import WarmupCore

/// App 0.6 F7 (spacing advice), X5 (selection on open) and X6 (row words, folded days).
@Suite struct ScheduleText {
    static let tail = "A warm-up can land just before the earlier window resets and start nothing."
    /// Today's admissions in projection-default (2026-11-12, Asia/Gaza).
    static let at0800 = 1_794_463_200_000
    static let at1300 = 1_794_481_200_000

    func projection(edit: ((inout [String: Any]) -> Void)? = nil) throws -> ScheduleProjection {
        try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default", edit: edit)))
    }

    static func admission(
        _ time: String, at: Int?, state: String = "upcoming", cause: String? = nil
    ) -> ProjectedAdmission {
        ProjectedAdmission(
            slot: "2026-11-12T\(time)", logicalTime: time, admission: time, at: at, state: state, cause: cause,
            repeatedLocalTime: nil, next: nil)
    }

    // MARK: - F7

    @Test func spacingAdviceAroundTheWindow() {
        #expect(
            SpacingAdvice.make(times: ["08:00", "13:00"], windowMinutes: 300) == [
                "13:00 is exactly 5 hours after 08:00. \(Self.tail) Try 13:10."
            ])
        #expect(
            SpacingAdvice.make(times: ["08:00", "13:09"], windowMinutes: 300) == [
                "13:09 is 5 h 9 min after 08:00. \(Self.tail) Try 13:10."
            ])
        #expect(SpacingAdvice.make(times: ["08:00", "13:11"], windowMinutes: 300).isEmpty)
        #expect(
            SpacingAdvice.make(times: ["08:00", "10:00"], windowMinutes: 300) == [
                "10:00 is 2 hours after 08:00, inside the window it starts. It will not start a fresh one. Try 13:10."
            ])
    }

    @Test func spacingAdviceNeedsAWindowAndSortsTimes() {
        #expect(SpacingAdvice.make(times: ["08:00", "13:00"], windowMinutes: nil).isEmpty)
        let advice = SpacingAdvice.make(times: ["18:00", "08:00", "13:00"], windowMinutes: 300)
        #expect(advice.count == 2)
        #expect(advice.first?.hasPrefix("13:00 is exactly 5 hours after 08:00.") == true)
        #expect(advice.last?.hasSuffix("Try 18:10.") == true)
        // Rounded up to 5 minutes, and left out past 23:55.
        #expect(
            SpacingAdvice.make(times: ["08:03", "13:00"], windowMinutes: 300).first?.hasSuffix("Try 13:15.") == true)
        #expect(
            SpacingAdvice.make(times: ["19:00", "23:50"], windowMinutes: 300) == [
                "23:50 is 4 h 50 min after 19:00, inside the window it starts. It will not start a fresh one."
            ])
    }

    @Test func observedWindowIsTheMostCommonShortOne() {
        func row(_ minutes: Int?, _ at: Int) -> UsageObservation {
            UsageObservation(account: "a", observedAt: at, windowMinutes: minutes, resetsAt: nil, usedPercent: nil)
        }
        #expect(SpacingAdvice.observedWindow(log: UsageLog()) == nil)
        #expect(SpacingAdvice.observedWindow(log: UsageLog(rows: [row(nil, 1), row(10_080, 2)])) == nil)
        #expect(
            SpacingAdvice.observedWindow(log: UsageLog(rows: [row(300, 1), row(300, 2), row(60, 3), row(60, 4)])) == 300
        )
        #expect(SpacingAdvice.observedWindow(log: UsageLog(rows: [row(300, 1), row(60, 3), row(60, 4)])) == 60)
    }

    // MARK: - X5

    @Test func initialSelection() throws {
        let today = try #require(try self.projection().days.first?.admissions)
        #expect(
            ScheduleSelection.initial(unseenProblem: "2026-11-11T18:00", today: today, now: Self.at1300 + 60_000)
                == "2026-11-11T18:00")
        #expect(
            ScheduleSelection.initial(unseenProblem: nil, today: today, now: Self.at1300 + 60_000) == "2026-11-12T13:00"
        )
        #expect(
            ScheduleSelection.initial(unseenProblem: nil, today: today, now: Self.at0800 - 60_000) == "2026-11-12T08:00"
        )
        #expect(ScheduleSelection.initial(unseenProblem: nil, today: [], now: Self.at0800) == nil)
    }

    // MARK: - X6

    @Test func foldsMatchingFutureDays() throws {
        let rows = ScheduleFold.days(
            projection: try self.projection(), recurring: ["08:00", "13:00", "18:00"], today: "2026-11-12")
        #expect(rows.count == 6)
        #expect(rows.first == .folded(date: "2026-11-13", text: "Tomorrow, Fri 13 Nov · 08:00, 13:00, 18:00"))
        #expect(rows.dropFirst().first == .folded(date: "2026-11-14", text: "Sat 14 Nov · 08:00, 13:00, 18:00"))
    }

    @Test func aDifferingDayStaysExpanded() throws {
        let projection = try self.projection { object in
            guard var days = object["days"] as? [[String: Any]],
                var admissions = days[2]["admissions"] as? [[String: Any]]
            else { return }
            admissions.removeLast()
            days[2]["admissions"] = admissions
            object["days"] = days
        }
        let rows = ScheduleFold.days(
            projection: projection, recurring: ["08:00", "13:00", "18:00"], today: "2026-11-12")
        #expect(rows.map(\.id) == projection.days.dropFirst().map(\.date))
        guard case let .expanded(day) = rows[1] else {
            Issue.record("2026-11-14 should stay expanded")
            return
        }
        #expect(day.admissions.count == 2)
        #expect(rows.filter { if case .folded = $0 { true } else { false } }.count == 5)
    }

    @Test func rowWords() {
        let now = Self.at1300 + 60_000
        let past = Self.at0800
        #expect(
            ScheduleRowText.words(
                admission: Self.admission("08:00", at: past, state: "claimed"), mark: .confirmed, isNext: false,
                now: now)
                == "✓ Confirmed")
        let missed = Self.admission("08:00", at: past, state: "not_admitted", cause: "no_tick_between")
        #expect(
            ScheduleRowText.words(admission: missed, mark: .missed, isNext: false, now: now)
                == "✕ Missed: nothing ran at that minute")
        let skipped = Self.admission("08:00", at: past, state: "not_admitted", cause: "schedule_disabled")
        #expect(
            ScheduleRowText.words(admission: skipped, mark: nil, isNext: false, now: now)
                == "– Skipped: scheduling was paused")
        let next = Self.admission("18:00", at: now + 2 * 3_600_000)
        #expect(ScheduleRowText.words(admission: next, mark: nil, isNext: true, now: now) == "Next · in 2 h")
        #expect(ScheduleRowText.words(admission: next, mark: nil, isNext: false, now: now) == "Upcoming")
        #expect(ScheduleRowText.excluded("vacation") == "– Skipped: time off")
    }
}

/// 060-FIX6 item 5: "Today" names only the current date in the schedule zone.
@Suite struct ScheduleDayHeadings {
    @Test func todayOnlyForTheCurrentDate() {
        #expect(ScheduleDayName.name("2026-11-22", today: "2026-11-22") == "Today, Sun 22 Nov")
        // A projection left from yesterday: its day is not "Today" after midnight.
        #expect(ScheduleDayName.name("2026-11-22", today: "2026-11-23") == "Sun 22 Nov")
        #expect(ScheduleDayName.name("2026-11-24", today: "2026-11-23") == "Tue 24 Nov")
        #expect(ScheduleDayName.name("2026-11-22", today: nil) == "Sun 22 Nov")
        #expect(ScheduleDayName.title("2026-11-22", count: 3, today: "2026-11-22") == "Today, Sun 22 Nov · 3 warm-ups")
        #expect(ScheduleDayName.title("2026-11-23", count: 1, today: "2026-11-22") == "Mon 23 Nov · 1 warm-up")
    }

    /// 060-FIX7 item 4: folded rows are named against the current date, not the projection's own.
    @Test func foldedRowsUseTheCurrentDate() throws {
        #expect(ScheduleDayName.coming("2026-11-23", today: "2026-11-22") == "Tomorrow, Mon 23 Nov")
        #expect(ScheduleDayName.coming("2026-11-22", today: "2026-11-22") == "Today, Sun 22 Nov")
        #expect(ScheduleDayName.coming("2026-11-24", today: "2026-11-22") == "Tue 24 Nov")
        #expect(ScheduleDayName.coming("2026-11-23", today: nil) == "Mon 23 Nov")
        // The projection was read on 12 Nov; it is now 13 Nov: 13 Nov is today, 14 Nov tomorrow.
        let projection = try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        #expect(projection.localDate == "2026-11-12")
        let rows = ScheduleFold.days(
            projection: projection, recurring: ["08:00", "13:00", "18:00"], today: "2026-11-13")
        #expect(rows.first == .folded(date: "2026-11-13", text: "Today, Fri 13 Nov · 08:00, 13:00, 18:00"))
        let tomorrow = "Tomorrow, Sat 14 Nov · 08:00, 13:00, 18:00"
        #expect(rows.dropFirst().first == .folded(date: "2026-11-14", text: tomorrow))
        for row in rows {
            if case let .folded(date, text) = row, date != "2026-11-14" { #expect(!text.hasPrefix("Tomorrow")) }
        }
    }
}
