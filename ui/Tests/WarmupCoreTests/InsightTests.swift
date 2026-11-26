import Foundation
import Testing
@testable import WarmupCore

/// Read-only insights: countdown, redacted status diagnostic, the week strip and wake readiness.
@Suite struct Insights {
    func status(_ name: String = "status-enabled", edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus
    {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output(name, edit: edit)))
    }

    static func row(_ slot: String?, _ status: String, at: Int, mode: String = "scheduled") -> HistoryEntry {
        HistoryEntry(
            enrollmentId: "enr_01", status: status, reason: "run_complete", mode: mode, slot: slot, at: at,
            dispatched: true)
    }

    @Test func countdownNamesTheNextSlotInItsZone() throws {
        let next = NextSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: 1_794_463_200_000)
        let due = try #require(Countdown.date(of: next, zone: "Asia/Gaza"))
        #expect(due.timeIntervalSince1970 == 1_794_463_200)  // 06:00Z, UTC+2
        #expect(Countdown.phrase(from: due.addingTimeInterval(-45 * 60), to: due) == "in 45 min")
        #expect(Countdown.phrase(from: due.addingTimeInterval(-(2 * 3600 + 15 * 60)), to: due) == "in 2 h 15 min")
        #expect(Countdown.phrase(from: due.addingTimeInterval(-3 * 3600), to: due) == "in 3 h")
        #expect(Countdown.phrase(from: due.addingTimeInterval(-3 * 86_400), to: due) == "in 3 days")
        #expect(Countdown.phrase(from: due.addingTimeInterval(10), to: due) == "now")
        #expect(Countdown.compact(from: due.addingTimeInterval(-45 * 60), to: due) == "45m")
        #expect(Countdown.compact(from: due.addingTimeInterval(-(2 * 3600 + 15 * 60)), to: due) == "2h 15m")
        #expect(Countdown.compact(from: due.addingTimeInterval(-3 * 86_400), to: due) == "3d")
        #expect(Countdown.compact(from: due.addingTimeInterval(1), to: due) == "now")
        // Without the engine's epoch the local date and time are used; an unknown zone gives nil.
        let bare = NextSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: nil)
        #expect(Countdown.date(of: bare, zone: "Asia/Gaza") == due)
        #expect(Countdown.date(of: bare, zone: "Mars/Base") == nil)
    }

    @Test func statusDiagnosticIsRedacted() throws {
        let status = try self.status {
            $0["slotLedger"] = [
                [
                    "slot": "2026-11-12T08:00", "admission": "08:00", "verdict": "not_admitted",
                    "cause": "no_tick_between",
                    "zone": "Asia/Gaza", "at": 1_794_510_000_000,
                    "evidence": [
                        "previousTick": 1_794_481_205_000, "tick": 1_794_510_000_000, "previousZone": "Asia/Gaza",
                    ],
                ]
            ]
        }
        let text = StatusDiagnostic.text(
            status, engineVersion: "1.0.0-offline", appVersion: "0.2.0",
            observedAt: Date(timeIntervalSince1970: 1_794_510_000))
        #expect(text.hasPrefix("Warm-up status at 2026-11-12 21:00 (Asia/Gaza"))
        #expect(text.contains("Not admitted: 2026-11-12T08:00 no_tick_between"))
        #expect(text.contains("Engine: 1.0.0-offline; app: 0.2.0"))
        for forbidden in ["install_", "enr_", "res_", "router_", "token", "/Users/", ".mjs"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test func weekSummaryShowsOnlyRecordedEvidence() throws {
        let status = try self.status {
            $0["slotLedger"] = [
                [
                    "slot": "2026-11-11T13:00", "admission": "13:00", "verdict": "not_admitted",
                    "cause": "no_tick_between",
                    "zone": "Asia/Gaza", "at": 1_794_400_000_000,
                    "evidence": [
                        "previousTick": 1_794_300_000_000, "tick": 1_794_400_000_000, "previousZone": "Asia/Gaza",
                    ],
                ]
            ]
            $0["lastSlotOutcome"] = [
                "slot": "2026-11-12T08:00", "outcome": "partial", "at": 1_794_470_000_000, "results": [],
            ]
        }
        let history = [
            Self.row("2026-11-10T08:00", "success", at: 1_794_290_000_000),
            Self.row("2026-11-10T08:00", "success", at: 1_794_290_001_000),
            Self.row("2026-11-11T08:00", "success", at: 1_794_376_000_000),
            Self.row("2026-11-11T08:00", "uncertain", at: 1_794_376_001_000),
            Self.row(nil, "success", at: 1_794_380_000_000, mode: "manual"),
        ]
        let week = WeekSummary.make(today: "2026-11-12", status: status, history: history)
        #expect(
            week.map(\.date) == [
                "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12",
            ])
        #expect(week.last?.weekday == 4)  // Thursday
        #expect(week[4].slots == [WeekDay.Slot(date: "2026-11-10", time: "08:00", mark: .confirmed)])
        #expect(
            week[5].slots == [
                WeekDay.Slot(date: "2026-11-11", time: "08:00", mark: .uncertain),
                WeekDay.Slot(date: "2026-11-11", time: "13:00", mark: .missed),
            ])
        #expect(week[5].manualRuns == 1)
        #expect(week[6].slots == [WeekDay.Slot(date: "2026-11-12", time: "08:00", mark: .problem)])
        #expect(week[0].slots.isEmpty)
        #expect(
            week[5].spoken
                == "Wednesday 11 November: 08:00 uncertain, 13:00 missed, 1 manual account result.")
        #expect(week[0].spoken == "Friday 6 November: no scheduled warm-ups recorded.")
        #expect(WeekSummary.make(today: "bad", status: status, history: history).isEmpty)
    }

    @Test func aPartialOrRunningBatchIsNeverShownAsConfirmed() throws {
        // The oldest batch in a truncated history may have lost rows; a running batch is unfinished.
        let status = try self.status {
            $0["activeBatch"] = ["slot": "2026-11-12T08:00", "enrollmentIds": ["enr_a", "enr_b"], "state": "running"]
        }
        let history = [
            Self.row("2026-11-10T08:00", "success", at: 1_794_290_000_000),
            Self.row("2026-11-11T08:00", "success", at: 1_794_376_000_000),
            Self.row("2026-11-12T08:00", "success", at: 1_794_470_000_000),
        ]
        let full = WeekSummary.make(today: "2026-11-12", status: status, history: history)
        #expect(full[4].slots == [WeekDay.Slot(date: "2026-11-10", time: "08:00", mark: .confirmed)])
        #expect(full[6].slots == [WeekDay.Slot(date: "2026-11-12", time: "08:00", mark: .uncertain)])
        // A batch newer than the last outcome status reported started after the status read.
        let settled = try self.status {
            $0["lastSlotOutcome"] = [
                "slot": "2026-11-10T08:00", "outcome": "success", "at": 1_794_290_100_000, "results": [],
            ]
        }
        let raced = WeekSummary.make(today: "2026-11-12", status: settled, history: history)
        #expect(raced[4].slots == [WeekDay.Slot(date: "2026-11-10", time: "08:00", mark: .confirmed)])
        #expect(raced[5].slots == [WeekDay.Slot(date: "2026-11-11", time: "08:00", mark: .uncertain)])
        let cut = WeekSummary.make(today: "2026-11-12", status: status, history: history, truncated: true)
        #expect(cut[4].slots == [WeekDay.Slot(date: "2026-11-10", time: "08:00", mark: .uncertain)])
        #expect(cut[5].slots == [WeekDay.Slot(date: "2026-11-11", time: "08:00", mark: .confirmed)])
    }

    @Test func engineTextThatIsNotACodeIsWithheldFromTheSummary() {
        #expect(StatusDiagnostic.safe("no_tick_between") == "no_tick_between")
        #expect(StatusDiagnostic.safe("Asia/Gaza") == "Asia/Gaza")
        #expect(StatusDiagnostic.safe("2026-11-12T08:00") == "2026-11-12T08:00")
        #expect(StatusDiagnostic.safe("2.0.1") == "2.0.1")
        if NSUserName().count >= 3 { #expect(StatusDiagnostic.safe(NSUserName()) == "(withheld)") }
        #expect(StatusDiagnostic.safe("13:00") == "13:00")
        for leak in [
            "someone@example.com", "/Users/x/.codex", "two words", "", String(repeating: "a", count: 49), "acct_h9T",
            "enr_c41e", "install_x", "codex/auth.json", ".codex", "MyAccount", "Not/AZone", "success\n", "a b",
        ] {
            #expect(StatusDiagnostic.safe(leak) == "(withheld)")
        }
    }

    static let systemOnly = """
        Scheduled power events:
         [0]  wake at 11/21/2026 19:32:22 by 'com.apple.alarm.user-invisible-com.apple.calaccessd.travelEngine.periodicRefreshTimer'
         [1]  wake at 11/22/2026 07:54:58 by 'com.apple.alarm.user-invisible-com.apple.osanalytics.hardhighengagementtimer'
        """

    @Test func onlyOperatorWakesBeforeTheSlotCount() {
        // 2026-11-22 is a Sunday. A system maintenance wake at 07:54 does not count.
        #expect(WakeReadiness.assess(pmset: Self.systemOnly, date: "2026-11-22", admission: "08:00") == .notScheduled)
        let oneTime = Self.systemOnly + "\n [2]  wake at 11/22/2026 07:50:00 by 'pmset'"
        #expect(WakeReadiness.assess(pmset: oneTime, date: "2026-11-22", admission: "08:00") == .ready(wakeAt: "07:50"))
        // Too early (more than 30 minutes before) or after the slot does not help.
        let early = Self.systemOnly + "\n [2]  wake at 11/22/2026 07:00:00 by 'pmset'"
        #expect(WakeReadiness.assess(pmset: early, date: "2026-11-22", admission: "08:00") == .notScheduled)
        let weekdays = "Repeating power events:\n  wakepoweron at 7:55AM weekdays only\nScheduled power events:\n"
        #expect(
            WakeReadiness.assess(pmset: weekdays, date: "2026-11-23", admission: "08:00") == .ready(wakeAt: "07:55"))
        #expect(WakeReadiness.assess(pmset: weekdays, date: "2026-11-22", admission: "08:00") == .notScheduled)
        let everyDay = "Repeating power events:\n  wakeorpoweron at 12:55PM every day\n"
        #expect(
            WakeReadiness.assess(pmset: everyDay, date: "2026-11-22", admission: "13:00") == .ready(wakeAt: "12:55"))
        #expect(WakeReadiness.assess(pmset: "", date: "bad", admission: "08:00") == .unknown)
        // A one-time wake with a custom owner counts; only com.apple owners are excluded.
        let custom = Self.systemOnly + "\n [2]  wake at 11/22/2026 07:45:00 by 'warmup-wake'"
        #expect(WakeReadiness.assess(pmset: custom, date: "2026-11-22", admission: "08:00") == .ready(wakeAt: "07:45"))
        // Full day names: 2026-11-23 is a Monday.
        let monday = "Repeating power events:\n  wakepoweron at 7:55AM Monday\n"
        #expect(WakeReadiness.assess(pmset: monday, date: "2026-11-23", admission: "08:00") == .ready(wakeAt: "07:55"))
        #expect(WakeReadiness.assess(pmset: monday, date: "2026-11-24", admission: "08:00") == .notScheduled)
        let letters = "Repeating power events:\n  wakepoweron at 7:55AM MTW\n"
        #expect(WakeReadiness.assess(pmset: letters, date: "2026-11-25", admission: "08:00") == .ready(wakeAt: "07:55"))
        #expect(WakeReadiness.assess(pmset: letters, date: "2026-11-26", admission: "08:00") == .notScheduled)
        #expect(WakeReadiness.hasRepeating(pmset: letters))
        #expect(!WakeReadiness.hasRepeating(pmset: Self.systemOnly))
    }

    @Test func aWakeTheEveningBeforeCountsForASlotJustAfterMidnight() {
        // The suggested command for a 00:02 slot wakes at 23:57 the day before.
        let daily = "Repeating power events:\n  wakeorpoweron at 11:57PM every day\n"
        #expect(WakeReadiness.assess(pmset: daily, date: "2026-11-23", admission: "00:02") == .ready(wakeAt: "23:57"))
        let sundayOnly = "Repeating power events:\n  wakeorpoweron at 11:57PM Sunday\n"
        // Monday 00:02 is covered by Sunday 23:57; Tuesday 00:02 is not.
        #expect(
            WakeReadiness.assess(pmset: sundayOnly, date: "2026-11-23", admission: "00:02") == .ready(wakeAt: "23:57"))
        #expect(WakeReadiness.assess(pmset: sundayOnly, date: "2026-11-24", admission: "00:02") == .notScheduled)
        let oneTime = "Scheduled power events:\n [0]  wake at 11/22/2026 23:57:00 by 'pmset'"
        #expect(WakeReadiness.assess(pmset: oneTime, date: "2026-11-23", admission: "00:02") == .ready(wakeAt: "23:57"))
        #expect(
            WakeReadiness.suggestedCommand(admission: "08:00") == "sudo pmset repeat wakeorpoweron MTWRFSU 07:55:00")
        #expect(
            WakeReadiness.suggestedCommand(admission: "00:02") == "sudo pmset repeat wakeorpoweron MTWRFSU 23:57:00")
    }

    @Test func weekdayNamesAreSpokenInFull() {
        #expect(Wording.weekdayName(1) == "Monday")
        #expect(Wording.weekdayName(7) == "Sunday")
        #expect(Wording.weekdayName(9) == "Sunday")
    }
}

