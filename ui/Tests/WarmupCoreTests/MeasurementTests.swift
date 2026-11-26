import Foundation
import Testing

@testable import WarmupCore

/// App 0.6 F1 ("Did it help?" v2) and F2 (usage cell text).
@Suite struct Measurement {
    /// 2026-11-12 08:00 in Asia/Gaza (UTC+2), a Thursday.
    static let eight = 1_794_463_200_000
    static let minute = 60_000
    static let hour = 3_600_000
    static let day = 86_400_000
    static let zone = "Asia/Gaza"
    /// 2026-11-12 00:00 in Asia/Gaza.
    static let midnight = 1_794_434_400_000

    static func row(at: Int, minutes: Int?, resetsAt: Int?, account: String = "a") -> UsageObservation {
        UsageObservation(account: account, observedAt: at, windowMinutes: minutes, resetsAt: resetsAt, usedPercent: 1)
    }

    static func fresh(at: Int, account: String = "a") -> UsageObservation {
        Self.row(at: at, minutes: 300, resetsAt: at + 300 * Self.minute, account: account)
    }

    @Test func countFromStartAndLabel() {
        #expect(EffectReport.countFromStart(day: "2026-11-12", zone: Self.zone) == Self.midnight)
        #expect(EffectReport.countFromStart(day: "2026-02-30", zone: Self.zone) == nil)
        #expect(EffectReport.countFromStart(day: "12 Nov", zone: Self.zone) == nil)
        #expect(EffectReport.countFromStart(day: "2026-11-12", zone: "Nowhere/City") == nil)
        #expect(EffectReport.countFromLabel(ms: Self.midnight, zone: Self.zone, now: Self.eight) == "12 Nov")
        #expect(
            EffectReport.countFromLabel(ms: Self.midnight, zone: Self.zone, now: Self.eight + 365 * Self.day)
                == "12 Nov 2026")
    }

    @Test func countFromFilter() {
        let start = Self.midnight
        let log = UsageLog(rows: [
            Self.fresh(at: start - 1_000), Self.fresh(at: start), Self.fresh(at: start + 1_000),
        ])
        #expect(EffectReport.summary(log, order: ["a"], now: Self.eight, countFrom: start).total == 2)
        #expect(EffectReport.summary(log, order: ["a"], now: Self.eight).total == 3)
        // A count-from date lifts the 14-day cut (the log's own 60-day retention still applies).
        let old = UsageLog(rows: [Self.fresh(at: Self.eight - 20 * Self.day)])
        #expect(EffectReport.summary(old, order: ["a"], now: Self.eight).total == 0)
        #expect(
            EffectReport.summary(old, order: ["a"], now: Self.eight, countFrom: Self.eight - 30 * Self.day).total == 1)
    }

    @Test func perSendListShowsEachClassNewestFirst() {
        let log = UsageLog(rows: [
            Self.fresh(at: Self.eight),
            Self.row(at: Self.eight - Self.hour, minutes: 300, resetsAt: Self.eight + Self.hour, account: "b"),
            Self.row(
                at: Self.eight - 2 * Self.hour, minutes: 300, resetsAt: Self.eight - 2 * Self.hour + 5 * Self.minute),
            Self.row(at: Self.eight - 3 * Self.hour, minutes: nil, resetsAt: nil),
            Self.row(at: Self.eight - 4 * Self.hour, minutes: 300, resetsAt: nil),
            Self.fresh(at: Self.eight, account: "gone"),
        ])
        let rows = EffectReport.rows(
            log: log, order: ["a", "b"], labels: ["a": "Work"], countFrom: nil, now: Self.eight + Self.minute,
            zone: Self.zone)
        #expect(rows.map(\.effect) == [.startedFresh, .insideRunning, .atBoundary, .noShortWindow, .unclear])
        #expect(rows.map(\.time) == ["Today 08:00", "Today 07:00", "Today 06:00", "Today 05:00", "Today 04:00"])
        #expect(rows.map(\.label) == ["Work", "Account 2", "Work", "Work", "Work"])
        #expect(rows.map(\.numberLabel) == ["Account 1", "Account 2", "Account 1", "Account 1", "Account 1"])
        #expect(rows.map(\.resetText) == ["resets 5 h later", "resets 2 h later", "reset 5 min later", "", ""])
        #expect(rows[2].effectWords == "landed just before the old window reset")
        let earlier = EffectReport.rows(
            log: UsageLog(rows: [Self.row(at: Self.eight - 2 * Self.day, minutes: 300, resetsAt: nil)]), order: ["a"],
            labels: [:], countFrom: nil, now: Self.eight, zone: Self.zone)
        #expect(earlier.map(\.time) == ["Tue 10 Nov 08:00"])
        let many = UsageLog(rows: (0..<60).map { Self.fresh(at: Self.eight - $0 * Self.hour) })
        let capped = EffectReport.rows(
            log: many, order: ["a"], labels: [:], countFrom: nil, now: Self.eight, zone: Self.zone)
        #expect(capped.count == 50)
        #expect(capped.first?.time == "Today 08:00")
    }

    @Test func decisionCardStates() {
        let keep = EffectDecision.make(counts: [.startedFresh: 8, .insideRunning: 2], total: 10, countFrom: 1)
        #expect(keep == .keep)
        #expect(keep?.text == "Most started a fresh window: keep the schedule")
        let stop = EffectDecision.make(
            counts: [.startedFresh: 2, .insideRunning: 6, .noShortWindow: 2], total: 10, countFrom: 1)
        #expect(stop == .stop)
        #expect(stop?.offersPause == true)
        #expect(stop?.text == "Most did not: turn the schedule off")
        let tie = EffectDecision.make(counts: [.startedFresh: 5, .insideRunning: 5], total: 12, countFrom: 1)
        #expect(tie == .undecided)
        #expect(tie?.text == "No clear answer yet: keep measuring")
        #expect(tie?.offersPause == false)
        #expect(EffectDecision.make(counts: [.startedFresh: 8, .insideRunning: 2], total: 10, countFrom: nil) == nil)
        #expect(
            EffectDecision.make(counts: [.startedFresh: 9, .atBoundary: 5, .unclear: 3], total: 17, countFrom: 1) == nil
        )
    }

    @Test func progressText() {
        #expect(EffectProgress.text(clear: 3, countFromLabel: "1 Dec") == "3 of 10 warm-ups measured since 1 Dec")
        #expect(EffectProgress.text(clear: 3, countFromLabel: nil) == "3 of 10 warm-ups measured in the last 14 days")
        #expect(EffectProgress.text(clear: 12, countFromLabel: "1 Dec") == "12 warm-ups measured since 1 Dec")
        #expect(EffectProgress.fraction(clear: 3) == 0.3)
        #expect(EffectProgress.fraction(clear: 12) == 1)
    }

    @Test func copiedTextHasNoIdsOrNicknames() {
        let log = UsageLog(rows: [Self.fresh(at: Self.eight, account: "enr_secret")])
        let summary = EffectReport.summary(log, order: ["enr_secret"], now: Self.eight, countFrom: Self.midnight)
        let rows = EffectReport.rows(
            log: log, order: ["enr_secret"], labels: ["enr_secret": "Work Nick"], countFrom: Self.midnight,
            now: Self.eight, zone: Self.zone)
        let text = EffectReport.text(summary, rows: rows, countFromLabel: "12 Nov")
        #expect(!text.contains("enr_secret"))
        #expect(!text.contains("Work Nick"))
        #expect(text.contains("Counting from 12 Nov"))
        #expect(text.contains("1 of 10 warm-ups measured since 12 Nov"))
        #expect(text.contains("Today 08:00 · Account 1: started a fresh window"))
        #expect(text.hasPrefix("Did it help? (since 12 Nov)"))
    }

    // MARK: - F2 usage cell

    static func usage(
        used: Double?, resetsAt: Int?, observedAt: Int = Self.eight, weekly: UsageWindow? = nil
    ) -> AccountUsage {
        AccountUsage(
            primary: UsageWindow(usedPercent: used, windowMinutes: 300, resetsAt: resetsAt), secondary: weekly,
            observedAt: observedAt)
    }

    static let reset1302 = Self.eight + 302 * Self.minute

    @Test func usageCellRunningEndedAndNone() {
        let running = UsageText.cell(
            usage: Self.usage(used: 3.5, resetsAt: Self.reset1302), now: Self.eight, zone: Self.zone)
        #expect(running.line == "96% left · resets 13:02 · seen 08:00")
        #expect(running.fraction == 0.035)
        #expect(!running.ended)
        #expect(running.weekly == nil)
        let ended = UsageText.cell(
            usage: Self.usage(used: 50, resetsAt: Self.eight + 304 * Self.minute), now: Self.eight + 305 * Self.minute,
            zone: Self.zone)
        #expect(ended.line == "Ended 13:04 · seen 08:00")
        #expect(ended.ended)
        let none = UsageText.cell(usage: nil, now: Self.eight, zone: Self.zone)
        #expect(none.main == "No usage seen yet")
        #expect(none.fraction == nil)
        let noPercent = UsageText.cell(
            usage: Self.usage(used: nil, resetsAt: Self.reset1302), now: Self.eight, zone: Self.zone)
        #expect(noPercent.line == "resets 13:02 · seen 08:00")
    }

    @Test func usageCellClampsAndNamesOtherDays() {
        let over = UsageText.cell(
            usage: Self.usage(used: 120, resetsAt: Self.reset1302), now: Self.eight, zone: Self.zone)
        #expect(over.main.hasPrefix("0% left"))
        #expect(over.fraction == 1)
        let under = UsageText.cell(
            usage: Self.usage(used: -5, resetsAt: Self.reset1302), now: Self.eight, zone: Self.zone)
        #expect(under.main.hasPrefix("100% left"))
        #expect(under.fraction == 0)
        let weekly = UsageWindow(
            usedPercent: 12, windowMinutes: 10_080, resetsAt: Self.eight + 3 * Self.day + Self.hour)
        let week = UsageText.cell(
            usage: Self.usage(used: 4, resetsAt: Self.reset1302, weekly: weekly), now: Self.eight, zone: Self.zone)
        #expect(week.weekly == "Week: 12% used, resets Sun 09:00")
        let older = UsageText.cell(
            usage: Self.usage(
                used: 4, resetsAt: Self.eight + Self.day + Self.hour, observedAt: Self.eight - 5 * Self.day),
            now: Self.eight, zone: Self.zone)
        #expect(older.line == "96% left · resets Fri 09:00 · seen Sat 08:00")
        #expect(UsageText.menuLine(label: "Work", cell: older) == "Work  ·  96% left · resets Fri 09:00")
        let line = UsageText.cell(
            usage: Self.usage(used: 3.5, resetsAt: Self.reset1302), now: Self.eight, zone: Self.zone)
        #expect(UsageText.menuLine(label: "Work", cell: line) == "Work  ·  96% left · resets 13:02")
    }
}

