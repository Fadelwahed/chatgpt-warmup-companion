import Foundation
import Testing

@testable import WarmupCore

/// The UI/UX pass: friendly times, plain reasons, the verdict line, the background refresh plan,
/// the unseen-problem state and the health checks.
@Suite struct UX {
    func status(_ edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    @Test func friendlyTimesUseRelativeDaysThenShortDates() {
        #expect(FriendlyTime.slot("2026-11-12T08:00", today: "2026-11-12") == "Today 08:00")
        #expect(FriendlyTime.slot("2026-11-11T18:00", today: "2026-11-12") == "Yesterday 18:00")
        #expect(FriendlyTime.slot("2026-11-13T08:00", today: "2026-11-12") == "Tomorrow 08:00")
        #expect(FriendlyTime.slot("2026-11-09T13:00", today: "2026-11-12") == "Mon 9 Nov 13:00")
        #expect(FriendlyTime.slot("2026-12-31T23:00", today: "2027-01-01") == "Yesterday 23:00", "across a year")
        #expect(FriendlyTime.slotShort("2026-11-11T18:00", today: "2026-11-12") == "18:00 yesterday")
        #expect(FriendlyTime.time("08:00", on: "2026-11-13", today: "2026-11-12") == "08:00 tomorrow")
        #expect(FriendlyTime.slot("garbage", today: "2026-11-12") == "garbage")
        // 2026-11-12 06:00Z is 08:00 in Asia/Gaza; "now" is later the same local day.
        let now = Date(timeIntervalSince1970: 1_794_470_400)  // 2026-11-12 10:00Z
        #expect(FriendlyTime.instant(1_794_463_200_000, now: now, zone: "Asia/Gaza") == "Today 08:00")
    }

    @Test func everyLedgerCauseHasPlainWordsAndUnknownCodesFallBack() {
        let causes = [
            "zone_changed", "schedule_disabled", "compatibility_blocked", "recovery_skip_through", "clock_hold",
            "manual_run_overlap", "no_tick_between", "schedule_spacing", "no_scheduled_accounts",
        ]
        for cause in causes { #expect(Wording.reason(cause) != Wording.code(cause), "\(cause) has plain words") }
        #expect(Wording.reason("something_new") == "something new")
    }

    @Test func lastSlotSentenceCountsWhatMatters() throws {
        let three: [[String: Any]] = (1...3).map {
            ["enrollmentId": "enr_\($0)", "outcome": "success", "reason": "marker_confirmed", "dispatched": true]
        }
        func outcome(_ results: [[String: Any]], _ value: String = "success") throws -> SlotOutcome {
            try #require(
                try self.status {
                    $0["lastSlotOutcome"] = [
                        "slot": "2026-11-12T08:00", "zone": "Asia/Gaza", "outcome": value, "at": 1, "results": results,
                    ]
                }.lastSlotOutcome)
        }
        #expect(LastSlotText.outcome(try outcome(three), today: "2026-11-12") == "08:00 today: all 3 confirmed")
        var mixed = three
        mixed[2]["outcome"] = "uncertain"
        #expect(
            LastSlotText.outcome(try outcome(mixed, "partial"), today: "2026-11-12")
                == "08:00 today: 2 of 3 confirmed, 1 unknown")
        let capped: [[String: Any]] = [
            [
                "enrollmentId": "enr_1", "outcome": "blocked", "reason": "daily_cap_reached", "dispatched": false,
                "skipped": true,
            ]
        ]
        #expect(
            LastSlotText.outcome(try outcome(capped, "partial"), today: "2026-11-12")
                == "08:00 today: skipped (daily limit reached)")
        #expect(
            LastSlotText.outcome(try outcome(three, "blocked"), today: "2026-11-12") == "08:00 today: did not complete")
    }

    @Test func refreshPlanReadsAfterTheNextSlotOtherwiseEveryFifteenMinutes() throws {
        let status = try self.status()
        let at = try #require(status.next?.at)
        #expect(RefreshPlan.delay(nowMilliseconds: at - 600_000, status: status) == 720)  // 10 min before + 2 min
        #expect(RefreshPlan.delay(nowMilliseconds: at - 86_400_000, status: status) == RefreshPlan.regular)
        #expect(RefreshPlan.delay(nowMilliseconds: at + 110_000, status: status) == 30, "never sooner than 30 s")
        #expect(RefreshPlan.delay(nowMilliseconds: at + 200_000, status: status) == RefreshPlan.regular, "already past")
        #expect(RefreshPlan.delay(nowMilliseconds: 0, status: nil) == RefreshPlan.retry)
        let running = try self.status {
            $0["activeBatch"] = [
                "slot": "2026-11-12T08:00", "enrollmentIds": ["enr_a"], "zone": "Asia/Gaza", "state": "running",
            ]
        }
        #expect(
            RefreshPlan.delay(nowMilliseconds: at - 86_400_000, status: running) == RefreshPlan.retry,
            "a running batch is rechecked soon")
        #expect(Wording.reason("already_reserved") == "already reserved; not sent again")
        #expect(
            RefreshPlan.delay(nowMilliseconds: 0, status: try self.status { $0["next"] = NSNull() })
                == RefreshPlan.regular)
    }

    @Test func aMissedSlotFlagsTheIconUntilItIsOpened() throws {
        let missed = try self.status {
            $0["slotLedger"] = [
                [
                    "slot": "2026-11-12T08:00", "admission": "08:00", "verdict": "not_admitted",
                    "cause": "no_tick_between",
                    "zone": "Asia/Gaza", "at": 1,
                ]
            ]
        }
        let glance = GlanceBuilder.make(status: missed, today: "2026-11-12", macZone: "Asia/Gaza")
        #expect(glance.state == .attention)
        #expect(glance.symbolName == GlanceState.unseenProblemSymbol)
        #expect(glance.headline == "Needs a look: 08:00 today")
        #expect(glance.unseenProblemSlot == "2026-11-12T08:00")
        #expect(glance.notes.first?.hasPrefix("Next ") == true)
        let seen = GlanceBuilder.make(
            status: missed, today: "2026-11-12", macZone: "Asia/Gaza", acknowledgedSlot: "2026-11-12T08:00")
        #expect(seen.state == .scheduled)
        #expect(seen.unseenProblemSlot == nil)
        // A slot skipped by the operator's own choice is not a problem.
        let chosen = try self.status {
            $0["slotLedger"] = [
                [
                    "slot": "2026-11-12T08:00", "admission": "08:00", "verdict": "not_admitted",
                    "cause": "no_scheduled_accounts",
                    "zone": "Asia/Gaza", "at": 1,
                ]
            ]
        }
        #expect(GlanceBuilder.make(status: chosen, today: "2026-11-12", macZone: "Asia/Gaza").state == .scheduled)
    }

    @Test func statesThatNeedTheOperatorCarryOneLineOfAdvice() throws {
        let unloaded = GlanceBuilder.make(
            status: try self.status { $0["job"] = "absent" }, today: nil, macZone: "Asia/Gaza")
        #expect(unloaded.notes.first == "Pause and resume scheduling to start the background job again.")
        let blocked = GlanceBuilder.make(
            status: try self.status { $0["compatibility"] = "blocked" }, today: nil, macZone: "Asia/Gaza")
        #expect(blocked.notes.first?.hasPrefix("codex-router changed, usually after Update or Restart") == true)
        #expect(blocked.notes.first?.contains("repin-router") == true)
        #expect(blocked.notes.first?.contains("/") == false)
        #expect(
            Wording.guidance("review_source_compatibility")
                == "codex-router changed. Run repin-router from the Warm-up repository; scheduled warm-ups resume "
                + "after that.")
        let fine = GlanceBuilder.make(status: try self.status(), today: "2026-11-12", macZone: "Asia/Gaza")
        #expect(fine.notes.isEmpty)
    }

    @Test func scheduleWordsRangesAndClockTimes() throws {
        #expect(Wording.admission(state: "upcoming", cause: nil) == "upcoming")
        #expect(
            Wording.admission(state: "not_admitted", cause: "no_tick_between") == "missed: nothing ran at that minute")
        #expect(
            Wording.admission(state: "not_admitted", cause: "schedule_disabled") == "skipped: scheduling was paused")
        #expect(Wording.verdictSymbol("admitted") != Wording.verdictSymbol("not_admitted"))
        #expect(VacationText.range(start: "2026-12-01", end: "2026-12-05") == "1–5 Dec (5 days)")
        #expect(VacationText.range(start: "2026-11-30", end: "2026-12-02") == "30 Nov – 2 Dec (3 days)")
        #expect(VacationText.range(start: "2026-12-01", end: "2026-12-01") == "1 Dec (1 day)")
        let gaza = try #require(TimeZone(identifier: "Asia/Gaza"))
        let picked = try #require(ClockTime.date(from: "21:05", zone: gaza))
        #expect(ClockTime.string(from: picked, zone: gaza) == "21:05", "24-hour text whatever the Mac's clock setting")
        // The editor's picker works in UTC on a fixed day, so a time inside a spring-forward gap still exists.
        let gap = try #require(ClockTime.date(from: "02:30", zone: ClockTime.utc, now: Date(timeIntervalSince1970: 0)))
        #expect(ClockTime.string(from: gap, zone: ClockTime.utc) == "02:30")
    }

    @Test func eachAccountGetsOneReadinessPhrase() throws {
        func row(_ state: String, reason: String = "eligible", eligible: Bool = true, pilot: Bool = true) throws
            -> AccountRow
        {
            let json: [String: Any] = [
                "routerAccountId": "router_a", "enrollmentId": NSNull(), "registryReason": reason,
                "enrollmentState": state,
                "eligible": eligible, "enabled": state == "enabled", "pilot": pilot, "lastOutcome": "success",
                "lastReason": "marker_confirmed", "lastAt": 1_794_463_200_000,
            ]
            return try JSONDecoder().decode(AccountRow.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(AccountText.readiness(try row("enabled")) == "Ready")
        #expect(AccountText.readiness(try row("enabled", pilot: false)) == "Needs a first manual warm-up")
        #expect(AccountText.readiness(try row("enabled", reason: "identity_unknown")) == "Router sign-in needed")
        #expect(AccountText.readiness(try row("not_enrolled")) == "Not added yet")
        #expect(AccountText.readiness(try row("disabled")) == "Turned off")
        #expect(!AccountText.needsLook(try row("enabled")))
        #expect(AccountText.needsLook(try row("enabled", reason: "revoked")))
        let now = Date(timeIntervalSince1970: 1_794_470_400)
        #expect(AccountText.last(try row("enabled"), zone: "Asia/Gaza", now: now) == "Confirmed · Today 08:00")
    }

    @Test func aProposalMarksWhatItAddsAndRemoves() throws {
        func day(_ date: String, _ times: [String]) throws -> ProjectedDay {
            let admissions: [[String: Any]] = times.map {
                ["slot": "\(date)T\($0)", "logicalTime": $0, "admission": $0, "state": "upcoming"]
            }
            let json: [String: Any] = [
                "date": date, "weekday": 4, "source": "recurring", "exclusion": NSNull(), "admissions": admissions,
                "attemptsPerAccount": times.count, "configuredAttempts": times.count,
            ]
            return try JSONDecoder().decode(ProjectedDay.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let current = [try day("2026-11-13", ["08:00", "13:00"])]
        let proposed = [try day("2026-11-13", ["08:00", "21:05"])]
        #expect(ProposalDiff.added(current: current, proposed: proposed) == ["2026-11-13|21:05"])
        #expect(ProposalDiff.removed(current: current, proposed: proposed) == ["2026-11-13": ["13:00"]])
    }

    @Test func aProposalReplyCarriesItsOwnBaseline() throws {
        let reply = try #require(
            ReplyValidator.payload(ProposalReply.self, from: try Fixture.output("proposal-workweek-saved-shape")))
        #expect(reply.days?.isEmpty == false, "the current days come in the same reply as the proposal")
    }

    @Test func aStoppedBatchIsNamedInItsDetail() throws {
        let stopped = try self.status { $0["blockedSlots"] = [["slot": "2026-11-12T08:00", "at": 1]] }
        #expect(
            BatchNote.text(status: stopped, slot: "2026-11-12T08:00")?.hasPrefix("The engine stopped this batch")
                == true)
        #expect(BatchNote.text(status: stopped, slot: "2026-11-12T13:00") == nil)
        let partial = try self.status {
            $0["lastSlotOutcome"] = [
                "slot": "2026-11-12T13:00", "zone": "Asia/Gaza", "outcome": "partial", "at": 1, "results": [],
            ]
        }
        #expect(
            BatchNote.text(status: partial, slot: "2026-11-12T13:00")?.hasPrefix("This batch finished with problems")
                == true)
    }

    @Test func healthCollapsesWhenEverythingPasses() throws {
        let observed = 1_794_470_400_000
        let fine = try self.status { $0["lastTick"] = observed - 30_000 }
        let rows = HealthCheck.rows(
            status: fine, observedAt: observed, wake: .notScheduled, nextLocalAdmission: "08:00")
        #expect(HealthCheck.allFine(rows))
        #expect(HealthCheck.summary(rows) == "All checks pass")
        #expect(rows.first { $0.title == "Mac wake" }?.level == .info, "a missing wake never blocks the collapse")
        let unloaded = try self.status {
            $0["job"] = "absent"; $0["compatibility"] = "blocked"
        }
        let bad = HealthCheck.rows(status: unloaded, observedAt: observed, wake: .unknown, nextLocalAdmission: nil)
        #expect(!HealthCheck.allFine(bad))
        #expect(HealthCheck.summary(bad) == "2 checks need a look")
        let paused = try self.status {
            $0["job"] = "absent"; $0["scheduleEnabled"] = false
        }
        #expect(
            HealthCheck.rows(status: paused, observedAt: observed, wake: .unknown, nextLocalAdmission: nil)
                .first { $0.title == "Background job" }?.level == .info)
        #expect(SetupCard.needed(alertsAnswered: true, loginAnswered: false, alertsOn: false, loginOn: false))
        #expect(!SetupCard.needed(alertsAnswered: true, loginAnswered: true, alertsOn: false, loginOn: false))
    }
}