@Suite struct RunAnywayGuard {
    @Test func anOverrideOnlyAppliesToTheSlotItNamed() {
        let overlap = OverlapSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12")
        let same = NextSlot(slot: "2026-11-12T08:00", admission: "08:00", date: "2026-11-12", at: nil)
        let later = NextSlot(slot: "2026-11-12T13:00", admission: "13:00", date: "2026-11-12", at: nil)
        #expect(OverlapOverride.stillApplies(overlap, next: same))
        #expect(!OverlapOverride.stillApplies(overlap, next: later))
        #expect(!OverlapOverride.stillApplies(overlap, next: nil))
        // Same slot ID, but the admission moved: the operator must see a fresh warning.
        let moved = NextSlot(slot: "2026-11-12T08:00", admission: "08:30", date: "2026-11-12", at: nil)
        #expect(!OverlapOverride.stillApplies(overlap, next: moved))
    }

    /// 060-FIX2 item 5: the line under Last 7 days after a failed history read.
    @Test func staleWeekLineNamesTheLastGoodRead() {
        let readAt = 1_794_463_200_000 + 18_120_000  // 13:02 in Asia/Gaza
        let now = Date(timeIntervalSince1970: Double(readAt + 3_480_000) / 1000)
        #expect(
            WeekStaleText.line(readAt: readAt, now: now, zone: "Asia/Gaza")
                == "History could not be read; earlier days are from Today 13:02.")
    }

    /// 060-FIX3 item 3: the first failed history read still shows the strip from fresh status, and
    /// says history could not be read.
    @Test func firstFailedHistoryReadStillShowsTheWeek() throws {
        let status = try #require(
            ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled")))
        let week = WeekSummary.make(today: "2026-11-12", status: status, history: [])
        #expect(week.count == 7)
        #expect(week.last?.date == "2026-11-12")
        #expect(WeekStaleText.line(readAt: nil, zone: "Asia/Gaza") == "History could not be read.")
    }
}

