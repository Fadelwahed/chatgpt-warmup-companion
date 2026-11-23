import Foundation
import Testing
@testable import WarmupCore

/// A3 opt-in alerts and the stale-heartbeat indicator, on engine-generated fixtures.
@Suite struct HeartbeatIndicator {
    /// status-enabled was observed at 2026-11-12T04:00:00Z; status-paused at 19:00:00Z.
    static let observed = 1_794_510_000_000 // 2026-11-12T19:00:00Z

    func status(_ name: String = "status-enabled", edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output(name, edit: edit)))
    }

    @Test func observedAtParses() {
        #expect(HeartbeatCheck.milliseconds(iso8601: "2026-11-12T19:00:00.000Z") == Self.observed)
        #expect(HeartbeatCheck.milliseconds(iso8601: "2026-11-12T19:00:00Z") == Self.observed)
        #expect(HeartbeatCheck.milliseconds(iso8601: "x") == nil)
    }

    @Test func staleOnlyPastTwoMinutesWhileScheduling() throws {
        let fresh = try self.status { $0["lastTick"] = Self.observed - 120_000 }
        #expect(HeartbeatCheck.staleSince(fresh, observedAt: Self.observed) == nil)
        let stale = try self.status { $0["lastTick"] = Self.observed - 121_000 }
        #expect(HeartbeatCheck.staleSince(stale, observedAt: Self.observed) == Self.observed - 121_000)
        // Unknown is not stale: no tick yet, or no readable observation time.
        #expect(HeartbeatCheck.staleSince(try self.status(), observedAt: Self.observed) == nil)
        #expect(HeartbeatCheck.staleSince(stale, observedAt: nil) == nil)
        // A tick later than the observation (clock skew) is not stale.
        let ahead = try self.status { $0["lastTick"] = Self.observed + 600_000 }
        #expect(HeartbeatCheck.staleSince(ahead, observedAt: Self.observed) == nil)
        // Paused or an unloaded job is reported by its own state, not as a stale heartbeat.
        let paused = try self.status { $0["lastTick"] = Self.observed - 600_000; $0["scheduleEnabled"] = false }
        #expect(HeartbeatCheck.staleSince(paused, observedAt: Self.observed) == nil)
        let unloaded = try self.status { $0["lastTick"] = Self.observed - 600_000; $0["job"] = "absent" }
        #expect(HeartbeatCheck.staleSince(unloaded, observedAt: Self.observed) == nil)
    }

    @Test func glanceShowsStaleHeartbeatWithoutCause() throws {
        let stale = try self.status { $0["lastTick"] = Self.observed - 121_000 }
        let glance = GlanceBuilder.make(
            status: stale, today: "2026-11-12", observedAt: Self.observed, macZone: "Asia/Gaza")
        #expect(glance.state == .attention)
        #expect(glance.headline == "No check-in since 20:57")  // Asia/Gaza, UTC+2
        #expect(glance.symbolName == GlanceState.staleHeartbeatSymbol)
        #expect(glance.notes.first == "Next 08:00")
        for text in [glance.headline] + glance.notes {
            #expect(!text.lowercased().contains("sleep"))
            #expect(!text.lowercased().contains("asleep"))
        }
        let yesterday = try self.status { $0["lastTick"] = Self.observed - 86_400_000 }
        let late = GlanceBuilder.make(status: yesterday, today: nil, observedAt: Self.observed)
        #expect(late.headline == "No check-in since 21:00 yesterday")
        // Without an observation time the existing behavior is unchanged.
        #expect(GlanceBuilder.make(status: stale, today: "2026-11-12").state == .scheduled)
        // A fresh heartbeat keeps the next-slot headline.
        let fresh = try self.status { $0["lastTick"] = Self.observed - 30_000 }
        let fine = GlanceBuilder.make(status: fresh, today: "2026-11-12", observedAt: Self.observed, macZone: "Asia/Gaza")
        #expect(fine.headline == "All good · next 08:00")
        #expect(GlanceBuilder.make(status: fresh, today: "2026-11-12", observedAt: Self.observed).symbolName == "clock")
    }

    @Test func higherPriorityStatesAreNotReplaced() throws {
        let tick = Self.observed - 600_000
        let blocked = try self.status { $0["lastTick"] = tick; $0["compatibility"] = "blocked" }
        #expect(GlanceBuilder.make(status: blocked, today: nil, observedAt: Self.observed).state == .blocked)
        let running = try self.status { $0["lastTick"] = tick; $0["activeBatch"] = ["slot": "2026-11-12T18:00", "enrollmentIds": ["enr_01"], "state": "running"] }
        #expect(GlanceBuilder.make(status: running, today: nil, observedAt: Self.observed).state == .running)
        let none = try self.status { $0["lastTick"] = tick; $0["next"] = NSNull() }
        #expect(GlanceBuilder.make(status: none, today: nil, observedAt: Self.observed).state == .attention)
    }
}