/// App 0.7.0: an opened problem today keeps the headline honest, and Health counts the week.
@Suite struct TodayProblems {
    static let today = "2026-11-12"

    static func ledger(_ slot: String, cause: String = "no_tick_between") -> [String: Any] {
        [
            "slot": slot, "admission": String(slot.suffix(5)), "verdict": "not_admitted", "cause": cause,
            "zone": "Asia/Gaza", "at": 1_794_463_200_000 - 3_600_000,
        ]
    }

    func status(_ edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    func missedAt0100(_ edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try self.status {
            $0["slotLedger"] = [Self.ledger("2026-11-12T01:00")]
            edit?(&$0)
        }
    }

    func glance(_ status: EngineStatus, today: String? = Self.today, acknowledged: String? = nil) -> Glance {
        GlanceBuilder.make(status: status, today: today, macZone: "Asia/Gaza", acknowledgedSlot: acknowledged)
    }

    @Test func noProblemTodayStaysAllGood() throws {
        let glance = self.glance(try self.status())
        #expect(glance.headline == "All good · next 08:00")
        #expect(glance.todayNote == nil)
        #expect(glance.symbolName == "clock")
        #expect(GlanceBuilder.problemsToday(try self.status(), today: Self.today).isEmpty)
    }

    @Test func unseenProblemStillNeedsALook() throws {
        let glance = self.glance(try self.missedAt0100())
        #expect(glance.state == .attention)
        #expect(glance.headline.hasPrefix("Needs a look: "))
        #expect(glance.todayNote == nil)
        #expect(glance.symbolName == GlanceState.unseenProblemSymbol)
    }

    @Test func openedMissTodaySaysNextAndCountsIt() throws {
        let glance = self.glance(try self.missedAt0100(), acknowledged: "2026-11-12T01:00")
        #expect(glance.state == .scheduled)
        #expect(glance.headline == "Next 08:00")
        #expect(glance.todayNote == "1 missed today")
        #expect(glance.symbolName == GlanceState.todayProblemSymbol)
        #expect(glance.symbolName != GlanceState.unseenProblemSymbol)
        #expect(glance.unseenProblemSlot == nil)
        #expect(glance.notes.isEmpty)
        #expect(HeroText.headline(glance) == "Next 08:00 · 1 missed today")
        #expect(HeroText.when(glance) == nil)
        // The headline names the next time, so the line below it is the countdown alone.
        #expect(HeroText.next(glance, countdown: "in 2 h") == "in 2 h")
        #expect(HeroText.next(glance, countdown: nil) == nil)
    }

    /// Status keeps only the latest batch: an earlier batch today that finished with a problem comes
    /// from the history the app has loaded (autoreview 131 round 1).
    @Test func anEarlierBatchProblemTodayComesFromHistory() throws {
        let status = try self.status {
            $0["lastSlotOutcome"] = [
                "slot": "2026-11-12T05:00", "zone": "Asia/Gaza", "outcome": "success", "at": 9_000, "results": [],
            ]
        }
        let earlier = HistoryEntry(
            enrollmentId: "enr_01", status: "failure", reason: "run_complete", mode: "scheduled",
            slot: "2026-11-12T01:00", at: 5_000, dispatched: true)
        #expect(GlanceBuilder.problemsToday(status, today: Self.today).isEmpty)
        #expect(GlanceBuilder.problemsToday(status, today: Self.today, history: [earlier]).count == 1)
        let glance = GlanceBuilder.make(
            status: status, today: Self.today, macZone: "Asia/Gaza", history: [earlier])
        #expect(glance.headline == "Next 08:00")
        #expect(glance.todayNote == "1 not confirmed today")
        #expect(glance.state == .scheduled)
    }

    @Test func aBatchProblemIsNotConfirmedRatherThanMissed() throws {
        let status = try self.missedAt0100 {
            $0["lastSlotOutcome"] = [
                "slot": "2026-11-12T05:00", "zone": "Asia/Gaza", "outcome": "partial", "at": 1, "results": [],
            ]
        }
        let glance = self.glance(status, acknowledged: "2026-11-12T05:00")
        #expect(glance.headline == "Next 08:00")
        #expect(glance.todayNote == "2 not confirmed today")
        #expect(GlanceBuilder.problemsToday(status, today: Self.today).count == 2)
    }

    @Test func aPausedDaySkipIsNoProblem() throws {
        let status = try self.status {
            $0["slotLedger"] = [Self.ledger("2026-11-12T01:00", cause: "schedule_disabled")]
        }
        let glance = self.glance(status)
        #expect(glance.headline == "All good · next 08:00")
        #expect(glance.todayNote == nil)
    }

    @Test func anOpenedMissYesterdayIsNotToday() throws {
        let status = try self.status { $0["slotLedger"] = [Self.ledger("2026-11-11T18:00")] }
        let glance = self.glance(status, acknowledged: "2026-11-11T18:00")
        #expect(glance.headline == "All good · next 08:00")
        #expect(glance.todayNote == nil)
        #expect(glance.symbolName == "clock")
    }

    @Test func withoutTodayNothingChanges() throws {
        let status = try self.missedAt0100()
        let glance = self.glance(status, today: nil, acknowledged: "2026-11-12T01:00")
        #expect(glance.state == .scheduled)
        #expect(glance.headline.hasPrefix("All good · next "))
        #expect(glance.todayNote == nil)
        #expect(GlanceBuilder.problemsToday(status, today: nil).isEmpty)
    }

    @Test func higherStatesKeepTheirHeadline() throws {
        let opened = "2026-11-12T01:00"
        let blocked = self.glance(try self.missedAt0100 { $0["compatibility"] = "blocked" }, acknowledged: opened)
        #expect(blocked.headline == "Blocked: Router needs a review")
        #expect(blocked.todayNote == nil)
        let paused = self.glance(try self.missedAt0100 { $0["scheduleEnabled"] = false }, acknowledged: opened)
        #expect(paused.headline == "Paused")
        #expect(paused.todayNote == nil)
        let held = self.glance(
            try self.missedAt0100 { $0["clockHold"] = ["lastWall": 1, "highWater": NSNull()] }, acknowledged: opened)
        #expect(held.headline == "Held: the clock moved backward")
        #expect(held.todayNote == nil)
    }

    static func week(
        confirmed: Int, slots: Int, skippedByChoice: Int = 0, truncated: Bool = false, ledgerMayBeCut: Bool = false
    ) -> WeekReport {
        WeekReport(
            firstDate: "2026-11-06", lastDate: "2026-11-12", days: 7, slots: slots, confirmed: confirmed,
            uncertain: 0, problems: 0, missed: slots - skippedByChoice - confirmed, skippedByChoice: skippedByChoice,
            notSent: 0, manual: 0, causes: [], accounts: [], truncated: truncated, ledgerMayBeCut: ledgerMayBeCut,
            asOf: 0)
    }

    @Test func healthCountsTheLastSevenDays() throws {
        let observed = 1_794_470_400_000
        let fine = try self.status { $0["lastTick"] = observed - 30_000 }
        func rows(_ week: WeekReport?) -> [HealthRow] {
            HealthCheck.rows(
                status: fine, observedAt: observed, wake: .notScheduled, nextLocalAdmission: "08:00", week: week)
        }
        #expect(!rows(nil).contains { $0.title == "Last 7 days" })
        let poor = rows(Self.week(confirmed: 4, slots: 18))
        let row = try #require(poor.first { $0.title == "Last 7 days" })
        #expect(row.value == "4 of 18 confirmed")
        #expect(row.level == .warning)
        let accounts = try #require(poor.firstIndex { $0.title == "Accounts" })
        #expect(poor[accounts + 1].title == "Last 7 days", "right after Accounts")
        #expect(HealthCheck.collapsed(poor) == "Last 7 days: 4 of 18 confirmed")
        #expect(HealthCheck.summary(poor) == "1 check needs a look")
        let half = rows(Self.week(confirmed: 9, slots: 18))
        #expect(half.first { $0.title == "Last 7 days" }?.level == .ok)
        #expect(HealthCheck.collapsed(half) == "All checks pass")
        // Skips by choice are not counted.
        let choice = rows(Self.week(confirmed: 4, slots: 20, skippedByChoice: 2))
        #expect(choice.first { $0.title == "Last 7 days" }?.value == "4 of 18 confirmed")
        #expect(!rows(Self.week(confirmed: 0, slots: 0)).contains { $0.title == "Last 7 days" })
        // Cut records are never graded as a pass (autoreview 131 round 1).
        let cuts = [
            Self.week(confirmed: 9, slots: 18, truncated: true),
            Self.week(confirmed: 9, slots: 18, ledgerMayBeCut: true),
        ]
        for cut in cuts {
            let partial = try #require(rows(cut).first { $0.title == "Last 7 days" })
            #expect(partial.value == "9 of 18 confirmed (records incomplete)")
            #expect(partial.level == .info)
        }
        let poorAndCut = rows(Self.week(confirmed: 4, slots: 18, truncated: true))
        #expect(poorAndCut.first { $0.title == "Last 7 days" }?.level == .warning)
        #expect(!rows(Self.week(confirmed: 0, slots: 3, skippedByChoice: 3)).contains { $0.title == "Last 7 days" })
    }
}