/// Work order 132: one wake read for every coming time, its Schedule words and the Health value.
@Suite struct WakePlans {

    /// The host's `pmset -g sched` lines of 26 Nov 07:50 (work order 132), booked through 2 Dec.
    static let host = """
        Scheduled power events:
         [0]  wake at 11/26/2026 08:00:05 by 'warmup'
         [1]  wake at 11/26/2026 10:05:58 by 'com.apple.alarm.user-invisible-com.apple.calaccessd.travelEngine.periodicRefreshTimer'
         [3]  wake at 11/26/2026 13:10:05 by 'pmset'
         [4]  wake at 11/26/2026 13:10:05 by 'warmup'
         [24]  wake at 12/02/2026 18:20:05 by 'warmup'
        """

    static func admission(
        _ date: String, _ time: String, at: Int?, state: String = "upcoming", next: Bool? = nil
    ) -> ProjectedAdmission {
        ProjectedAdmission(
            slot: "\(date)T\(time)", logicalTime: time, admission: time, at: at, state: state, cause: nil,
            repeatedLocalTime: nil, next: next)
    }

    @Test func aWakeSecondsAfterTheMinuteCountsForThatMinute() {
        let line = "Scheduled power events:\n [0]  wake at 11/27/2026 08:00:05 by 'warmup'"
        #expect(WakeReadiness.assess(pmset: line, date: "2026-11-27", admission: "08:00") == .ready(wakeAt: "08:00"))
        #expect(WakeReadiness.assess(pmset: line, date: "2026-11-27", admission: "13:10") == .notScheduled)
    }

