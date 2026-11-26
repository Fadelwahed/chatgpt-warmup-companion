import Foundation
import Testing
@testable import WarmupCore

/// App 0.3: engine lock, usage windows, the sleep journal, the weekly report and the scoped override.
@Suite struct Evidence {
    // 2026-11-12 08:00 in Asia/Gaza (UTC+2), the fixture's next slot.
    static let eight = 1_794_463_200_000
    static let minute = 60_000

    func status(_ edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    @Test func engineOneOneFieldsDecodeAndOldEnginesStillDecode() throws {
        let current = try self.status()
        #expect(current.workLock == WorkLock(state: "free", since: nil))
        #expect(current.next?.at == Self.eight)
        #expect(current.accounts.allSatisfy { $0.usage == nil })
        let old = try self.status {
            $0.removeValue(forKey: "workLock")
            var accounts = $0["accounts"] as? [[String: Any]] ?? []
            for index in accounts.indices { accounts[index].removeValue(forKey: "usage") }
            $0["accounts"] = accounts
        }
        #expect(old.workLock == nil)
        #expect(WorkLockCheck.note(old, observedAt: Self.eight) == nil)
    }

    @Test func workLockNotesNameTheCause() throws {
        let since = Self.eight - 90 * Self.minute
        func note(_ state: String, since: Int? = since, at observed: Int = Self.eight) throws -> String? {
            let status = try self.status {
                $0["workLock"] = ["state": state, "since": since.map { $0 as Any } ?? NSNull()]
            }
            return WorkLockCheck.note(status, observedAt: observed)
        }
        #expect(
            try note("stale")
                == "The engine is busy since 06:30: a stopped process left it held. The engine clears this at a later check when no other recovery is running."
        )
        #expect(try note("unknown")?.contains("Pause and resume scheduling") == true)
        #expect(try note("held") == "The engine has been busy since 06:30.")
        #expect(try note("held", since: Self.eight - 2 * Self.minute) == nil)  // a normal batch
        #expect(try note("free", since: nil) == nil)
        #expect(
            try note("stale", since: nil)
                == "The engine is busy: a stopped process left it held. The engine clears this at a later check when no other recovery is running."
        )
        // A lock from an earlier day carries its date.
        #expect(try note("stale", since: Self.eight - 86_400_000)?.contains("since 2026-11-11 08:00") == true)
    }

    @Test func staleLockNoteLeadsTheStaleHeartbeatGlance() throws {
        let status = try self.status {
            $0["lastTick"] = Self.eight - 30 * Self.minute
            $0["workLock"] = ["state": "stale", "since": Self.eight - 31 * Self.minute]
        }
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12", observedAt: Self.eight - 10 * Self.minute)
        #expect(glance.headline == "No check-in since 07:30")
        #expect(glance.notes.first?.hasPrefix("The engine is busy since 07:29: a stopped process left it held") == true)
        let text = StatusDiagnostic.text(
            status, engineVersion: "1.1.0-offline", appVersion: "0.3.0", observedAt: Date())
        #expect(text.contains("Engine lock: stale"))
    }

    @Test func usageLinesNameWindowsAndResets() {
        let usage = AccountUsage(
            primary: UsageWindow(usedPercent: 42, windowMinutes: 300, resetsAt: Self.eight + 150 * Self.minute),
            secondary: UsageWindow(usedPercent: 12.5, windowMinutes: 10_080, resetsAt: Self.eight + 3 * 86_400_000),
            observedAt: Self.eight - 5 * Self.minute)
        #expect(
            UsageSummary.line(usage, zone: "Asia/Gaza", now: Self.eight)
                == "5-hour window 42% used, resets 10:30. Weekly window 12.5% used, resets Sun 08:00. Seen at 07:55.")
        let past = AccountUsage(
            primary: UsageWindow(usedPercent: nil, windowMinutes: nil, resetsAt: Self.eight - 1), secondary: nil,
            observedAt: Self.eight - 86_400_000)
        #expect(
            UsageSummary.line(past, zone: "Asia/Gaza", now: Self.eight)
                == "Usage window, reset since. Seen at 2026-11-11 08:00.")
        #expect(
            UsageSummary.line(
                AccountUsage(primary: nil, secondary: nil, observedAt: Self.eight), zone: "UTC", now: Self.eight) == nil
        )
        #expect(UsageSummary.windowName(1_440) == "1-day window")
        #expect(UsageSummary.windowName(90) == "90-minute window")
    }

    @Test func sleepJournalClaimsOnlyARecordedSleepThatCoversTheWholeMinute() {
        var journal = SleepJournal()
        journal.record(.launch, at: Self.eight - 3 * 3_600_000)
        journal.record(.sleep, at: Self.eight - 80 * Self.minute)
        journal.record(.wake, at: Self.eight + 45 * Self.minute)
        #expect(
            journal.explanation(admissionAt: Self.eight, zone: "Asia/Gaza")
                == "Warm-up recorded the Mac asleep from 06:40 to 08:45, which covers that minute.")
        // A wake inside the admission minute means the engine could still have run: no claim.
        var early = SleepJournal()
        early.record(.sleep, at: Self.eight - Self.minute)
        early.record(.wake, at: Self.eight + 10_000)
        #expect(early.explanation(admissionAt: Self.eight, zone: "UTC") == nil)
        // A sleep from an earlier app session is never paired with a wake after a relaunch.
        var restarted = SleepJournal()
        restarted.record(.sleep, at: Self.eight - 80 * Self.minute)
        restarted.record(.launch, at: Self.eight + 30 * Self.minute)
        restarted.record(.wake, at: Self.eight + 45 * Self.minute)
        #expect(restarted.asleep(from: Self.eight, to: Self.eight + Self.minute) == nil)
        // No wake recorded yet: not claimed. Awake at the minute: nothing.
        var open = SleepJournal()
        open.record(.sleep, at: Self.eight - Self.minute)
        #expect(open.asleep(from: Self.eight, to: Self.eight + Self.minute) == nil)
        #expect(journal.asleep(from: Self.eight + 60 * Self.minute, to: Self.eight + 61 * Self.minute) == nil)
        // An event older than the last one (clock moved back) is ignored, and old events age out.
        journal.record(.wake, at: Self.eight - 4 * 3_600_000)
        #expect(journal.events.count == 3)
        journal.record(.wake, at: Self.eight + 15 * 86_400_000)
        #expect(journal.events.count == 1)
    }

    @Test func sleepJournalStoreRoundTripsPrivately() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SleepJournalStore(directory: folder)
        #expect(store.load() == SleepJournal())
        var journal = SleepJournal()
        journal.record(.sleep, at: 1)
        journal.record(.wake, at: 2)
        #expect(store.save(journal))
        #expect(store.load() == journal)
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["sleep-journal.json"])
        // Corrupt, oversized, linked or group-readable files are ignored, never trusted.
        try Data("not json".utf8).write(to: store.file)
        #expect(store.load() == SleepJournal())
        try Data(count: SleepJournalStore.maxBytes + 1).write(to: store.file)
        #expect(store.load() == SleepJournal())
        #expect(store.save(journal))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        #expect(store.load() == SleepJournal())
        try FileManager.default.removeItem(at: store.file)
        let elsewhere = folder.appendingPathComponent("elsewhere.json")
        #expect(SleepJournalStore(directory: folder).save(journal))
        try FileManager.default.moveItem(at: store.file, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: elsewhere)
        #expect(store.load() == SleepJournal())
        // A folder that is not private is refused for both reading and writing.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(!store.save(journal))
        #expect(!SleepJournalStore(directory: folder.appendingPathComponent("missing")).save(journal))
    }

    @Test func weekReportCountsSlotsCausesAndAccountsWithoutNamingThem() throws {
        let status = try self.status {
            $0["slotLedger"] = [
                [
                    "slot": "2026-11-11T13:00", "admission": "13:00", "cause": "no_tick_between", "zone": "Asia/Gaza",
                    "at": Self.eight,
                ],
                [
                    "slot": "2026-11-10T13:00", "admission": "13:00", "cause": "no_tick_between", "zone": "Asia/Gaza",
                    "at": Self.eight,
                ],
                [
                    "slot": "2026-11-10T18:00", "admission": "18:00", "cause": "schedule_disabled", "zone": "Asia/Gaza",
                    "at": Self.eight,
                ],
            ]
            $0["lastSlotOutcome"] = NSNull()
            $0["activeBatch"] = NSNull()
        }
        func row(_ id: String, _ slot: String, _ outcome: String, dispatched: Bool = true) -> HistoryEntry {
            HistoryEntry(
                enrollmentId: id, status: outcome, reason: "x", mode: "scheduled", slot: slot, at: Self.eight,
                dispatched: dispatched)
        }
        let history = [
            row("enr_a", "2026-11-11T08:00", "success"), row("enr_b", "2026-11-11T08:00", "success"),
            row("enr_a", "2026-11-11T18:00", "success"), row("enr_b", "2026-11-11T18:00", "blocked", dispatched: false),
            // A batch where every account was skipped (cooldown): it ran but sent nothing, and counts.
            row("enr_a", "2026-11-09T08:00", "skipped", dispatched: false),
            row("enr_a", "2026-11-12T08:00", "success"), row("enr_b", "2026-11-12T08:00", "success"),
            HistoryEntry(
                enrollmentId: "enr_a", status: "success", reason: "x", mode: "manual", slot: nil, at: Self.eight,
                dispatched: true),
        ]
        let week = WeekSummary.make(today: "2026-11-12", status: status, history: history)
        let report = WeekReport.make(week: week, status: status, history: history, truncated: true, asOf: Self.eight)
        #expect(report.slots == 7)
        #expect(report.skippedByChoice == 1)
        #expect(report.notSent == 1)
        #expect(report.counted == 6)
        #expect(report.missed == 2)
        #expect(report.problems == 1)
        // The newest slot has no finished batch on record, so it stays uncertain.
        #expect(report.confirmed == 1)
        #expect(report.uncertain == 1)
        #expect(report.headline == "1 of 6 scheduled warm-ups confirmed · 6–12 Nov")
        #expect(report.causes == [.init(cause: "no_tick_between", count: 2)])
        #expect(
            report.accounts == [
                .init(enrollmentId: "enr_a", sent: 3, confirmed: 3),
                .init(enrollmentId: "enr_b", sent: 2, confirmed: 2),
            ])
        #expect(report.manual == 1)
        // 0.7.0: the cause line moved under the headline; only the copied text keeps "Missed because".
        #expect(!report.details.contains { $0.contains("Missed because") })
        #expect(report.text(zone: "Asia/Gaza").contains("Missed because: nothing ran at that minute ×2."))
        #expect(report.details.contains { $0.contains("1 ran but sent nothing") })
        #expect(report.details.contains { $0.contains("older days may be incomplete") })
        let text = report.text(zone: "Asia/Gaza")
        #expect(!text.contains("enr_"))
        // The copy keeps full dates and cause codes; the screen uses words.
        #expect(text.hasPrefix("Warm-up weekly report (read 2026-11-12 08:00 Asia/Gaza)"))
        #expect(text.contains("Dates: 2026-11-06 to 2026-11-12"))
        #expect(text.contains("Cause codes: no_tick_between ×2"))
        #expect(text.contains("Account 2: 2 confirmed of 2 sent"))
        let empty = WeekReport.make(week: [], status: status, history: [], truncated: false, asOf: Self.eight)
        #expect(empty.headline == "No scheduled warm-ups recorded · the last 0 days")
    }

    /// Pinned before 0.7.0 moved the cause line out of `details` (order 133): the copied text must not change.
    @Test func copiedWeeklyReportTextIsPinned() throws {
        let status = try self.status {
            $0["slotLedger"] = [
                [
                    "slot": "2026-11-11T13:00", "admission": "13:00", "cause": "no_tick_between", "zone": "Asia/Gaza",
                    "at": Self.eight,
                ],
                [
                    "slot": "2026-11-10T13:00", "admission": "13:00", "cause": "no_tick_between", "zone": "Asia/Gaza",
                    "at": Self.eight,
                ],
                [
                    "slot": "2026-11-10T08:00", "admission": "08:00", "cause": "compatibility_blocked",
                    "zone": "Asia/Gaza", "at": Self.eight,
                ],
                [
                    "slot": "2026-11-10T18:00", "admission": "18:00", "cause": "schedule_disabled", "zone": "Asia/Gaza",
                    "at": Self.eight,
                ],
            ]
            $0["lastSlotOutcome"] = NSNull()
            $0["activeBatch"] = NSNull()
        }
        func row(_ id: String, _ slot: String, _ outcome: String, dispatched: Bool = true) -> HistoryEntry {
            HistoryEntry(
                enrollmentId: id, status: outcome, reason: "x", mode: "scheduled", slot: slot, at: Self.eight,
                dispatched: dispatched)
        }
        let history = [
            row("enr_a", "2026-11-11T08:00", "success"), row("enr_b", "2026-11-11T08:00", "success"),
            row("enr_a", "2026-11-11T18:00", "success"), row("enr_b", "2026-11-11T18:00", "blocked", dispatched: false),
            row("enr_a", "2026-11-12T08:00", "success"),
            HistoryEntry(
                enrollmentId: "enr_a", status: "success", reason: "x", mode: "manual", slot: nil, at: Self.eight,
                dispatched: true),
        ]
        let week = WeekSummary.make(today: "2026-11-12", status: status, history: history)
        let report = WeekReport.make(week: week, status: status, history: history, truncated: false, asOf: Self.eight)
        #expect(report.causes.count == 2)
        #expect(
            report.text(zone: "Asia/Gaza") == """
                Warm-up weekly report (read 2026-11-12 08:00 Asia/Gaza)
                1 of 6 scheduled warm-ups confirmed · 6–12 Nov
                Dates: 2026-11-06 to 2026-11-12
                Also: 1 uncertain; 1 with problems; 3 missed; 1 skipped by your pause or account selection, not counted.
                Missed because: nothing ran at that minute ×2, Router needed a review ×1.
                1 manual account result.
                Cause codes: no_tick_between ×2, compatibility_blocked ×1
                Account 1: 3 confirmed of 3 sent
                Account 2: 1 confirmed of 1 sent
                """)
    }

    /// Order 133: the week's causes in one line under the headline.
    @Test func causeLineCountsCausesAndRecordedSleep() throws {
        func ledger(_ rows: [(String, String)]) throws -> EngineStatus {
            try self.status {
                $0["slotLedger"] = rows.map { slot, cause in
                    [
                        "slot": slot, "admission": String(slot.suffix(5)), "cause": cause, "zone": "Asia/Gaza",
                        "at": Self.eight,
                    ]
                }
                $0["lastSlotOutcome"] = NSNull()
                $0["activeBatch"] = NSNull()
            }
        }
        func report(_ status: EngineStatus, asleep: Set<String> = []) -> WeekReport {
            let week = WeekSummary.make(today: "2026-11-12", status: status, history: [])
            return WeekReport.make(
                week: week, status: status, history: [], truncated: false, asOf: Self.eight, asleepSlots: asleep)
        }
        // No causes (an operator's own pause does not count): no line.
        let none = report(try ledger([("2026-11-10T18:00", "schedule_disabled")]))
        #expect(none.causeLine == nil)
        let one = report(try ledger([("2026-11-11T13:00", "compatibility_blocked")]))
        #expect(one.causeLine == "1 missed: Router needed a review ×1.")
        let two = try ledger([
            ("2026-11-10T08:00", "compatibility_blocked"), ("2026-11-10T13:00", "no_tick_between"),
            ("2026-11-11T13:00", "no_tick_between"), ("2026-11-11T08:00", "no_tick_between"),
        ])
        // Ordered by count; the leading number is their sum.
        #expect(report(two).causeLine == "4 missed: nothing ran at that minute ×3, Router needed a review ×1.")
        // The bracket only on "nothing ran", only above zero, and a blocked slot's sleep is not counted.
        let asleep = report(two, asleep: ["2026-11-10T13:00", "2026-11-11T13:00", "2026-11-10T08:00"])
        #expect(asleep.asleepNoTick == 2)
        #expect(
            asleep.causeLine
                == "4 missed: nothing ran at that minute ×3 (at least 2 while the Mac was recorded asleep), Router "
                + "needed a review ×1."
        )
        // Work order 137: the sleep journal covers only time the app ran, so the count is a lower bound.
        #expect(asleep.causeLine?.contains("(at least 2 while") == true)
        let blockedAsleep = report(
            try ledger([("2026-11-11T13:00", "compatibility_blocked")]), asleep: ["2026-11-11T13:00"])
        #expect(blockedAsleep.causeLine == "1 missed: Router needed a review ×1.")
        for line in [one.causeLine, report(two).causeLine, asleep.causeLine].compactMap({ $0 }) {
            #expect(!line.contains("because"))
            #expect(!line.contains("_"))
        }
        // The copied text still has its "Missed because" line and no new cause line.
        let text = asleep.text(zone: "Asia/Gaza")
        #expect(text.contains("Missed because: nothing ran at that minute ×3, Router needed a review ×1."))
        #expect(!text.contains("recorded asleep"))
        #expect(!asleep.details.contains { $0.contains("Missed because") })
    }

    @Test func scopedOverrideNamesItsInstantAndNeedsTheFeature() throws {
        let id = "install_ui_fixture_01"
        let scoped = EngineCommand.runAll(allowSlotOverlap: true, overlapAt: Self.eight)
        #expect(
            try scoped.arguments(installationId: id) == [
                "run", "--allow-slot-overlap", "--overlap-at", String(Self.eight), "--expected-installation-id", id,
            ])
        #expect(scoped.requiredFeatures.contains("scoped_slot_overlap"))
        #expect(!EngineCommand.runAll(allowSlotOverlap: true).requiredFeatures.contains("scoped_slot_overlap"))
        let account = WarmupAction.runAccount(enrollmentId: "enr_01", allowSlotOverlap: true, overlapAt: Self.eight)
            .command
        #expect(try account.arguments(installationId: id).contains(String(Self.eight)))
        for bad in [
            EngineCommand.runAll(allowSlotOverlap: false, overlapAt: Self.eight),
            .runAll(allowSlotOverlap: true, overlapAt: -1),
            .runAccount(enrollmentId: "enr_01", allowSlotOverlap: true, overlapAt: 42),
        ] {
            #expect(throws: CommandError.self) { try bad.arguments(installationId: id) }
        }
        // A moved admission or the other fall-back occurrence has another instant: the offer is withdrawn.
        let overlap = OverlapSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: Self.eight)
        let same = NextSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: Self.eight)
        let repeated = NextSlot(
            slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: Self.eight + 3_600_000)
        #expect(OverlapOverride.stillApplies(overlap, next: same))
        #expect(!OverlapOverride.stillApplies(overlap, next: repeated))
    }

    @Test func ledgerInstantUsesTheRecordedMinuteAndRefusesAmbiguousOnes() {
        func row(_ slot: String, _ admission: String, _ zone: String) -> LedgerRow {
            LedgerRow(slot: slot, admission: admission, cause: "no_tick_between", zone: zone, at: 0)
        }
        // A moved admission (13:00 slot recorded at 13:05) uses the recorded minute and zone.
        #expect(LedgerInstant.admissionAt(row("2026-11-12T08:00", "08:00", "Asia/Gaza")) == Self.eight)
        #expect(
            LedgerInstant.admissionAt(row("2026-11-12T13:00", "13:05", "UTC")) == Self.eight + (7 * 60 + 5)
                * Self.minute)
        // New York fall-back 01:30 happens twice; spring-forward 02:30 never happens: no instant.
        #expect(LedgerInstant.admissionAt(row("2026-11-01T01:30", "01:30", "America/New_York")) == nil)
        #expect(LedgerInstant.admissionAt(row("2027-03-14T02:30", "02:30", "America/New_York")) == nil)
        #expect(LedgerInstant.admissionAt(row("2026-11-12T08:00", "08:00", "Mars/Base")) == nil)
        // Lord Howe's 30-minute fall-back repeats 01:45 on 2026-04-05.
        #expect(LedgerInstant.admissionAt(row("2026-04-05T01:45", "01:45", "Australia/Lord_Howe")) == nil)
        // Troll (Antarctica) falls back two hours: 01:30 on 2026-10-25 happens twice.
        #expect(LedgerInstant.admissionAt(row("2026-10-25T01:30", "01:30", "Antarctica/Troll")) == nil)
    }

    @Test func weekReportStatesReadTimeAndLedgerCoverage() throws {
        let rows: [[String: Any]] = (0..<50).map { index in
            let day = 6 + index % 7
            return [
                "slot": String(format: "2026-11-%02dT%02d:00", day, index / 7),
                "admission": String(format: "%02d:00", index / 7),
                "cause": "no_tick_between", "zone": "Asia/Gaza", "at": Self.eight,
            ]
        }
        let status = try self.status {
            $0["slotLedger"] = rows
            $0["lastSlotOutcome"] = NSNull()
        }
        let week = WeekSummary.make(today: "2026-11-12", status: status, history: [])
        let report = WeekReport.make(week: week, status: status, history: [], truncated: false, asOf: Self.eight)
        #expect(report.ledgerMayBeCut)
        #expect(report.details.contains { $0.hasPrefix("The missed list reached its 50-row limit") })
        #expect(report.readTime(zone: "Asia/Gaza") == "Read at Thu 12 Nov 08:00 (Asia/Gaza)")
        let few = try self.status { $0["slotLedger"] = Array(rows.prefix(3)) }
        #expect(!WeekReport.make(week: week, status: few, history: [], truncated: false, asOf: 0).ledgerMayBeCut)
    }

    @Test func aLatestBatchThatSentNothingReadsLikeItsHistory() throws {
        let slot = "2026-11-12T08:00"
        let status = try self.status {
            $0["lastSlotOutcome"] = [
                "slot": slot, "zone": "Asia/Gaza", "outcome": "partial", "at": Self.eight,
                "results": [
                    ["enrollmentId": "enr_a", "outcome": "blocked", "reason": "cooldown", "dispatched": false]
                ],
            ]
            $0["slotLedger"] = []
            $0["activeBatch"] = NSNull()
        }
        let skipped = HistoryEntry(
            enrollmentId: "enr_a", status: "skipped", reason: "cooldown", mode: "scheduled", slot: slot, at: Self.eight,
            dispatched: false)
        let day = WeekSummary.make(today: "2026-11-12", status: status, history: [skipped]).last
        #expect(day?.slots.first?.mark == .skipped)
        // Without matching history rows, the batch outcome still decides (a problem).
        let alone = WeekSummary.make(today: "2026-11-12", status: status, history: []).last
        #expect(alone?.slots.first?.mark == .problem)
        // A history that holds fewer rows than the batch has results does not decide the mark.
        let two = try self.status {
            $0["lastSlotOutcome"] = [
                "slot": slot, "zone": "Asia/Gaza", "outcome": "partial", "at": Self.eight,
                "results": [
                    ["enrollmentId": "enr_a", "outcome": "blocked", "reason": "cooldown", "dispatched": false],
                    ["enrollmentId": "enr_b", "outcome": "blocked", "reason": "protocol_failure", "dispatched": false],
                ],
            ]
            $0["slotLedger"] = []
            $0["activeBatch"] = NSNull()
        }
        #expect(
            WeekSummary.make(today: "2026-11-12", status: two, history: [skipped]).last?.slots.first?.mark == .problem)
    }

    @Test func usageTruncationDecodes() throws {
        #expect(try self.status().usageTruncated == false)
        #expect(try self.status { $0["usageTruncated"] = true }.usageTruncated == true)
    }

    @Test func aBatchWhoseResultsAreAllSkippedIsSkippedWithoutHistory() throws {
        let results = (0..<51).map { _ in
            ["enrollmentId": "enr_x", "outcome": "blocked", "reason": "cooldown", "dispatched": false, "skipped": true]
                as [String: Any]
        }
        let status = try self.status {
            $0["lastSlotOutcome"] = [
                "slot": "2026-11-12T08:00", "zone": "Asia/Gaza", "outcome": "partial", "at": Self.eight,
                "results": results,
            ]
            $0["slotLedger"] = []
            $0["activeBatch"] = NSNull()
        }
        #expect(WeekSummary.make(today: "2026-11-12", status: status, history: []).last?.slots.first?.mark == .skipped)
    }

    @Test func aBatchTheEngineStoppedIsAProblemEvenWhenEveryRowIsASkip() throws {
        let results = (0..<51).map { _ in
            [
                "enrollmentId": "enr_x", "outcome": "blocked", "reason": "reader_global_block", "dispatched": false,
                "skipped": true,
            ]
                as [String: Any]
        }
        let status = try self.status {
            $0["lastSlotOutcome"] = [
                "slot": "2026-11-12T08:00", "zone": "Asia/Gaza", "outcome": "blocked", "at": Self.eight,
                "results": results,
            ]
            $0["slotLedger"] = []
            $0["activeBatch"] = NSNull()
        }
        #expect(WeekSummary.make(today: "2026-11-12", status: status, history: []).last?.slots.first?.mark == .problem)
    }

    @Test func aBlockedBatchWithSuccessfulRowsIsStillAProblem() {
        let ok = AccountResult(
            enrollmentId: "enr_a", outcome: "success", reason: "marker_confirmed", dispatched: true, at: 1)
        #expect(WeekSummary.mark(outcome: "blocked", results: [ok]) == .problem)
    }
}
