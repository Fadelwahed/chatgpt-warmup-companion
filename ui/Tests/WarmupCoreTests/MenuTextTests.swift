import Foundation
import Testing

@testable import WarmupCore

/// App 0.6 F9 menu text, the menu-bar modes and the 0.5.1 setup card follow-up.
@Suite struct MenuTexts {
    static let at0800 = 1_794_463_200_000

    func status(edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    @Test func todayLineAndItsLabel() {
        let line = MenuText.today(marks: [
            TodayMark(time: "08:00", kind: .confirmed), TodayMark(time: "13:00", kind: .upcoming),
            TodayMark(time: "18:00", kind: .upcoming),
        ])
        #expect(line.title == "Today:  ✓ 08:00   ○ 13:00   ○ 18:00")
        #expect(line.accessibilityLabel == "Today: 08:00 confirmed, 13:00 upcoming, 18:00 upcoming.")
        let mixed = MenuText.today(marks: [
            TodayMark(time: "08:00", kind: .missed), TodayMark(time: "13:00", kind: .skipped),
        ])
        #expect(mixed.title == "Today:  ✕ 08:00   – 13:00")
        #expect(MenuText.today(marks: []).title == "Today:  no warm-ups")
    }

    @Test func todayMarksJoinTheWeekStripAndTheProjection() throws {
        let projection = try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        let admissions = try #require(projection.days.first?.admissions)
        let week = WeekDay(
            date: "2026-11-12", weekday: 4, slots: [WeekDay.Slot(date: "2026-11-12", time: "08:00", mark: .confirmed)],
            manualRuns: 0)
        let marks = TodayMark.make(week: week, admissions: admissions, now: Self.at0800 + 60_000)
        #expect(marks.map(\.kind) == [.confirmed, .upcoming, .upcoming])
        #expect(marks.map(\.time) == ["08:00", "13:00", "18:00"])
        // A passed time with no record is not called confirmed.
        let unknown = TodayMark.make(week: nil, admissions: admissions, now: Self.at0800 + 60_000)
        #expect(unknown.first?.kind == .uncertain)
    }

    /// App 0.6.8: a time moved today (08:00 → 00:10) or every day (13:00 → 13:10) is shown and ordered
    /// at the minute it runs, as Schedule shows it; the configured time stays the mark's key.
    @Test func movedTimesShowWhenTheyRun() {
        func admission(_ logical: String, runs: String, at: Int?, state: String) -> ProjectedAdmission {
            ProjectedAdmission(
                slot: "2026-11-12T\(logical)", logicalTime: logical, admission: runs, at: at, state: state,
                cause: nil, repeatedLocalTime: nil, next: nil)
        }
        let admissions = [
            admission("08:00", runs: "00:10", at: Self.at0800 - 470 * 60_000, state: "passed"),
            admission("13:00", runs: "13:10", at: Self.at0800 + 310 * 60_000, state: "upcoming"),
            admission("18:00", runs: "18:20", at: Self.at0800 + 620 * 60_000, state: "upcoming"),
        ]
        let week = WeekDay(
            date: "2026-11-12", weekday: 4, slots: [WeekDay.Slot(date: "2026-11-12", time: "08:00", mark: .confirmed)],
            manualRuns: 0)
        let marks = TodayMark.make(week: week, admissions: admissions, now: Self.at0800)
        #expect(marks.map(\.shown) == ["00:10", "13:10", "18:20"])
        #expect(marks.map(\.time) == ["08:00", "13:00", "18:00"])
        #expect(marks.map(\.kind) == [.confirmed, .upcoming, .upcoming])
        let line = MenuText.today(marks: marks)
        #expect(line.title == "Today:  ✓ 00:10   ○ 13:10   ○ 18:20")
        #expect(line.accessibilityLabel == "Today: 00:10 confirmed, 13:10 upcoming, 18:20 upcoming.")
        // A time recorded as missed at 13:00 and moved to 13:10 afterwards (a westward zone change
        // makes that possible) stays at the minute the engine recorded (review round 2).
        let missedWeek = WeekDay(
            date: "2026-11-12", weekday: 4, slots: [WeekDay.Slot(date: "2026-11-12", time: "13:00", mark: .missed)],
            manualRuns: 0)
        let ledger = [
            LedgerRow(slot: "2026-11-12T13:00", admission: "13:00", cause: "no_tick_between", zone: "UTC", at: 1)
        ]
        let recorded = TodayMark.make(
            week: missedWeek, admissions: [admissions[1]], now: Self.at0800, ledger: ledger)
        #expect(recorded.map(\.shown) == ["13:00"])
        #expect(recorded.map(\.kind) == [.missed])
        // Anything but a plain HH:mm keeps the configured time.
        for odd in ["13:10:00", "1310", "25:00", "١٣:١٠", "13:10 sk-live"] {
            let kept = TodayMark.make(
                week: nil, admissions: [admission("13:00", runs: odd, at: nil, state: "upcoming")], now: Self.at0800)
            #expect(kept.map(\.shown) == ["13:00"])
        }
    }

    /// 060-FIX2 item 6: without a projection, Today says the schedule is not available instead of
    /// claiming there are no warm-ups.
    @Test func todayWithoutAScheduleIsNotAvailable() {
        let week = WeekDay(
            date: "2026-11-12", weekday: 4, slots: [WeekDay.Slot(date: "2026-11-12", time: "08:00", mark: .confirmed)],
            manualRuns: 0)
        let marks = TodayMark.make(week: week, admissions: [], now: Self.at0800 + 60_000, available: false)
        #expect(marks.isEmpty)
        #expect(TodayMark.emptyText(available: false) == "Schedule not available")
        #expect(TodayMark.emptyText(available: true) == "No warm-ups today")
        let line = MenuText.today(marks: [TodayMark(time: "08:00", kind: .confirmed)], available: false)
        #expect(line.title == "Today:  Schedule not available")
        #expect(line.accessibilityLabel == "Today: schedule not available.")
        #expect(MenuText.today(marks: [], available: true).title == "Today:  no warm-ups")
    }

    @Test func attentionOnlyWhenUnseen() throws {
        let ledger: [String: Any] = [
            "slot": "2026-11-12T08:00", "admission": "08:00", "verdict": "not_admitted", "cause": "no_tick_between",
            "zone": "Asia/Gaza", "at": 1_794_464_000_000,
        ]
        let missed = try self.status { $0["slotLedger"] = [ledger] }
        let unseen = GlanceBuilder.make(status: missed, today: "2026-11-12")
        #expect(MenuText.attention(glance: unseen) == "Needs a look: 08:00 today")
        let seen = GlanceBuilder.make(status: missed, today: "2026-11-12", acknowledgedSlot: "2026-11-12T08:00")
        #expect(MenuText.attention(glance: seen) == nil)
        #expect(MenuText.attention(glance: GlanceBuilder.notChecked()) == nil)
    }

    @Test func unreviewedLine() {
        #expect(MenuText.unreviewed(count: 0) == nil)
        #expect(MenuText.unreviewed(count: 1) == "1 new possible send with no result")
        #expect(MenuText.unreviewed(count: 2) == "2 new possible sends with no result")
    }

    @Test func accountLinesStopAtFour() {
        let cell = UsageText.cell(usage: nil, now: Self.at0800, zone: "Asia/Gaza")
        let cells = ["a", "b", "c", "d", "e"].map { (account: $0, cell: cell) }
        let lines = MenuText.accounts(cells: cells, labels: ["a": "Work"])
        #expect(lines.count == 5)
        #expect(lines.first == "Work  ·  No usage seen yet")
        #expect(lines[1] == "Account 2  ·  No usage seen yet")
        #expect(lines.last == "5 accounts…")
        #expect(MenuText.accounts(cells: Array(cells.prefix(4)), labels: [:]).count == 4)
    }

    @Test func menuBarModes() throws {
        let next = try #require(try self.status().next)
        let now = Date(timeIntervalSince1970: Double(Self.at0800 - 135 * 60_000) / 1000)
        #expect(MenuBarMode.timeLeft.title(for: next, zone: "Asia/Gaza", now: now) == "2h 15m")
        #expect(MenuBarMode.nextTime.title(for: next, zone: "Asia/Gaza", now: now) == "08:00")
        #expect(MenuBarMode.iconOnly.title(for: next, zone: "Asia/Gaza", now: now) == nil)
        #expect(MenuBarMode.timeLeft.title(for: nil, zone: "Asia/Gaza", now: now) == nil)
        #expect(MenuBarMode.migrated(oldCountdownSwitch: true) == .timeLeft)
        #expect(MenuBarMode.migrated(oldCountdownSwitch: false) == .iconOnly)
        #expect(MenuBarMode(rawValue: "nextTime") == .nextTime)
    }

    @Test func setupCardCountsASwitchThatIsOnAsAnswered() {
        #expect(!SetupCard.needed(alertsAnswered: false, loginAnswered: false, alertsOn: true, loginOn: true))
        #expect(SetupCard.needed(alertsAnswered: false, loginAnswered: false, alertsOn: true, loginOn: false))
        #expect(!SetupCard.needed(alertsAnswered: false, loginAnswered: true, alertsOn: true, loginOn: false))
        #expect(SetupCard.needed(alertsAnswered: false, loginAnswered: false, alertsOn: false, loginOn: false))
    }

    /// 0.7.0: the menu header and the menu-bar label carry an opened problem today.
    @Test func headerAndItemLabelCarryTodaysNote() throws {
        let ledger: [String: Any] = [
            "slot": "2026-11-12T01:00", "admission": "01:00", "verdict": "not_admitted", "cause": "no_tick_between",
            "zone": "Asia/Gaza", "at": Self.at0800 - 3_600_000,
        ]
        let missed = try self.status { $0["slotLedger"] = [ledger] }
        let now = Date(timeIntervalSince1970: Double(Self.at0800 - 297 * 60_000) / 1000)
        let opened = GlanceBuilder.make(
            status: missed, today: "2026-11-12", macZone: "Asia/Gaza", acknowledgedSlot: "2026-11-12T01:00")
        #expect(
            MenuText.header(glance: opened, status: missed, now: now) == "Next 08:00 · in 4 h 57 min · 1 missed today")
        #expect(MenuText.itemLabel(glance: opened) == "Warm-up: Next 08:00 · 1 missed today")
        let fine = try self.status()
        let good = GlanceBuilder.make(status: fine, today: "2026-11-12", macZone: "Asia/Gaza")
        #expect(MenuText.header(glance: good, status: fine, now: now) == "All good · next 08:00 · in 4 h 57 min")
        #expect(MenuText.itemLabel(glance: good) == "Warm-up: All good · next 08:00")
        #expect(MenuText.header(glance: good, status: nil, now: now) == "All good · next 08:00")
        let paused = Glance(state: .paused, headline: "Paused", lastOutcome: nil, lastOutcomeSlot: nil, notes: [])
        #expect(MenuText.header(glance: paused, status: fine, now: now) == "Paused")
    }