    @Test func onePlanAssessesEveryTimeAndFindsTheLastBookedDay() {
        let slots: [WakeReadiness.Slot] = [
            (id: "a", date: "2026-11-26", admission: "08:00"), (id: "b", date: "2026-11-26", admission: "13:10"),
            (id: "c", date: "2026-11-26", admission: "18:20"),
        ]
        let plan = WakeReadiness.plan(pmset: Self.host, slots: slots)
        #expect(plan.bySlot["a"] == .ready(wakeAt: "08:00"))
        #expect(plan.bySlot["b"] == .ready(wakeAt: "13:10"))
        #expect(plan.bySlot["c"] == .notScheduled)
        #expect(plan.isKnown)
        #expect(!plan.hasRepeating)
        #expect(plan.lastBookedDay == "2026-12-02")
        // A later system wake does not extend the bookings.
        let apple = Self.host + "\n [25]  wake at 12/05/2026 03:00:00 by 'com.apple.alarm.user-invisible-x'"
        #expect(WakeReadiness.plan(pmset: apple, slots: slots).lastBookedDay == "2026-12-02")
        let empty = WakeReadiness.plan(pmset: "", slots: slots)
        #expect(empty.lastBookedDay == nil)
        #expect(empty.isKnown)
        let repeating = "Repeating power events:\n  wakepoweron at 7:55AM every day\nScheduled power events:\n"
        let onlyRepeating = WakeReadiness.plan(pmset: repeating, slots: slots)
        #expect(onlyRepeating.hasRepeating)
        #expect(onlyRepeating.lastBookedDay == nil)
        #expect(onlyRepeating.bySlot["a"] == .ready(wakeAt: "07:55"))
        #expect(!WakePlan.unknown.isKnown)
        #expect(WakePlan.unknown.readiness("a") == .unknown)
        #expect(plan.readiness("missing") == .unknown)
    }

