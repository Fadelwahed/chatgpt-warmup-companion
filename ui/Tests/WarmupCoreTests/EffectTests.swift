import Foundation
import Testing
@testable import WarmupCore

/// App 0.5: "Did it help?" from the usage windows seen at each send (backlog item 3).
@Suite struct Effect {
    static let eight = 1_794_463_200_000
    static let minute = 60_000
    static let fiveHours = 300

    static func state(_ id: String, at: Int, minutes: Int?, resetsAt: Int?, weekly: Bool = false) -> AccountState {
        let short = UsageWindow(usedPercent: 1, windowMinutes: minutes, resetsAt: resetsAt)
        let week = UsageWindow(usedPercent: 10, windowMinutes: 10_080, resetsAt: at + 86_400_000)
        let usage = AccountUsage(primary: weekly ? week : short, secondary: weekly ? nil : week, observedAt: at)
        return AccountState(enrollmentId: id, block: nil, cooldownUntil: nil, usage: usage)
    }

    static func row(at: Int, minutes: Int?, resetsAt: Int?, account: String = "a") -> UsageObservation {
        UsageObservation(account: account, observedAt: at, windowMinutes: minutes, resetsAt: resetsAt, usedPercent: 1)
    }

    @Test func classifiesByResetTime() {
        let fresh = Self.eight + Self.fiveHours * Self.minute
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: fresh)) == .startedFresh)
        #expect(
            EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: fresh - 9 * Self.minute))
                == .startedFresh)
        #expect(
            EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: fresh - 2 * 3_600_000))
                == .insideRunning)
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: nil, resetsAt: nil)) == .noShortWindow)
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: nil)) == .unclear)
        // A reset already past, or later than a fresh window allows, fits neither case.
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: Self.eight - 1)) == .unclear)
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: fresh + 3_600_000)) == .unclear)
    }

    @Test func expiredResetsAndTamperedValuesAreUnclearNotFresh() {
        // A 5-minute window that reset a minute before the send is not a fresh window.
        #expect(
            EffectReport.classify(Self.row(at: Self.eight, minutes: 5, resetsAt: Self.eight - Self.minute)) == .unclear)
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: Int.min)) == .unclear)
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: 300, resetsAt: Int.max)) == .unclear)
        #expect(EffectReport.classify(Self.row(at: Int.max, minutes: 300, resetsAt: Int.max)) == .unclear)
        #expect(EffectReport.classify(Self.row(at: Self.eight, minutes: Int.max, resetsAt: Self.eight + 1)) == .unclear)
    }

    @Test func everyReadPrunesPastRetention() {
        var log = UsageLog(rows: [Self.row(at: Self.eight, minutes: 300, resetsAt: nil)])
        let kept = log.record([], now: Self.eight + Self.minute)
        let pruned = log.record([], now: Self.eight + UsageLog.retentionMilliseconds + 1)
        #expect(!kept && pruned && log.rows.isEmpty)
    }

    @Test func recordsEachNewObservationOnceAndPicksTheShortWindow() {
        var log = UsageLog()
        let reset = Self.eight + Self.fiveHours * Self.minute
        let accounts = [
            Self.state("a", at: Self.eight, minutes: 300, resetsAt: reset),
            Self.state("b", at: Self.eight, minutes: nil, resetsAt: nil, weekly: true),
            AccountState(enrollmentId: "c", block: nil, cooldownUntil: nil, usage: nil),
        ]
        let first = log.record(accounts, now: Self.eight + Self.minute)
        let again = log.record(accounts, now: Self.eight + 2 * Self.minute)
        #expect(first && !again)
        #expect(log.rows.count == 2)
        #expect(log.rows.first { $0.account == "a" }?.windowMinutes == 300)
        // A weekly-only account has no short window: the weekly reset is never read as one.
        #expect(log.rows.first { $0.account == "b" }?.windowMinutes == nil)
        // An observation from the future (clock skew beyond a minute) is not recorded.
        let future = log.record(
            [Self.state("a", at: Self.eight + 10 * Self.minute, minutes: 300, resetsAt: reset)], now: Self.eight)
        #expect(!future)
    }

    @Test func logDropsOldRowsAndKeepsItsCap() {
        var log = UsageLog(rows: [
            Self.row(at: Self.eight - UsageLog.retentionMilliseconds - 1, minutes: 300, resetsAt: nil)
        ])
        let added = log.record([Self.state("a", at: Self.eight, minutes: 300, resetsAt: nil)], now: Self.eight)
        #expect(added)
        #expect(log.rows.map(\.observedAt) == [Self.eight])
        let many = (0..<(UsageLog.maxRows + 5)).map { Self.row(at: Self.eight + $0, minutes: 300, resetsAt: nil) }
        var full = UsageLog(rows: many)
        let capped = full.record(
            [Self.state("b", at: Self.eight + 10_000, minutes: 300, resetsAt: nil)], now: Self.eight + 20_000)
        #expect(capped)
        #expect(full.rows.count == UsageLog.maxRows)
        #expect(full.rows.last?.account == "b")
    }

    @Test func summaryVerdictsFollowTheStopRule() {
        let window = Self.fiveHours * Self.minute
        func rows(fresh: Int, inside: Int) -> UsageLog {
            let f = (0..<fresh).map {
                Self.row(
                    at: Self.eight - $0 * 86_400_000, minutes: 300, resetsAt: Self.eight - $0 * 86_400_000 + window)
            }
            let i = (0..<inside).map {
                Self.row(
                    at: Self.eight - $0 * 3_600_000, minutes: 300, resetsAt: Self.eight - $0 * 3_600_000 + 3_600_000,
                    account: "b")
            }
            return UsageLog(rows: f + i)
        }
        #expect(
            EffectReport.summary(UsageLog(), order: ["a"], now: Self.eight).verdict
                == "No warm-up with usage data seen yet.")
        #expect(
            EffectReport.summary(rows(fresh: 3, inside: 0), order: ["a"], now: Self.eight).verdict
                == "Too early to tell: 3 of 10 warm-ups with a clear answer.")
        let good = EffectReport.summary(rows(fresh: 8, inside: 4), order: ["a", "b"], now: Self.eight)
        #expect(good.verdict == "Of 12 warm-ups with a clear answer, 8 started a fresh window.")
        #expect(good.lines == ["Account 1: 8 started a fresh window", "Account 2: 4 inside a running window"])
        let tie = EffectReport.summary(rows(fresh: 5, inside: 5), order: ["a", "b"], now: Self.eight)
        #expect(tie.verdict == "No clear answer: 5 of 10 warm-ups with a clear answer started a fresh window.")
        let bad = EffectReport.summary(rows(fresh: 4, inside: 7), order: ["a", "b"], now: Self.eight)
        #expect(bad.verdict == "Of 11 warm-ups with a clear answer, 7 started no fresh window.")
        #expect(!bad.verdict.contains("stop rule"))
        // Unclear sends never count toward a verdict.
        let unclear = (0..<9).map { Self.row(at: Self.eight - $0 * 3_600_000, minutes: 300, resetsAt: nil) }
        let fiveFresh = rows(fresh: 5, inside: 0).rows
        let mixed = EffectReport.summary(UsageLog(rows: unclear + fiveFresh), order: ["a"], now: Self.eight)
        #expect(mixed.verdict == "Too early to tell: 5 of 10 warm-ups with a clear answer.")
        // Accounts no longer enrolled and rows older than 14 days are left out.
        #expect(EffectReport.summary(rows(fresh: 8, inside: 4), order: ["a"], now: Self.eight).total == 8)
        #expect(
            EffectReport.summary(rows(fresh: 8, inside: 0), order: ["a"], now: Self.eight + 20 * 86_400_000).total == 0)
    }

    @Test func copiedTextHasNoIdsOrTimes() {
        let log = UsageLog(rows: [
            Self.row(at: Self.eight, minutes: 300, resetsAt: Self.eight + 300 * Self.minute, account: "enr_secret")
        ])
        let text = EffectReport.text(EffectReport.summary(log, order: ["enr_secret"], now: Self.eight))
        #expect(!text.contains("enr_secret"))
        #expect(!text.contains(":00"))
        #expect(text.contains("Account 1: 1 started a fresh window"))
        #expect(text.contains("Stop rule"))
    }

    @Test func usageLogStoreRoundTripsPrivately() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UsageLogStore(directory: folder)
        #expect(store.load() == UsageLog())
        let log = UsageLog(rows: [Self.row(at: Self.eight, minutes: 300, resetsAt: nil)])
        #expect(store.save(log))
        #expect(store.load() == log)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["usage-log.json"])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        #expect(store.load() == UsageLog())
    }
}