    @Test func overviewPaneTexts() {
        let scheduled = Glance(
            state: .scheduled, headline: "All good · next 13:00", lastOutcome: nil, lastOutcomeSlot: nil, notes: [])
        #expect(HeroText.headline(scheduled) == "All good")
        #expect(HeroText.next(scheduled, countdown: "in 2 h 15 min") == "Next warm-up 13:00, in 2 h 15 min")
        #expect(HeroText.next(scheduled, countdown: nil) == "Next warm-up 13:00")
        let paused = Glance(state: .paused, headline: "Paused", lastOutcome: nil, lastOutcomeSlot: nil, notes: [])
        #expect(HeroText.headline(paused) == "Paused")
        #expect(HeroText.next(paused, countdown: "in 1 h") == nil)

        #expect(TodayMark(time: "13:00", kind: .upcoming).cellWords(countdown: "in 2 h 15 min") == "In 2 h 15 min")
        #expect(TodayMark(time: "18:00", kind: .upcoming).cellWords(countdown: nil) == "Upcoming")
        #expect(TodayMark(time: "08:00", kind: .confirmed).cellWords(countdown: "in 1 h") == "Confirmed")
        #expect(ScheduleRowText.past(.missed) == "✕ Missed")

        let week = [
            WeekDay(
                date: "2026-11-11", weekday: 3, slots: [WeekDay.Slot(date: "2026-11-11", time: "08:00", mark: .missed)],
                manualRuns: 0),
            WeekDay(
                date: "2026-11-12", weekday: 4,
                slots: [WeekDay.Slot(date: "2026-11-12", time: "08:00", mark: .confirmed)], manualRuns: 0),
        ]
        #expect(WeekDay.marksPresent(week) == [.confirmed, .missed])

        let rows = [
            HealthRow(title: "Engine", value: "Ready", level: .ok),
            HealthRow(title: "Background job", value: "Not running", level: .warning),
        ]
        #expect(HealthCheck.collapsed(rows) == "Background job: Not running")
        #expect(HealthCheck.collapsed(Array(rows.prefix(1))) == "All checks pass")

        #expect(
            UnresolvedText.line(count: 3, truncated: false)
                == "3 possible sends have no recorded result. They are never resent.")
        #expect(UnresolvedText.line(count: 1, truncated: false).hasPrefix("1 possible send has"))
    }

    /// 060-FIX3 item 5: a kept projection speaks for today only while it matches the status.
    @Test func projectionMustMatchTheCurrentStatus() throws {
        let projection = try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        let today = try #require(projection.days.first?.date)
        func status(revision: Int, zone: String) throws -> EngineStatus {
            try self.status { object in
                object["scheduleRevision"] = revision
                guard var schedule = object["schedule"] as? [String: Any] else { return }
                schedule["zone"] = zone
                object["schedule"] = schedule
            }
        }
        let matching = try status(revision: projection.scheduleRevision, zone: projection.zone)
        #expect(ProjectionCheck.current(projection: projection, status: matching, today: today))
        let edited = try status(revision: projection.scheduleRevision + 1, zone: projection.zone)
        #expect(!ProjectionCheck.current(projection: projection, status: edited, today: today))
        let moved = try status(revision: projection.scheduleRevision, zone: "Europe/Berlin")
        #expect(projection.zone != "Europe/Berlin")
        #expect(!ProjectionCheck.current(projection: projection, status: moved, today: today))
        #expect(!ProjectionCheck.current(projection: projection, status: matching, today: "1999-01-01"))
    }

    /// 060-FIX4 item 3: marks and click targets follow the date shown. After midnight, a projection
    /// that holds only yesterday yields no marks (Schedule not available), never yesterday's.
    @Test func todayMarksFollowTheDateShown() throws {
        let onlyYesterday = try #require(
            ReplyValidator.payload(
                ScheduleProjection.self,
                from: try Fixture.output("projection-default") { object in
                    let days = object["days"] as? [[String: Any]] ?? []
                    object["days"] = days.filter { $0["date"] as? String == "2026-11-12" }
                }))
        let status = try self.status()
        let week = [
            WeekDay(
                date: "2026-11-12", weekday: 4,
                slots: [WeekDay.Slot(date: "2026-11-12", time: "08:00", mark: .confirmed)], manualRuns: 0)
        ]
        let now = Self.at0800 + 60_000
        let yesterday = TodayMark.marks(
            projection: onlyYesterday, status: status, week: week, today: "2026-11-12", now: now)
        #expect(yesterday?.map(\.slot) == ["2026-11-12T08:00", "2026-11-12T13:00", "2026-11-12T18:00"])
        #expect(yesterday?.first?.kind == .confirmed)
        let afterMidnight = TodayMark.marks(
            projection: onlyYesterday, status: status, week: week, today: "2026-11-13", now: now + 86_400_000)
        #expect(afterMidnight == nil)
        #expect(TodayMark.marks(projection: nil, status: status, week: week, today: "2026-11-12", now: now) == nil)
        #expect(TodayMark.marks(projection: onlyYesterday, status: status, week: week, today: nil, now: now) == nil)
        #expect(TodayMark(time: "08:00", kind: .upcoming).slot == nil)
    }

    /// 060-FIX5 item 4: the menu Today line opens the displayed date's slot.
    @Test func todayLineOpensTheDisplayedSlot() {
        let day = "2026-11-13"
        let marks = [
            TodayMark(time: "08:00", kind: .confirmed, date: day),
            TodayMark(time: "13:00", kind: .upcoming, date: day),
            TodayMark(time: "18:00", kind: .upcoming, date: day),
        ]
        #expect(MenuText.todayTarget(marks: marks) == "2026-11-13T13:00")
        let done = [
            TodayMark(time: "08:00", kind: .confirmed, date: day), TodayMark(time: "13:00", kind: .missed, date: day),
        ]
        #expect(MenuText.todayTarget(marks: done) == "2026-11-13T13:00")
        #expect(MenuText.todayTarget(marks: []) == nil)
        #expect(MenuText.todayTarget(marks: [TodayMark(time: "08:00", kind: .upcoming)]) == nil)
    }
}