    @Test func theSlotListCoversNextAndEveryUpcomingTimeInMacLocalTime() throws {
        let gaza = try #require(TimeZone(identifier: "Asia/Gaza"))
        // 2026-11-26 06:00 UTC is 08:00 in Gaza (UTC+2).
        let eight = 1_795_672_800_000
        let next = NextSlot(slot: "2026-11-26T08:00", admission: "08:00", date: "2026-11-26", at: eight)
        let day = ProjectedDay(
            date: "2026-11-26", weekday: 4, source: "recurring", exclusion: nil,
            admissions: [
                Self.admission("2026-11-26", "01:00", at: eight - 7 * 3_600_000, state: "missed"),
                Self.admission("2026-11-26", "08:00", at: eight, state: "next", next: true),
                Self.admission("2026-11-26", "13:10", at: eight + 310 * 60_000),
                Self.admission("2026-11-26", "18:20", at: nil),
            ], attemptsPerAccount: 1, configuredAttempts: 1)
        let projection = ScheduleProjection(
            scheduleEnabled: true, scheduleRevision: 1, timeZoneMode: "local", weekdays: [], times: [],
            zoneNotice: nil, localDate: "2026-11-26", zone: "Asia/Gaza", accounts: [], days: [day], next: next)
        let slots = WakeReadiness.slots(next: next, scheduleZone: "Asia/Gaza", projection: projection, local: gaza)
        #expect(slots.map(\.id) == [WakeReadiness.nextKey, "2026-11-26T08:00#0", "2026-11-26T13:10#0"])
        #expect(slots.map(\.date) == ["2026-11-26", "2026-11-26", "2026-11-26"])
        #expect(slots.map(\.admission) == ["08:00", "08:00", "13:10"])
        // In UTC the same instants fall at 06:00 and 11:10.
        let utc = WakeReadiness.slots(next: next, scheduleZone: "Asia/Gaza", projection: projection, local: .gmt)
        #expect(utc.map(\.admission) == ["06:00", "06:00", "11:10"])
        // No projection: the next time only.
        let only = WakeReadiness.slots(next: next, scheduleZone: "Asia/Gaza", projection: nil, local: gaza)
        #expect(only.map(\.id) == [WakeReadiness.nextKey])
    }

