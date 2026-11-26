import Foundation
import Testing

@testable import WarmupCore

/// App 0.5.1 fixes (FABLE-PLAN-2, work order 051).
@Suite struct Fixes051 {
    static let eight = 1_794_463_200_000
    static let minute = 60_000

    static func row(at: Int, minutes: Int?, resetsAt: Int?, account: String = "a") -> UsageObservation {
        UsageObservation(account: account, observedAt: at, windowMinutes: minutes, resetsAt: resetsAt, usedPercent: 1)
    }

    static func status(_ name: String, edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output(name, edit: edit)))
    }

    // MARK: C1

    @Test func boundarySendsAreTheirOwnClass() {
        let boundary = EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: Self.eight + 1_000))
        #expect(boundary == .atBoundary)
        let running = EffectReport.classify(
            Self.row(at: Self.eight, minutes: 300, resetsAt: Self.eight + 11 * Self.minute))
        #expect(running == .insideRunning)
        let fresh = EffectReport.classify(
            Self.row(at: Self.eight, minutes: 300, resetsAt: Self.eight + 300 * Self.minute))
        #expect(fresh == .startedFresh)
        // A 15-minute window with 8 minutes left fits both readings: unclear, never fresh.
        let both = EffectReport.classify(Self.row(at: Self.eight, minutes: 15, resetsAt: Self.eight + 8 * Self.minute))
        #expect(both == .unclear)
    }

    @Test func boundarySendsStayOutOfTheVerdict() {
        let rows = (0..<10).map {
            Self.row(at: Self.eight - $0 * 3_600_000, minutes: 300, resetsAt: Self.eight - $0 * 3_600_000 + 30_000)
        }
        let summary = EffectReport.summary(UsageLog(rows: rows), order: ["a"], now: Self.eight)
        #expect(summary.count(.atBoundary) == 10)
        #expect(summary.verdict == "Too early to tell: 0 of 10 warm-ups with a clear answer.")
        #expect(summary.lines == ["Account 1: 10 landed just before the old window reset"])
        #expect(EffectReport.text(summary).contains("landed just before the old window reset"))
    }

    // MARK: C3

    @Test func coreDateStringsUseAsciiDigits() throws {
        let date = Date(timeIntervalSince1970: Double(Self.eight) / 1000)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let day = ClockTime.day(from: date, zone: utc)
        let time = ClockTime.string(from: date, zone: utc)
        let today = try #require(FriendlyTime.today(zone: "UTC", now: date))
        let next = NextSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: Self.eight)
        let local = try #require(ClockTime.localAdmission(next, scheduleZone: "Asia/Gaza", local: utc))
        #expect(day == "2026-11-12")
        #expect(today == "2026-11-12")
        #expect(time == "06:00")
        #expect(local == "06:00")
        for text in [day, time, today, local] {
            #expect(text.unicodeScalars.allSatisfy { $0.isASCII })
        }
        // Without the engine's instant, the schedule zone's date and time give the moment.
        let unanchored = NextSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: nil)
        #expect(ClockTime.localAdmission(unanchored, scheduleZone: "Asia/Gaza", local: utc) == "06:00")
    }

    // MARK: C6

    @Test func truncatedUnresolvedListsSayOrMore() throws {
        let plain = try Self.status("status-paused")
        #expect(plain.unresolvedTruncated != true)
        #expect(!UnresolvedText.line(plain).contains("or more"))
        let cut = try Self.status("status-paused") {
            $0["unresolvedTruncated"] = true
            $0["historyTruncated"] = true
        }
        #expect(cut.unresolvedTruncated == true)
        #expect(cut.historyTruncated == true)
        let count = cut.unresolved.count
        #expect(
            UnresolvedText.line(cut)
                == "\(count) or more sends have no recorded result. They are never resent.")
        let absent = try Self.status("status-paused") {
            $0.removeValue(forKey: "unresolvedTruncated")
            $0.removeValue(forKey: "historyTruncated")
        }
        #expect(absent.unresolvedTruncated == nil)
        #expect(!UnresolvedText.line(absent).contains("or more"))
    }

    // MARK: X1

    @Test func unresolvedNoteLeavesTheHeroButFeedsTheMenu() throws {
        let status = try Self.status("status-paused")
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
        #expect(!glance.notes.contains { $0.contains("possible send") })
        #expect(glance.unresolvedNote == UnresolvedText.line(status))
        let clean = GlanceBuilder.make(status: try Self.status("status-enabled") { $0["unresolved"] = [] }, today: nil)
        #expect(clean.unresolvedNote == nil)
    }

    // MARK: X7

    @Test func weekSpansAndSpokenDaysUsePlainDates() {
        #expect(VacationText.span(start: "2026-11-15", end: "2026-11-21") == "15–21 Nov")
        #expect(VacationText.span(start: "2026-11-28", end: "2026-12-04") == "28 Nov – 4 Dec")
        #expect(VacationText.span(start: "2026-12-04", end: "2026-11-28") == nil)
        #expect(VacationText.range(start: "2026-12-01", end: "2026-12-05") == "1–5 Dec (5 days)")
        let day = WeekDay(date: "2026-11-16", weekday: 1, slots: [], manualRuns: 0)
        #expect(day.spoken == "Monday 16 November: no scheduled warm-ups recorded.")
    }

    // MARK: X8

    static let forbidden = try! NSRegularExpression(
        pattern: #"\b(slot|slots|tick|ticks|admission|admissions|pilot|pilots)\b|\d{4}-\d{2}-\d{2}"#,
        options: [.caseInsensitive])

    static func offending(_ texts: [String]) -> [String] {
        texts.filter { text in
            Self.forbidden.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    @Test func userFacingTextUsesPlainWords() throws {
        var texts: [String] = []
        let today = "2026-11-12"
        // Glance.
        for name in ["status-enabled", "status-paused"] {
            let status = try Self.status(name)
            let glance = GlanceBuilder.make(status: status, today: today, observedAt: Self.eight)
            texts += [glance.headline] + glance.notes + [glance.lastOutcome, glance.unresolvedNote].compactMap { $0 }
            texts += UnresolvedGroup.make(status.unresolved, today: today).map(\.text)
        }
        // Week report.
        let status = try Self.status("status-paused")
        let history = try #require(
            ReplyValidator.payload(HistoryReport.self, from: try Fixture.output("history")))
        let week = WeekSummary.make(today: today, status: status, history: history.rows, truncated: true)
        let report = WeekReport.make(
            week: week, status: status, history: history.rows, truncated: true, asOf: Self.eight)
        // `text(zone:)` is the copied report: it keeps full dates and cause codes on purpose.
        texts += [report.headline, report.readTime(zone: "Asia/Gaza")]
        texts += report.details + week.map(\.spoken)
        // Slot detail.
        for name in ["slot-admitted", "slot-uncertain", "slot-unobserved", "slot-no-tick"] {
            let result = try #require(
                ReplyValidator.payload(SlotExplanationResult.self, from: try Fixture.output(name)))
            let e = result.explanation
            texts.append(Wording.verdict(e.verdict))
            if let missed = e.notAdmitted {
                texts += [Wording.reason(missed.cause), Wording.guidance(missed.guidance)]
            }
            for account in e.accounts {
                texts += [Wording.dispatch(account.dispatch), Wording.response(account.response)]
                texts += [Wording.guidance(account.guidance)] + [account.reason.map(Wording.reason)].compactMap { $0 }
            }
        }
        // Account text.
        let list = try #require(ReplyValidator.payload(AccountList.self, from: try Fixture.output("list")))
        for row in list.rows {
            texts += [AccountText.readiness(row), AccountText.last(row, zone: "Asia/Gaza")]
        }
        // Confirmation text and titles.
        let actions: [WarmupAction] = [
            .runAll(allowSlotOverlap: false), .runAll(allowSlotOverlap: true),
            .runAccount(enrollmentId: "enr_a", allowSlotOverlap: true), .enroll(routerAccountId: "router_a"),
            .pause(expectedRevision: 1), .resume(expectedRevision: 1),
            .saveEdit(.add(time: "09:00", today: false), expectedRevision: 1, expectedLocalDate: today),
            .setting(.exclude(start: "2026-11-20", end: "2026-11-22"), expectedRevision: 1, expectedLocalDate: today),
            .setting(.include(start: "2026-11-20", end: "2026-11-22"), expectedRevision: 1, expectedLocalDate: today),
            .setting(.accounts(nil), expectedRevision: 1, expectedLocalDate: nil),
            .setting(.accounts(["enr_a"]), expectedRevision: 1, expectedLocalDate: nil),
            .setting(.addAccount("enr_a"), expectedRevision: 1, expectedLocalDate: nil),
            .setting(.removeAccount("enr_a"), expectedRevision: 1, expectedLocalDate: nil),
            .setting(.undo, expectedRevision: 1, expectedLocalDate: today),
            .setting(.cap(enrollmentId: "enr_a", count: 2), expectedRevision: 1, expectedLocalDate: nil),
            .setting(.cap(enrollmentId: "enr_a", count: nil), expectedRevision: 1, expectedLocalDate: nil),
        ]
        for action in actions {
            texts += [
                action.title,
                Confirmation.text(for: action, enabledAccounts: 2, pilots: 2, account: "Account 1"),
            ]
        }
        #expect(texts.count > 40)
        #expect(Self.offending(texts) == [])
    }

    // MARK: X9

    @Test func accountSymbolsFollowTheState() {
        func row(_ state: String, eligible: Bool = true, reason: String = "eligible", pilot: Bool = true) -> AccountRow
        {
            AccountRow(
                routerAccountId: "router_a", enrollmentId: "enr_a", registryReason: reason, enrollmentState: state,
                eligible: eligible, enabled: state == "enabled", pilot: pilot, lastOutcome: nil, lastReason: nil,
                lastAt: nil)
        }
        #expect(AccountText.symbol(row("enabled")) == "checkmark.circle")
        #expect(AccountText.symbol(row("disabled")) == "minus.circle")
        #expect(AccountText.symbol(row("not_enrolled")) == "plus.circle")
        #expect(AccountText.symbol(row("enabled", pilot: false)) == "exclamationmark.triangle")
        #expect(AccountText.symbol(row("enabled", reason: "revoked")) == "exclamationmark.triangle")
    }

    // MARK: X14

    @Test func versionLineNamesAppAndEngine() {
        #expect(
            VersionText.line(appVersion: "0.5.1", build: "6", engineVersion: "1.2.0")
                == "Warm-up 0.5.1 (6) · Engine 1.2.0")
        #expect(VersionText.line(appVersion: "0.5.1", build: "6", engineVersion: nil) == "Warm-up 0.5.1 (6)")
        #expect(VersionText.line(appVersion: nil, build: nil, engineVersion: "1.2.0") == "Warm-up dev · Engine 1.2.0")
        #expect(VersionText.line(appVersion: nil, build: "6", engineVersion: nil) == "Warm-up dev")
    }

    // MARK: Review round 2

    @Test func timeOffConfirmationsNameTheYear() {
        let add = Confirmation.settingText(.exclude(start: "2026-12-01", end: "2026-12-05"), account: nil)
        #expect(add.contains("1–5 Dec 2026"))
        let remove = Confirmation.settingText(.include(start: "2026-12-01", end: "2026-12-01"), account: nil)
        #expect(remove.contains("1 Dec 2026"))
        let newYear = Confirmation.settingText(.exclude(start: "2026-12-30", end: "2027-01-02"), account: nil)
        #expect(newYear.contains("2026-12-30 to 2027-01-02"))
    }

    @Test func statusSummarySaysWhenTheUnresolvedListWasCut() throws {
        let cut = try Self.status("status-enabled") { $0["unresolvedTruncated"] = true }
        let text = StatusDiagnostic.text(cut, engineVersion: nil, appVersion: nil, observedAt: Date())
        #expect(text.contains("or more (list cut)"))
        let plain = try Self.status("status-enabled")
        let full = StatusDiagnostic.text(plain, engineVersion: nil, appVersion: nil, observedAt: Date())
        #expect(!full.contains("list cut"))
    }
}
