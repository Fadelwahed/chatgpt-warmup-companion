import Foundation

// App 0.7.0 (work order 133): a missed time explains itself in up to three plain lines: what
// happened, whether it still applies now, and what to do. Nothing here reads or sends.

public enum MissExplanation {
    static let nothingToDo = "Nothing to do."

    /// `compatibility`, `scheduleEnabled` and `clockHeld` are the current status; `asleepNote` is the
    /// app's sleep note for that minute; `jobSeenAfterwards` is whether the background job checked in
    /// after the minute (nil when not known).
    public static func lines(
        cause: String, compatibility: String, scheduleEnabled: Bool, clockHeld: Bool, asleepNote: String?,
        jobSeenAfterwards: Bool? = nil
    ) -> [String] {
        let ready = compatibility == "ready"
        switch cause {
        case "compatibility_blocked":
            return [
                "codex-router had changed and needed a review, so this warm-up was skipped.",
                ready
                    ? "Router is compatible again."
                    : "Router still needs a review; scheduled warm-ups are skipped until then.",
                ready ? Self.nothingToDo : "Review the change and re-pin codex-router.",
            ]
        case "no_tick_between":
            // Only a job not seen afterwards keeps the engine's hint to check the job. A booked wake can
            // last seconds with the lid closed on battery (work order 137), so it is not the whole remedy.
            let toDo =
                jobSeenAfterwards == false
                ? Wording.guidance("check_job_and_mac_awake")
                : "Keep the Mac awake at warm-up times. A booked wake helps when the lid is open; with the lid "
                    + "closed on battery it may be too short."
            let what = "Nothing ran at that minute; the reason was not recorded."
            return [what] + [asleepNote].compactMap { $0 } + [toDo]
        case "schedule_disabled":
            return [
                "Scheduling was paused at that time.",
                scheduleEnabled ? "Scheduling is on again." : "Scheduling is still paused.",
                scheduleEnabled ? Self.nothingToDo : "Resume scheduling when you want warm-ups again.",
            ]
        case "clock_hold":
            return [
                "The Mac's clock had moved backward, so Warm-up waited.",
                clockHeld ? "The clock is still behind its last reading." : "The clock has caught up.",
                clockHeld ? "Check the Mac's date and time." : Self.nothingToDo,
            ]
        case "schedule_spacing":
            return [
                "It was too close to the previous warm-up.", "Edit Times shows advice when two times are too close.",
            ]
        case "manual_run_overlap":
            return ["A manual warm-up was running at that time.", Self.nothingToDo]
        case "zone_changed":
            return ["The time zone had changed, so this time was skipped once.", Self.nothingToDo]
        case "no_scheduled_accounts":
            return ["No account was chosen for scheduled warm-ups.", "Tick Scheduled for an account in Accounts."]
        case "recovery_skip_through":
            return ["Skipped while Warm-up was recovering.", Self.nothingToDo]
        default:
            let reason = Wording.reason(cause)
            return [reason.prefix(1).uppercased() + reason.dropFirst() + "."]
        }
    }

    /// The sentence that replaces the "checked in afterwards" row.
    public static func jobLine(seenAfterwards: Bool) -> String {
        seenAfterwards
            ? "Warm-up's background job was running afterwards."
            : "Warm-up's background job was not seen running afterwards."
    }
}