    @Test func scheduleRowsSayWhetherAWakeIsBooked() {
        let now = 1_000
        let upcoming = Self.admission("2026-11-26", "13:10", at: 2_000)
        let past = Self.admission("2026-11-26", "08:00", at: 500, state: "confirmed")
        let booked = WakePlan(bySlot: [upcoming.id: .ready(wakeAt: "13:10")], lastBookedDay: nil, hasRepeating: false)
        let missing = WakePlan(bySlot: [upcoming.id: .notScheduled], lastBookedDay: nil, hasRepeating: false)
        #expect(ScheduleWakeText.row(admission: upcoming, plan: booked, now: now) == "wake booked")
        #expect(ScheduleWakeText.row(admission: upcoming, plan: missing, now: now) == "no wake")
        #expect(ScheduleWakeText.row(admission: past, plan: booked, now: now) == nil)
        #expect(ScheduleWakeText.row(admission: upcoming, plan: .unknown, now: now) == nil)
        // A time the read did not cover gets no mark, never "no wake".
        let other = WakePlan(bySlot: [:], lastBookedDay: nil, hasRepeating: false)
        #expect(ScheduleWakeText.row(admission: upcoming, plan: other, now: now) == nil)
    }

    @Test func comingDaysCountTheirBookedWakes() {
        let times = ["08:00", "13:10", "18:20"].map { Self.admission("2026-11-27", $0, at: 5_000) }
        func plan(_ ready: Int) -> WakePlan {
            var bySlot: [String: WakeReadiness] = [:]
            for (index, admission) in times.enumerated() {
                bySlot[admission.id] = index < ready ? .ready(wakeAt: admission.admission) : .notScheduled
            }
            return WakePlan(bySlot: bySlot, lastBookedDay: nil, hasRepeating: false)
        }
        #expect(ScheduleWakeText.day(times, plan: plan(3)) == "3 wakes booked")
        #expect(ScheduleWakeText.day(times, plan: plan(1)) == "1 of 3 wakes booked")
        #expect(ScheduleWakeText.day(times, plan: plan(0)) == "no wakes booked")
        #expect(ScheduleWakeText.day(Array(times.prefix(1)), plan: plan(1)) == "1 wake booked")
        #expect(ScheduleWakeText.day(times, plan: .unknown) == nil)
        #expect(ScheduleWakeText.day([], plan: plan(3)) == nil)
    }