/// App 0.7.0: the usage cell's own "seen" line, the age of a reading, and the measurement words.
@Suite struct ReadingAge {
    static let eight = Measurement.eight
    static let hour = Measurement.hour
    static let day = Measurement.day
    static let zone = Measurement.zone

    @Test func cellKeepsSeenOutOfMain() {
        let running = UsageText.cell(
            usage: Measurement.usage(used: 3.5, resetsAt: Measurement.reset1302), now: Self.eight, zone: Self.zone)
        #expect(running.main == "96% left · resets 13:02")
        #expect(running.seen == "Seen 08:00")
        #expect(running.brief == "96% left · resets 13:02")
        let ended = UsageText.cell(
            usage: Measurement.usage(used: 50, resetsAt: Self.eight + 304 * Measurement.minute),
            now: Self.eight + 305 * Measurement.minute, zone: Self.zone)
        #expect(ended.main == "Ended 13:04")
        #expect(ended.brief == "Ended 13:04")
        #expect(ended.seen == "Seen 08:00")
        let older = UsageText.cell(
            usage: Measurement.usage(
                used: 4, resetsAt: Self.eight + Self.day + Self.hour, observedAt: Self.eight - 5 * Self.day),
            now: Self.eight, zone: Self.zone)
        #expect(older.main == "96% left · resets Fri 09:00")
        #expect(older.seen == "Seen Sat 08:00")
        #expect(older.brief == "96% left · resets Fri 09:00")
        let none = UsageText.cell(usage: nil, now: Self.eight, zone: Self.zone)
        #expect(none.seen == nil)
        #expect(none.brief == "No usage seen yet")
        #expect(none.line == "No usage seen yet")
        // Nothing but the time: `main` stays "seen 08:00" and it is not shown twice.
        let bare = UsageText.cell(
            usage: Measurement.usage(used: nil, resetsAt: nil), now: Self.eight, zone: Self.zone)
        #expect(bare.main == "seen 08:00")
        #expect(bare.brief == "seen 08:00")
        #expect(bare.seen == nil)
        #expect(bare.line == "seen 08:00")
        let noShort = UsageText.cell(
            usage: AccountUsage(primary: nil, secondary: nil, observedAt: Self.eight), now: Self.eight, zone: Self.zone)
        #expect(noShort.main == "No short window")
        #expect(noShort.brief == "No short window")
        #expect(noShort.seen == "Seen 08:00")
        #expect(noShort.line == "No short window · seen 08:00")
        for cell in [running, ended, older, noShort] { #expect(!cell.main.contains("seen")) }
    }

    @Test func stateLineSaysWhenAReadingIsOld() {
        func line(age: Int, readiness: String = "Ready", nicknamed: Bool = false) -> String {
            AccountText.stateLine(
                readiness: readiness, observedAt: Self.eight - age, nicknamed: nicknamed, now: Self.eight,
                zone: Self.zone)
        }
        #expect(line(age: 2 * Self.hour) == "Ready")
        #expect(line(age: 24 * Self.hour) == "Ready")
        #expect(line(age: 30 * Self.hour) == "Ready · last seen Wed")
        #expect(line(age: 8 * Self.day) == "Ready · last seen 4 Nov")
        #expect(line(age: 30 * Self.hour, readiness: "Cooling down") == "Cooling down")
        #expect(line(age: 30 * Self.hour, nicknamed: true) == "Ready")
        let unread = AccountText.stateLine(
            readiness: "Ready", observedAt: nil, nicknamed: false, now: Self.eight, zone: Self.zone)
        #expect(unread == "Ready")
    }

    @Test func measurementWordsForUnsetAndSet() {
        #expect(EffectReport.noCountFrom == "Decision period hasn't started.")
        #expect(EffectReport.notStarted == "Decision period hasn't started. Counting the last 14 days.")
        #expect(EffectReport.setStartDate == "Set Start Date…")
        #expect(!EffectReport.noCountFrom.contains("count from"))
        #expect(EffectProgress.text(clear: 3, countFromLabel: nil) == "3 of 10 warm-ups measured in the last 14 days")
        #expect(EffectProgress.text(clear: 3, countFromLabel: "1 Dec") == "3 of 10 warm-ups measured since 1 Dec")
    }
}