@Suite struct ProblemAlerts {
    static let installation = "install_ui_fixture_01"

    func status(_ name: String = "status-enabled", edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output(name, edit: edit)))
    }

    static func ledger(_ slot: String, cause: String = "no_tick_between") -> [String: Any] {
        ["slot": slot, "admission": String(slot.suffix(5)), "verdict": "not_admitted", "cause": cause, "zone": "Asia/Gaza", "at": 1_794_510_000_000,
         "evidence": ["previousTick": 1_794_481_205_000, "tick": 1_794_510_000_000, "previousZone": "Asia/Gaza"]]
    }

    @Test func problemsComeFromRecordedEvidenceOnly() throws {
        let paused = try self.status("status-paused")
        #expect(SlotProblem.from(paused) == [
            SlotProblem(slot: "2026-11-12T13:00", kind: .batch(outcome: "partial", sent: 0, confirmed: 0, unknown: 2), at: 1_794_481_205_000),
            SlotProblem(slot: "2026-11-12T18:00", kind: .notAdmitted(cause: "no_tick_between"), at: 1_794_510_000_000),
        ])
        // An idle batch (no account enabled) is the operator's configuration, not a problem.
        let idle = try self.status { $0["lastSlotOutcome"] = ["slot": "2026-11-12T08:00", "outcome": "idle", "at": 1, "results": []] }
        #expect(SlotProblem.from(idle).isEmpty)
        // One problem per slot; a finished batch outranks a ledger row for the same slot.
        let both = try self.status {
            $0["slotLedger"] = [Self.ledger("2026-11-12T08:00")]
            $0["lastSlotOutcome"] = ["slot": "2026-11-12T08:00", "outcome": "blocked", "at": 5, "results": []]
        }
        #expect(SlotProblem.from(both) == [SlotProblem(slot: "2026-11-12T08:00", kind: .batch(outcome: "blocked", sent: 0, confirmed: 0, unknown: 0), at: 5)])
        // An unobserved minute is not a problem until the engine records it.
        let unobserved = try self.status { $0["slotObservation"] = ["slot": "2026-11-12T08:00", "observation": "unobserved", "asOf": 1] }
        #expect(SlotProblem.from(unobserved).isEmpty)
        // A successful batch is not a problem.
        let success = try self.status { $0["lastSlotOutcome"] = ["slot": "2026-11-12T08:00", "outcome": "success", "at": 1, "results": []] }
        #expect(SlotProblem.from(success).isEmpty)
        // Operator-chosen skips are not problems.
        let chosen = try self.status { $0["slotLedger"] = [Self.ledger("2026-11-12T08:00", cause: "schedule_disabled"), Self.ledger("2026-11-12T13:00", cause: "recovery_skip_through")] }
        #expect(SlotProblem.from(chosen).isEmpty)
    }

    @Test func firstObservationIsTheBaseline() throws {
        var tracker = AlertTracker()
        #expect(!tracker.hasBaseline)
        #expect(tracker.observe(installation: Self.installation, status: try self.status("status-paused")).isEmpty)
        #expect(tracker.hasBaseline)
        // The same problems seen again stay silent.
        #expect(tracker.observe(installation: Self.installation, status: try self.status("status-paused")).isEmpty)
    }

    @Test func newProblemsAlertOncePerInstallationAndSlot() throws {
        var tracker = AlertTracker()
        _ = tracker.observe(installation: Self.installation, status: try self.status())
        let missed = try self.status { $0["slotLedger"] = [Self.ledger("2026-11-12T08:00")] }
        #expect(tracker.observe(installation: Self.installation, status: missed).map(\.slot) == ["2026-11-12T08:00"])
        #expect(tracker.observe(installation: Self.installation, status: missed).isEmpty)
        // The same logical slot later appearing as a batch outcome is not announced twice.
        let batch = try self.status {
            $0["slotLedger"] = [Self.ledger("2026-11-12T08:00")]
            $0["lastSlotOutcome"] = ["slot": "2026-11-12T08:00", "outcome": "partial", "at": 1, "results": []]
        }
        #expect(tracker.observe(installation: Self.installation, status: batch).isEmpty)
        // Several new slots at once arrive oldest first.
        let two = try self.status { $0["slotLedger"] = [Self.ledger("2026-11-12T18:00"), Self.ledger("2026-11-12T13:00"), Self.ledger("2026-11-12T08:00")] }
        #expect(tracker.observe(installation: Self.installation, status: two).map(\.slot) == ["2026-11-12T13:00", "2026-11-12T18:00"])
    }

    @Test func problemsAfterArmingSurviveAMissedBaselineRead() throws {
        var tracker = AlertTracker()
        // Alerts start at 18:30Z; the baseline read is skipped or fails. The first successful
        // read later still announces what was recorded after 18:30Z, and not what was before.
        tracker.arm(at: 1_794_508_200_000)
        let later = try self.status("status-paused") // 13:00 batch at 11:00Z, 18:00 miss recorded at 19:00Z
        #expect(tracker.observe(installation: Self.installation, status: later).map(\.slot) == ["2026-11-12T18:00"])
        #expect(tracker.observe(installation: Self.installation, status: later).isEmpty)
        // A problem that could not be shown is returned again, once.
        tracker.retain(SlotProblem.from(later).filter { $0.slot == "2026-11-12T18:00" })
        #expect(tracker.observe(installation: Self.installation, status: later).map(\.slot) == ["2026-11-12T18:00"])
        #expect(tracker.observe(installation: Self.installation, status: later).isEmpty)
        // A different installation is baselined whole, whatever the arm time.
        #expect(tracker.observe(installation: "install_other", status: later).isEmpty)
    }

    @Test func anotherInstallationOrResetRebaselines() throws {
        var tracker = AlertTracker()
        _ = tracker.observe(installation: Self.installation, status: try self.status())
        let missed = try self.status { $0["slotLedger"] = [Self.ledger("2026-11-12T08:00")] }
        #expect(tracker.observe(installation: "install_other", status: missed).isEmpty)
        tracker.reset()
        #expect(!tracker.hasBaseline)
        #expect(tracker.observe(installation: Self.installation, status: missed).isEmpty)
    }

    @Test func notificationTextIsRedactedAndStatesNoCause() throws {
        let problems = SlotProblem.from(try self.status("status-paused"))
        // Dates are absolute (060-FIX6 item 3): an alert delivered on a later day stays true.
        func compose(_ list: [SlotProblem], mac: String = "Europe/London") -> AlertContent? {
            AlertComposer.content(for: list, zone: "Asia/Gaza", macZone: mac)
        }
        let single = try #require(compose([problems[1]]))
        #expect(single.title == "The 18:00 warm-up was missed")
        #expect(single.body == "Thu 12 Nov 18:00 (Asia/Gaza). Nothing ran at that minute; the reason was not recorded.")
        #expect(single.slot == "2026-11-12T18:00")
        #expect(single.slots == ["2026-11-12T18:00"])
        #expect(single.identifier == "warmup.slot.2026-11-12T18:00")
        let home = try #require(compose([problems[1]], mac: "Asia/Gaza"))
        #expect(home.body.hasPrefix("Thu 12 Nov 18:00. "), "no zone at home")
        let batch = try #require(compose([problems[0]]))
        #expect(batch.title == "The 13:00 warm-up had problems")
        #expect(
            batch.body == "Thu 12 Nov 13:00 (Asia/Gaza). 0 sent, 0 confirmed, 2 unknown. Uncertain sends are not resent.")
        let both = try #require(compose(problems))
        #expect(both.title == "2 warm-ups need a look")
        #expect(both.body.hasPrefix("Thu 12 Nov 13:00, Thu 12 Nov 18:00 (Asia/Gaza). "))
        #expect(both.slot == "2026-11-12T18:00") // opens the newest
        #expect(both.slots == ["2026-11-12T13:00", "2026-11-12T18:00"])
        #expect(both.identifier == "warmup.slot.2026-11-12T13:00+2026-11-12T18:00")
        for content in [single, home, batch, both] {
            for relative in ["Today", "Yesterday", "Tomorrow"] { #expect(!content.body.contains(relative)) }
        }
        #expect(AlertComposer.content(for: [], zone: "Asia/Gaza") == nil)
        for content in [single, batch, both] {
            let text = (content.title + " " + content.body).lowercased()
            for forbidden in ["install_", "enr_", "res_", "router_", "sleep", "token"] { #expect(!text.contains(forbidden)) }
        }
        for cause in ["no_tick_between", "schedule_spacing", "zone_changed", "manual_run_overlap", "clock_hold", "compatibility_blocked", "other_code"] {
            #expect(!AlertComposer.cause(cause).lowercased().contains("sleep"))
        }
    }

    static func row(_ slot: String, _ status: String, at: Int, mode: String = "scheduled") -> HistoryEntry {
        HistoryEntry(
            enrollmentId: "enr_01", status: status, reason: "run_complete", mode: mode, slot: slot, at: at,
            dispatched: true)
    }

    static func outcome(_ slot: String, _ outcome: String = "success", at: Int) -> [String: Any] {
        ["slot": slot, "outcome": outcome, "at": at, "results": []]
    }

    static func reply(_ rows: [HistoryEntry], truncated: Bool = false, requestedAt: Int = 3_100_000) -> HistoryReply {
        HistoryReply(rows: rows, truncated: truncated, requestedAt: requestedAt)
    }

    /// Where a catch-up read starts for a start point: one batch length earlier.
    static func since(_ start: Int, _ status: EngineStatus) -> Int {
        max(0, start - AlertTracker.batchLookback(enrolled: status.enrolled))
    }

    @Test func batchesFinishedBetweenReadsComeFromHistory() throws {
        var tracker = AlertTracker()
        let first = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T03:00", at: 1_000_000) }
        _ = tracker.observe(installation: Self.installation, status: first)
        // Reads fail across an 08:00 failure and a 13:00 success; the next good read sees only 13:00.
        let later = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        #expect(tracker.historyNeeded(installation: Self.installation, status: later) == Self.since(1_000_000, later))
        // Without the history reply the gap stays open, so the next read asks again.
        #expect(tracker.observe(installation: Self.installation, status: later).isEmpty)
        #expect(tracker.historyNeeded(installation: Self.installation, status: later) == Self.since(1_000_000, later))
        let rows = [
            Self.row("2026-11-12T03:00", "failed", at: 990_000),  // covered by the earlier read
            Self.row("2026-11-12T08:00", "failed", at: 2_000_000),
            Self.row("2026-11-12T08:00", "uncertain", at: 2_000_001),
            Self.row("2026-11-12T09:30", "failed", at: 2_500_000, mode: "manual"),  // a manual run is not a slot
            Self.row("2026-11-12T13:00", "success", at: 2_999_000),
        ]
        let missed = SlotProblem(
            slot: "2026-11-12T08:00",
            kind: .batch(outcome: "partial", sent: 2, confirmed: 0, unknown: 1), at: 2_000_001)
        #expect(tracker.observe(installation: Self.installation, status: later, history: Self.reply(rows)) == [missed])
        // The gap is closed and the slot is not announced twice.
        #expect(tracker.historyNeeded(installation: Self.installation, status: later) == nil)
        #expect(tracker.observe(installation: Self.installation, status: later, history: Self.reply(rows)).isEmpty)
        // A different installation is baselined whole and needs no history.
        #expect(tracker.historyNeeded(installation: "install_other", status: later) == nil)
    }

    @Test func aFailedFirstHistoryReadIsRetried() throws {
        var tracker = AlertTracker()
        tracker.arm(at: 1_000_000)
        let status = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        // The first good status after arming needs history, and that read fails.
        #expect(tracker.observe(installation: Self.installation, status: status).isEmpty)
        #expect(tracker.hasBaseline)
        #expect(tracker.historyNeeded(installation: Self.installation, status: status) == Self.since(1_000_000, status))
        let rows = [Self.row("2026-11-12T08:00", "failed", at: 2_000_000)]
        let retried = tracker.observe(installation: Self.installation, status: status, history: Self.reply(rows))
        #expect(retried.map(\.slot) == ["2026-11-12T08:00"])
    }

    @Test func historyKeepsTheArmBaselineAndReadsAStraddlingBatchWhole() throws {
        var tracker = AlertTracker()
        tracker.arm(at: 1_000_000)
        let status = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        let since = tracker.historyNeeded(installation: Self.installation, status: status)
        #expect(since == Self.since(1_000_000, status))
        let rows = [
            Self.row("2026-11-12T03:00", "failed", at: 980_000),  // finished before alerts started
            Self.row("2026-11-12T08:00", "failed", at: 990_000),  // running when alerts started ...
            Self.row("2026-11-12T08:00", "success", at: 1_010_000),  // ... and finished after
            Self.row("2026-11-12T18:00", "failed", at: 3_100_000),  // still running after the latest outcome
        ]
        let fresh = tracker.observe(installation: Self.installation, status: status, history: Self.reply(rows))
        let straddling = SlotProblem(
            slot: "2026-11-12T08:00",
            kind: .batch(outcome: "partial", sent: 2, confirmed: 1, unknown: 0), at: 1_010_000)
        #expect(fresh == [straddling])
    }

    @Test func problemsThatCouldNotBeShownAreReturnedAgain() throws {
        var tracker = AlertTracker()
        _ = tracker.observe(
            installation: Self.installation,
            status: try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T03:00", at: 1_000_000) })
        let later = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        let rows = [Self.row("2026-11-12T08:00", "failed", at: 2_000_000)]
        let found = tracker.observe(installation: Self.installation, status: later, history: Self.reply(rows))
        #expect(found.map(\.slot) == ["2026-11-12T08:00"])
        // Permission was revoked before delivery: the history gap is closed, but the problem is kept.
        tracker.retain(found)
        #expect(tracker.historyNeeded(installation: Self.installation, status: later) == nil)
        #expect(tracker.observe(installation: Self.installation, status: later) == found)
        #expect(tracker.observe(installation: Self.installation, status: later).isEmpty)
    }

    @Test func incompleteHistoryCoverageIsNoticedOnce() throws {
        let later = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        func tracker() throws -> AlertTracker {
            var tracker = AlertTracker()
            let first = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T03:00", at: 1_000_000) }
            _ = tracker.observe(installation: Self.installation, status: first)
            return tracker
        }
        // A capped reply whose oldest batch finished after the start: that batch may be cut off,
        // so it is left out rather than reported with partial counts, and the notice is due.
        var capped = try tracker()
        let cut = [
            Self.row("2026-11-12T08:00", "failed", at: 2_000_000),
            Self.row("2026-11-12T10:00", "failed", at: 2_500_000),
        ]
        let cutReply = Self.reply(cut, truncated: true)
        let found = capped.observe(installation: Self.installation, status: later, history: cutReply)
        #expect(found.map(\.slot) == ["2026-11-12T10:00"])
        let notice1 = capped.takeIncompleteNotice()
        #expect(notice1)
        let notice2 = capped.takeIncompleteNotice()
        #expect(!notice2)
        // Capped, but only rows from before the start were dropped: nothing after it is missing.
        var covered = try tracker()
        let whole = [
            Self.row("2026-11-12T03:00", "success", at: 990_000),
            Self.row("2026-11-12T08:00", "failed", at: 2_000_000),
        ]
        let wholeReply = Self.reply(whole, truncated: true)
        let kept = covered.observe(installation: Self.installation, status: later, history: wholeReply)
        #expect(kept.map(\.slot) == ["2026-11-12T08:00"])
        let notice3 = covered.takeIncompleteNotice()
        #expect(!notice3)
        // The engine keeps 30 days before the request, so an older start is incomplete even when
        // the reply is neither capped nor non-empty.
        var old = try tracker()
        let late = Self.reply([], requestedAt: 1_000_000 + 31 * 86_400_000)
        #expect(old.observe(installation: Self.installation, status: later, history: late).isEmpty)
        let notice4 = old.takeIncompleteNotice()
        #expect(notice4)
        // A notice that could not be shown is kept for the next observation.
        old.retainIncompleteNotice()
        let notice5 = old.takeIncompleteNotice()
        #expect(notice5)
        let notice = try #require(AlertComposer.incompleteHistory(latestSlot: "2026-11-12T13:00"))
        #expect(notice.title == "Some earlier warm-ups could not be checked")
        #expect(notice.slot == "2026-11-12T13:00")
        #expect(AlertComposer.incompleteHistory(latestSlot: "bad") == nil)
    }

    /// 060-FIX3 item 4: while the incomplete-coverage notice is pending, the covered time stays at
    /// the gap's start, so a relaunch reads the gap again; a successful submission releases it.
    @Test func pendingIncompleteNoticeCapsCoveredThrough() throws {
        let later = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        var tracker = AlertTracker()
        let first = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T03:00", at: 1_000_000) }
        _ = tracker.observe(installation: Self.installation, status: first)
        let late = Self.reply([], requestedAt: 1_000_000 + 31 * 86_400_000)
        _ = tracker.observe(installation: Self.installation, status: later, history: late)
        let due = tracker.takeIncompleteNotice()
        #expect(due)
        #expect(tracker.coveredThrough == 1_000_000)
        // A failed submission keeps the notice and the cap; a relaunch arming there reads the gap again.
        tracker.retainIncompleteNotice()
        #expect(tracker.coveredThrough == 1_000_000)
        var relaunched = AlertTracker()
        relaunched.arm(at: tracker.coveredThrough)
        #expect(relaunched.historyNeeded(installation: Self.installation, status: later) != nil)
        // Even a later observation that covers more does not pass the gap until the notice is sent.
        _ = tracker.observe(installation: Self.installation, status: later)
        #expect(tracker.coveredThrough == 1_000_000)
        tracker.delivered(slots: [PendingAlert.noticeKey])
        #expect(tracker.coveredThrough == 3_000_000)
    }

    @Test func aManualRunAtTheCapProvesLaterBatchesWhole() throws {
        // Capped, and the oldest returned row is a manual run: runs never overlap, so the 08:00
        // batch after it is whole. It is judged normally and nothing is reported missing.
        let later = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        var tracker = AlertTracker()
        let first = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T03:00", at: 1_000_000) }
        _ = tracker.observe(installation: Self.installation, status: first)
        let rows = [
            Self.row("2026-11-12T05:00", "success", at: 950_000, mode: "manual"),
            Self.row("2026-11-12T08:00", "failed", at: 2_000_000),
        ]
        let capped = Self.reply(rows, truncated: true)
        let found = tracker.observe(installation: Self.installation, status: later, history: capped)
        #expect(found.map(\.slot) == ["2026-11-12T08:00"])
        let notice = tracker.takeIncompleteNotice()
        #expect(!notice)
    }

    @Test func aBatchStartingRightAfterTheCapIsLeftOut() throws {
        // Capped at a manual row, with a scheduled batch starting within one batch length of it:
        // if the wall clock stepped, rows of that batch could sit before the cap, so its counts are
        // not trusted. It is left out and the notice is due.
        let later = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        var tracker = AlertTracker()
        let first = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T03:00", at: 1_000_000) }
        _ = tracker.observe(installation: Self.installation, status: first)
        let rows = [
            Self.row("2026-11-12T08:00", "success", at: 1_950_000, mode: "manual"),
            Self.row("2026-11-12T08:00", "failed", at: 2_000_000),
        ]
        let capped = Self.reply(rows, truncated: true)
        #expect(tracker.observe(installation: Self.installation, status: later, history: capped).isEmpty)
        let notice = tracker.takeIncompleteNotice()
        #expect(notice)
    }

    @Test func theThirtyDayCutoffInsideTheLookbackDropsTheStraddlingBatch() throws {
        // Alerts started at 1,000,000 while the 08:00 batch was running. The read reaches back to
        // `since`, but the engine's cutoff (30 days before the request) lands between `since` and
        // the start: the batch's early rows may be pruned, so it is left out and noticed.
        let later = try self.status { $0["lastSlotOutcome"] = Self.outcome("2026-11-12T13:00", at: 3_000_000) }
        var tracker = AlertTracker()
        tracker.arm(at: 1_000_000)
        let since = try #require(tracker.historyNeeded(installation: Self.installation, status: later))
        let requestedAt = since + 100_000 + 30 * 86_400_000  // cutoff = since + 100 s, inside one batch of 08:00's row
        let rows = [Self.row("2026-11-12T08:00", "success", at: 1_020_000)]
        let found = tracker.observe(
            installation: Self.installation, status: later, history: Self.reply(rows, requestedAt: requestedAt))
        #expect(found.isEmpty)
        let notice = tracker.takeIncompleteNotice()
        #expect(notice)
        // A cutoff before `since` loses nothing the read asked for.
        var whole = AlertTracker()
        whole.arm(at: 1_000_000)
        let failedRow = Self.row("2026-11-12T08:00", "failed", at: 1_020_000)
        // The app estimates the engine's cutoff two minutes late, so stay clear of that margin.
        let early = Self.reply([failedRow], requestedAt: since - 1 - 120_000 + 30 * 86_400_000)
        let wholeFound = whole.observe(installation: Self.installation, status: later, history: early)
        #expect(wholeFound.map(\.slot) == ["2026-11-12T08:00"])
        let quiet = whole.takeIncompleteNotice()
        #expect(!quiet)
    }

    @Test func historySinceIsTheEngineForm() throws {
        let since = AlertTracker.historySince(1_794_510_000_001)
        #expect(since == "2026-11-12T19:00:00.001Z")
        let arguments = try EngineCommand.history(account: nil, since: since).arguments(installationId: nil)
        #expect(arguments == ["history", "--since", since])
    }

    @Test func unrecognizedEngineTextNeverReachesANotification() throws {
        let canary = "router_acct_canary_7f3"
        let failed = SlotProblem(
            slot: "2026-11-12T08:00", kind: .batch(outcome: canary, sent: 1, confirmed: 0, unknown: 0), at: 1)
        let batch = try #require(AlertComposer.content(for: [failed], zone: "Asia/Gaza"))
        #expect(batch.title == "The 08:00 warm-up did not complete")
        let missed = SlotProblem(slot: "2026-11-12T08:00", kind: .notAdmitted(cause: canary), at: 1)
        let ledger = try #require(AlertComposer.content(for: [missed], zone: canary))
        #expect(ledger.body == "Thu 12 Nov 08:00 (local time). It did not run. Open Warm-up to see the recorded reason.")
        for content in [batch, ledger] { #expect(!(content.title + content.body).contains("canary")) }
        // Slots and zones must be real, not just shaped like one.
        for slot in [canary, "2026-02-30T08:00", "2026-11-12T29:99"] {
            let bad = SlotProblem(slot: slot, kind: .notAdmitted(cause: "no_tick_between"), at: 1)
            #expect(AlertComposer.content(for: [bad], zone: "Asia/Gaza") == nil)
        }
        #expect(SlotProblem.isSlot("2026-03-27T00:30"))
        #expect(AlertComposer.isZone("Asia/Gaza") && AlertComposer.isZone("UTC") && !AlertComposer.isZone("Mars/Base"))
        #expect(AlertComposer.batchVerb("blocked") == "was blocked")
    }
}

/// App 0.6 F6: alerts arm from the stored `coveredThrough`, so a miss while the app was closed is
/// announced once after relaunch.
@Suite struct AlertRestart {
    static let installation = "install_ui_fixture_01"
    /// When the fixture ledger row below was recorded.
    static let miss = 1_794_510_000_000
    static let day = 86_400_000

    func status(edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    @Test func relaunchAfterAMissAnnouncesItOnce() throws {
        var before = AlertTracker()
        #expect(before.coveredThrough == nil)
        before.arm(at: Self.miss - 3_600_000)
        _ = before.observe(installation: Self.installation, status: try self.status())
        let stored = try #require(before.coveredThrough)
        #expect(stored < Self.miss)
        let missed = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger("2026-11-12T18:00")] }
        var relaunch = AlertTracker()
        relaunch.arm(at: AlertResume.start(stored: stored, now: Self.miss + 600_000))
        let announced = relaunch.observe(installation: Self.installation, status: missed)
        #expect(announced.map(\.slot) == ["2026-11-12T18:00"])
        let updated = try #require(relaunch.coveredThrough)
        #expect(updated >= Self.miss)
        var again = AlertTracker()
        again.arm(at: AlertResume.start(stored: updated, now: Self.miss + 1_200_000))
        let repeated = again.observe(installation: Self.installation, status: missed)
        #expect(repeated.isEmpty)
    }

    @Test func aProblemNotYetShownIsNotCovered() throws {
        let missed = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger("2026-11-12T18:00")] }
        var tracker = AlertTracker()
        tracker.arm(at: Self.miss - 3_600_000)
        let announced = tracker.observe(installation: Self.installation, status: missed)
        tracker.retain(announced)
        let covered = try #require(tracker.coveredThrough)
        #expect(covered < Self.miss)
    }

    /// 060-FIX1 item 4: a miss announced while the catch-up read failed is not repeated after a
    /// relaunch, and the retried catch-up still announces an older miss once.
    @Test func announcedSlotsSurviveAFailedCatchUp() throws {
        let installation = ProblemAlerts.installation
        let latest = try self.status {
            $0["lastSlotOutcome"] = ProblemAlerts.outcome("2026-11-12T13:00", "blocked", at: 3_000_000)
        }
        var before = AlertTracker()
        before.arm(at: 1_000_000)
        // The catch-up history read fails; the newest miss is still announced.
        let first = before.observe(installation: installation, status: latest)
        #expect(first.map(\.slot) == ["2026-11-12T13:00"])
        #expect(before.announced.isEmpty)  // seen, not yet accepted (060-FIX7 item 1)
        before.delivered(slots: first.map(\.slot))
        #expect(before.announced == ["2026-11-12T13:00"])
        let stored = try #require(before.coveredThrough)
        #expect(stored < 3_000_000)
        // Relaunch with the stored cursor and announced list: not announced again.
        var relaunch = AlertTracker()
        relaunch.arm(at: AlertResume.start(stored: stored, now: 3_100_000), announced: before.announced)
        #expect(relaunch.observe(installation: installation, status: latest).isEmpty)
        // The retried catch-up finds an older miss and announces it once.
        let since = try #require(relaunch.historyNeeded(installation: installation, status: latest))
        #expect(since == ProblemAlerts.since(1_000_000, latest))
        let rows = [ProblemAlerts.row("2026-11-12T08:00", "failed", at: 2_000_000)]
        let retried = relaunch.observe(installation: installation, status: latest, history: ProblemAlerts.reply(rows))
        #expect(retried.map(\.slot) == ["2026-11-12T08:00"])
        relaunch.delivered(slots: retried.map(\.slot))
        let again = relaunch.observe(installation: installation, status: latest, history: ProblemAlerts.reply(rows))
        #expect(again.isEmpty)
        #expect(relaunch.announced == ["2026-11-12T08:00", "2026-11-12T13:00"])
    }

    @Test func announcedSlotsLeaveOutUndeliveredAndKeepTheNewestThirty() throws {
        let missed = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger("2026-11-12T18:00")] }
        var tracker = AlertTracker()
        tracker.arm(at: Self.miss - 3_600_000)
        let announced = tracker.observe(installation: Self.installation, status: missed)
        tracker.retain(announced)
        #expect(tracker.announced.isEmpty)
        let many = (0..<40).map { String(format: "2026-11-%02dT%02d:00", $0 / 2 + 1, $0 % 2 == 0 ? 8 : 13) }
        var capped = AlertTracker()
        capped.arm(at: nil, announced: many.reversed())
        #expect(capped.announced == Array(many.suffix(30)))
    }

    @Test func storedValuesAreCapped() {
        let now = Self.miss
        #expect(AlertResume.start(stored: now - 9 * Self.day, now: now) == now - 7 * Self.day)
        #expect(AlertResume.start(stored: now - Self.day, now: now) == now - Self.day)
        #expect(AlertResume.start(stored: now + 1, now: now) == now)
        #expect(AlertResume.start(stored: nil, now: now) == now)
    }

    /// 060-FIX2 item 4: the arm time is stored at once, so a quit before the first observation
    /// still resumes from it and a miss in between is announced.
    @Test func armTimeIsStoredAtOnce() throws {
        let armedAt = AlertResume.start(stored: nil, now: Self.miss - 3_600_000)
        let initial = try #require(AlertResume.initialStore(stored: nil, armedAt: armedAt))
        #expect(initial == Self.miss - 3_600_000)
        #expect(AlertResume.initialStore(stored: initial, armedAt: armedAt) == nil)
        let missed = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger("2026-11-12T18:00")] }
        var relaunch = AlertTracker()
        relaunch.arm(at: AlertResume.start(stored: initial, now: Self.miss + 600_000))
        let announced = relaunch.observe(installation: Self.installation, status: missed)
        #expect(announced.map(\.slot) == ["2026-11-12T18:00"])
    }
}