    @Test func theSummaryLineSaysHowFarBookingsReach() {
        let booked = WakePlan(bySlot: [:], lastBookedDay: "2026-12-02", hasRepeating: false)
        #expect(ScheduleWakeText.summary(plan: booked, scheduleEnabled: true) == "Wakes booked through Wed 2 Dec.")
        let repeating = WakePlan(bySlot: ["a": .ready(wakeAt: "07:55")], lastBookedDay: nil, hasRepeating: true)
        #expect(ScheduleWakeText.summary(plan: repeating, scheduleEnabled: true) == "A repeating wake is set.")
        // A repeating event that wakes for no time (a repeating sleep, say) is not a wake.
        let sleepOnly = WakePlan(bySlot: ["a": .notScheduled], lastBookedDay: nil, hasRepeating: true)
        let none = "No wakes booked. A warm-up is missed if the Mac is asleep at its time."
        #expect(ScheduleWakeText.summary(plan: sleepOnly, scheduleEnabled: true) == none)
        let empty = WakePlan(bySlot: ["a": .notScheduled], lastBookedDay: nil, hasRepeating: false)
        #expect(ScheduleWakeText.summary(plan: empty, scheduleEnabled: true) == none)
        #expect(ScheduleWakeText.summary(plan: .unknown, scheduleEnabled: true) == nil)
        #expect(ScheduleWakeText.summary(plan: booked, scheduleEnabled: false) == nil)
        let texts = [booked, repeating, empty].compactMap { ScheduleWakeText.summary(plan: $0, scheduleEnabled: true) }
        #expect(Fixes051.offending(texts).isEmpty)
    }

    @Test func healthSaysAWakeIsBooked() throws {
        let status = try #require(
            ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled")))
        let rows = HealthCheck.rows(
            status: status, observedAt: nil, wake: .ready(wakeAt: "08:00"), nextLocalAdmission: "08:00")
        #expect(rows.first { $0.title == "Mac wake" }?.value == "booked for 08:00")
        let none = HealthCheck.rows(
            status: status, observedAt: nil, wake: .notScheduled, nextLocalAdmission: "08:00")
        let row = none.first { $0.title == "Mac wake" }
        #expect(row?.value == "none set before 08:00; the Mac must be awake")
        #expect(row?.level == .info)
    }
}

/// App 0.7.0: the week strip shows the minute a slot ran, and counts manual results in words.
@Suite struct WeekCells {
    @Test func cellShowsTheMovedMinute() {
        let slot = WeekDay.Slot(date: "2026-11-24", time: "13:00", mark: .confirmed)
        let moved = RunTimes(byLabel: ["2026-11-24T13:00": "13:10"])
        #expect(slot.shown(runs: moved) == "13:10")
        #expect(slot.id == "2026-11-24T13:00")
        // Moved for one day only: the next day's 13:00 keeps its time.
        #expect(WeekDay.Slot(date: "2026-11-25", time: "13:00", mark: .missed).shown(runs: moved) == "13:00")
        #expect(slot.shown(runs: .none) == "13:00")
    }

    @Test func manualResultsInWords() {
        func day(_ manual: Int) -> WeekDay {
            WeekDay(date: "2026-11-24", weekday: 2, slots: [], manualRuns: manual)
        }
        #expect(day(2).manualText == "+2 manual results")
        #expect(day(1).manualText == "+1 manual result")
        #expect(day(0).manualText == nil)
        #expect(WeekDay.manualLegend == "+N manual results: account results from manual warm-ups that day.")
    }
}
