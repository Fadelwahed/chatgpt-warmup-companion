import Foundation
import Testing
@testable import WarmupCore

/// App 0.7.0 (work order 133): a missed time's lines say what happened, whether it still applies and
/// what to do.
@Suite struct MissExplanationLines {
    static let sleep = "Warm-up recorded the Mac asleep from 06:40 to 08:45, which covers that minute."
    static let causes = [
        "compatibility_blocked", "no_tick_between", "schedule_disabled", "clock_hold", "schedule_spacing",
        "manual_run_overlap", "zone_changed", "no_scheduled_accounts", "recovery_skip_through", "brand_new_cause",
    ]

    /// Both current states: blocked, paused and held, or all clear.
    func lines(_ cause: String, now good: Bool, asleep: String? = nil, job: Bool? = nil) -> [String] {
        MissExplanation.lines(
            cause: cause, compatibility: good ? "ready" : "blocked", scheduleEnabled: good, clockHeld: !good,
            asleepNote: asleep, jobSeenAfterwards: job)
    }

    @Test func compatibilityBlockedSaysWhetherRouterIsStillBlocked() {
        let what = "codex-router had changed and needed a review, so this warm-up was skipped."
        #expect(
            self.lines("compatibility_blocked", now: true) == [what, "Router is compatible again.", "Nothing to do."])
        #expect(
            self.lines("compatibility_blocked", now: false) == [
                what, "Router still needs a review; scheduled warm-ups are skipped until then.",
                "Run repin-router from the Warm-up repository.",
            ])
    }

    @Test func nothingRanUsesTheSleepNoteAndKeepsTheJobHint() {
        let what = "Nothing ran at that minute; the reason was not recorded."
        let awake =
            "Keep the Mac awake at warm-up times. A booked wake works with the lid open, or closed while the Mac is "
            + "plugged in; on battery with the lid closed, the Mac sleeps again within seconds."
        for good in [true, false] {
            #expect(self.lines("no_tick_between", now: good) == [what, awake])
            #expect(self.lines("no_tick_between", now: good, asleep: Self.sleep) == [what, Self.sleep, awake])
            #expect(self.lines("no_tick_between", now: good, job: true) == [what, awake])
        }
        // The job was not seen afterwards: the existing hint to check the job stays as the "To do" line.
        #expect(
            self.lines("no_tick_between", now: true, job: false) == [
                what, Wording.guidance("check_job_and_mac_awake"),
            ])
        #expect(
            self.lines("no_tick_between", now: true, job: false).last
                == "No check-in was recorded at this minute. Check that the job is loaded; the cause is not recorded.")
    }

    /// Work order 137: a booked wake can fail with the lid closed, so the advice no longer offers it as
    /// the remedy on its own. Work order 140: it says what the lid-closed test showed, not "may".
    /// Work order 143: a closed lid works while the Mac is plugged in (27 Nov 08:00 check).
    @Test func nothingRanAdviceNamesTheLidNotJustBookedWakes() {
        for good in [true, false] {
            for job in [true, nil] as [Bool?] {
                let toDo = self.lines("no_tick_between", now: good, job: job).last ?? ""
                #expect(!toDo.contains("or book wakes"))
                #expect(toDo.contains("lid"))
                #expect(toDo.contains("plugged in"))
                #expect(toDo.contains("battery"))
                #expect(!toDo.contains("may"))
            }
        }
        #expect(
            self.lines("no_tick_between", now: true, job: false).last
                == Wording.guidance("check_job_and_mac_awake"))
    }

    @Test func pausedAndHeldSayWhetherTheyStillApply() {
        let paused = "Scheduling was paused at that time."
        #expect(self.lines("schedule_disabled", now: true) == [paused, "Scheduling is on again.", "Nothing to do."])
        #expect(
            self.lines("schedule_disabled", now: false) == [
                paused, "Scheduling is still paused.", "Resume scheduling when you want warm-ups again.",
            ])
        let held = "The Mac's clock had moved backward, so Warm-up waited."
        #expect(self.lines("clock_hold", now: true) == [held, "The clock has caught up.", "Nothing to do."])
        #expect(
            self.lines("clock_hold", now: false) == [
                held, "The clock is still behind its last reading.", "Check the Mac's date and time.",
            ])
    }

    @Test func causesWithoutAPresentStateGiveTwoLines() {
        let expected: [String: [String]] = [
            "schedule_spacing": [
                "It was too close to the previous warm-up.", "Edit Times shows advice when two times are too close.",
            ],
            "manual_run_overlap": ["A manual warm-up was running at that time.", "Nothing to do."],
            "zone_changed": ["The time zone had changed, so this time was skipped once.", "Nothing to do."],
            "no_scheduled_accounts": [
                "No account was chosen for scheduled warm-ups.", "Tick Scheduled for an account in Accounts.",
            ],
            "recovery_skip_through": ["Skipped while Warm-up was recovering.", "Nothing to do."],
        ]
        for (cause, lines) in expected {
            #expect(self.lines(cause, now: true) == lines)
            #expect(self.lines(cause, now: false) == lines)
        }
    }

    @Test func anUnknownCauseGivesOnePlainLine() {
        for good in [true, false] {
            #expect(self.lines("brand_new_cause", now: good) == ["Brand new cause."])
        }
    }

    @Test func noLineCarriesCodesOrInternalWords() {
        for cause in Self.causes {
            for good in [true, false] {
                for job in [true, false, nil] as [Bool?] {
                    for line in self.lines(cause, now: good, asleep: Self.sleep, job: job) {
                        for word in ["_", "/", "slot", "tick", "admission"] {
                            #expect(!line.contains(word), "\(cause): \(line)")
                        }
                    }
                }
            }
        }
        for seen in [true, false] {
            let line = MissExplanation.jobLine(seenAfterwards: seen, verdict: "not_admitted")
            #expect(line?.contains("check") == false)
        }
    }

    @Test func theJobLineIsOneSentence() {
        #expect(
            MissExplanation.jobLine(seenAfterwards: true, verdict: "admitted")
                == "Warm-up's background job was running afterwards.")
        let unseen = "Warm-up's background job was not seen running afterwards."
        #expect(MissExplanation.jobLine(seenAfterwards: false, verdict: "not_admitted") == unseen)
    }

    /// Work order 138 item 1: only a time whose minute has passed carries the job line.
    @Test func theJobLineIsOnlyForPastTimes() {
        let seen = "Warm-up's background job was running afterwards."
        let unseen = "Warm-up's background job was not seen running afterwards."
        for verdict in ["scheduled", "in_progress"] {
            #expect(MissExplanation.jobLine(seenAfterwards: false, verdict: verdict) == nil, "\(verdict)")
        }
        for verdict in ["admitted", "not_admitted", "unobserved", "unknown"] {
            #expect(MissExplanation.jobLine(seenAfterwards: true, verdict: verdict) == seen, "\(verdict)")
            #expect(MissExplanation.jobLine(seenAfterwards: false, verdict: verdict) == unseen, "\(verdict)")
        }
        let every = [
            "admitted", "not_admitted", "unobserved", "unknown", "scheduled", "in_progress", "excluded",
            "not_configured", "nonexistent_local_time", "brand_new",
        ]
        for verdict in every {
            #expect(MissExplanation.jobLine(seenAfterwards: nil, verdict: verdict) == nil, "\(verdict)")
        }
        for seenAfterwards in [true, false] {
            #expect(MissExplanation.jobLine(seenAfterwards: seenAfterwards, verdict: "brand_new") == nil)
        }
    }
}
