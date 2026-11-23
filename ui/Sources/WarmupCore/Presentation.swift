import Foundation

/// At-a-glance state for the menu. Each state has its own symbol and words, so it never
/// depends on color alone.
public enum GlanceState: String, Sendable, Equatable {
    case setupRequired, checking, unavailable, blocked, attention, paused, running, noUpcoming, scheduled

    public var symbolName: String {
        switch self {
        case .setupRequired: "wrench.and.screwdriver"
        case .checking: "ellipsis.circle"
        case .unavailable: "questionmark.circle"
        case .blocked: "exclamationmark.octagon"
        case .attention: "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .noUpcoming: "calendar.badge.exclamationmark"
        case .scheduled: "clock"
        }
    }

    /// No heartbeat while scheduling should be running.
    public static let staleHeartbeatSymbol = "heart.slash"
    /// The latest slot had a problem the operator has not opened yet.
    public static let unseenProblemSymbol = "exclamationmark.circle"
}

public struct Glance: Sendable, Equatable {
    public let state: GlanceState
    public let headline: String
    public let lastOutcome: String?
    public let lastOutcomeSlot: String?
    public let notes: [String]
    /// The state's symbol, or a more specific one (a stale heartbeat shares `.attention` with
    /// other conditions but should look different in the menu bar).
    public let symbolName: String
    /// The latest slot, when it had a problem the operator has not opened yet.
    public let unseenProblemSlot: String?
    /// Possible sends without a result, for the menu's attention line (never a hero note).
    public let unresolvedNote: String?

    init(
        state: GlanceState, headline: String, lastOutcome: String?, lastOutcomeSlot: String?, notes: [String],
        symbolName: String? = nil, unseenProblemSlot: String? = nil, unresolvedNote: String? = nil
    ) {
        self.state = state
        self.headline = headline
        self.lastOutcome = lastOutcome
        self.lastOutcomeSlot = lastOutcomeSlot
        self.notes = notes
        self.symbolName = symbolName ?? state.symbolName
        self.unseenProblemSlot = unseenProblemSlot
        self.unresolvedNote = unresolvedNote
    }
}

public enum Wording {
    public static let windowEffect = "Usage window effect unverified"

    public static func guidance(_ code: String) -> String {
        switch code {
        case "none": "No action needed."
        case "run_manual_pilot": "Run one manual warm-up for this account so it can be scheduled."
        case "review_account_block": "The account is blocked after a provider response. Review it before scheduling resumes."
        case "wait_for_cooldown": "The account is cooling down. It will be eligible again after the recorded time."
        case "review_source_compatibility": "Router source compatibility needs review before scheduled runs resume."
        case "reconcile_job_state": "The background job and the schedule setting disagree. Pause and resume scheduling."
        case "resume_schedule_if_intended": "Scheduling was paused. Resume it if that was not intended."
        case "check_job_and_mac_awake": "No check-in was recorded at this minute. Check that the job is loaded; the cause is not recorded."
        case "review_clock": "The clock moved unexpectedly. Review the Mac's time before relying on the schedule."
        case "review_time_zone": "The Mac's time zone changed. Review the schedule in the new zone."
        case "review_schedule_spacing": "This time was too close to the previous warm-up and was skipped."
        case "review_router_state": "Router reported this account as unavailable. Review it in Router."
        case "refresh_router_login": "Router's sign-in for this account needs attention."
        case "retry_after_router_login": "Router was signing in at the time. A later warm-up may succeed."
        case "check_network": "The request was not sent because the network was unavailable."
        case "outcome_unknown_no_resend": "The request may have been sent. Its outcome is unknown and it will not be resent for this time."
        case "review_unresolved_reservation": "A send may have started but no result was recorded."
        default: "Review the account history for details."
        }
    }

    public static func verdict(_ code: String) -> String {
        switch code {
        case "admitted": "Ran"
        case "in_progress": "Running now"
        case "not_admitted": "Missed"
        case "scheduled": "Upcoming"
        case "excluded": "Off: not a scheduled day"
        case "not_configured": "Not in the current schedule"
        case "nonexistent_local_time": "This time does not exist that day (clocks go forward)"
        case "unobserved": "No check-in was recorded at this minute; the reason is not known"
        default: "Unknown"
        }
    }

    public static func dispatch(_ code: String) -> String {
        switch code {
        case "confirmed": "Request sent"
        case "ruled_out": "Not sent"
        case "pending": "Waiting"
        default: "Unknown whether sent"
        }
    }

    public static func response(_ code: String) -> String {
        switch code {
        case "confirmed": "Response confirmed"
        case "uncertain": "Response uncertain"
        case "failed": "Error response"
        default: "No response observed"
        }
    }

    public static func weekday(_ iso: Int) -> String {
        ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][max(0, min(7, iso))]
    }

    public static func code(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ") }

    public static func workLock(_ state: String) -> String {
        switch state {
        case "free": "Free"
        case "held": "Held by a running engine process"
        case "stale": "Left by a stopped process (the engine clears it when it can)"
        default: "Owner unknown"
        }
    }
}

public enum GlanceBuilder {
    public static func setupRequired(_ issue: BindingIssue) -> Glance {
        Glance(state: .setupRequired, headline: issue.description, lastOutcome: nil, lastOutcomeSlot: nil, notes: [])
    }

    /// A verified binding exists but no status has been read yet (the app reads it at launch).
    public static func notChecked() -> Glance {
        Glance(state: .checking, headline: "Checking…", lastOutcome: nil, lastOutcomeSlot: nil, notes: [])
    }

    public static func unavailable(_ reason: String) -> Glance {
        Glance(
            state: .unavailable, headline: "Status unavailable: \(reason)", lastOutcome: nil, lastOutcomeSlot: nil,
            notes: ["Refresh to try again."])
    }

    /// UserDefaults key (app domain) holding the latest problem slot whose detail was opened. The app
    /// writes it; the CLI only reads it.
    public static let acknowledgedSlotKey = "acknowledgedProblemSlot"

    /// `observedAt` is the engine's observation time from the same reply, in milliseconds. It is
    /// needed to judge the heartbeat; without it the heartbeat is not flagged. `macZone` hides the
    /// zone when it is the Mac's own; `acknowledgedSlot` is the latest problem slot already opened.
    public static func make(
        status: EngineStatus, today: String?, observedAt: Int? = nil, macZone: String? = TimeZone.current.identifier,
        acknowledgedSlot: String? = nil
    ) -> Glance {
        let zone = status.schedule.zone
        let zoneSuffix = zone == macZone ? "" : " (\(zone))"
        // Possible sends without a result live in Needs attention and the menu, not in the hero.
        var notes: [String] = []
        var symbol: String?
        // One line of advice for states that need the operator; none guesses a cause.
        if status.compatibility != "ready" {
            notes.append("Scheduled warm-ups wait until Router's compatibility is reviewed.")
        } else if status.clockHold != nil {
            notes.append("Check the Mac's date and time. Scheduling resumes once the clock passes its last reading.")
        } else if status.scheduleEnabled, status.job != "loaded" {
            notes.append("Pause and resume scheduling to start the background job again.")
        }
        var (state, headline): (GlanceState, String) = {
            if status.compatibility != "ready" { return (.blocked, "Blocked: Router needs a review") }
            if status.clockHold != nil { return (.attention, "Held: the clock moved backward") }
            if !status.scheduleEnabled { return (.paused, "Paused") }
            if status.job != "loaded" { return (.attention, "Background job not running") }
            if let batch = status.activeBatch, batch.state == "running" { return (.running, "Warming up: \(batch.slot.suffix(5))") }
            guard let next = status.next else { return (.noUpcoming, "No warm-up in the next 7 days") }
            let when = next.date == today ? next.admission : FriendlyTime.time(next.admission, on: next.date, today: today)
            return (.scheduled, "All good · next \(when)\(zoneSuffix)")
        }()
        // A stale heartbeat outranks the next-slot line, which then moves to the notes. No cause
        // is stated: the job, the Mac or the engine may each explain it.
        var unseen: String?
        if state == .scheduled || state == .noUpcoming, let observedAt, let tick = HeartbeatCheck.staleSince(status, observedAt: observedAt) {
            notes.insert(Self.nextLine(headline), at: 0)
            state = .attention
            symbol = GlanceState.staleHeartbeatSymbol
            headline = HeartbeatCheck.headline(tick: tick, observedAt: observedAt, zone: zone)
        }
        let lastSlot = [status.lastSlotOutcome?.slot, status.slotLedger.first?.slot].compactMap { $0 }.max()
        // The latest slot had a problem not yet opened: say so until the operator looks.
        if state == .scheduled || state == .noUpcoming, let lastSlot, lastSlot != acknowledgedSlot,
            SlotProblem.from(status).contains(where: { $0.slot == lastSlot })
        {
            notes.insert(Self.nextLine(headline), at: 0)
            state = .attention
            symbol = GlanceState.unseenProblemSymbol
            headline = "Needs a look: \(FriendlyTime.slotShort(lastSlot, today: today))"
            unseen = lastSlot
        }
        // Engine 1.1 names what holds the work lock: the likeliest cause of a stopped heartbeat.
        if let lockNote = WorkLockCheck.note(status, observedAt: observedAt) {
            notes.insert(lockNote, at: state == .attention ? 0 : notes.count)
        }
        var last: String?
        let ledger = status.slotLedger.first
        let batchIsNewer = (status.lastSlotOutcome?.slot ?? "") >= (ledger?.slot ?? "")
        if let outcome = status.lastSlotOutcome, batchIsNewer {
            last = LastSlotText.outcome(outcome, today: today)
        } else if let ledger {
            last = LastSlotText.ledger(ledger, today: today)
        }
        return Glance(
            state: state, headline: headline, lastOutcome: last, lastOutcomeSlot: lastSlot, notes: notes, symbolName: symbol,
            unseenProblemSlot: unseen, unresolvedNote: status.unresolved.isEmpty ? nil : UnresolvedText.line(status))
    }

    /// "All good · next 13:00" becomes "Next 13:00" when another headline takes its place.
    static func nextLine(_ headline: String) -> String {
        headline.hasPrefix("All good · next ") ? "Next " + headline.dropFirst("All good · next ".count) : headline
    }
}

/// The Overview hero says the next time once: "All good" as the headline, then "Next warm-up 13:00,
/// in 2 h 15 min" below it. Other headlines stay as they are.
public enum HeroText {
    static let scheduledPrefix = "All good · next "

    public static func headline(_ glance: Glance) -> String {
        Self.when(glance) == nil ? glance.headline : "All good"
    }

    /// "Next warm-up 13:00, in 2 h 15 min" (or without the countdown), only while scheduled.
    public static func next(_ glance: Glance, countdown: String?) -> String? {
        guard let when = Self.when(glance) else { return nil }
        return countdown.map { "Next warm-up \(when), \($0)" } ?? "Next warm-up \(when)"
    }

    static func when(_ glance: Glance) -> String? {
        guard glance.state == .scheduled, glance.headline.hasPrefix(Self.scheduledPrefix) else { return nil }
        return String(glance.headline.dropFirst(Self.scheduledPrefix.count))
    }
}

/// The version row in Settings: "Warm-up 0.5.1 (6) · Engine 1.2.0". A build without bundle values
/// says "dev"; the engine part is left out until a status read names it.
public enum VersionText {
    public static func line(appVersion: String?, build: String?, engineVersion: String?) -> String {
        let app = Self.present(appVersion) ?? "dev"
        var text = "Warm-up \(app)"
        if Self.present(appVersion) != nil, let build = Self.present(build) { text += " (\(build))" }
        if let engine = Self.present(engineVersion) { text += " · Engine \(engine)" }
        return text
    }

    static func present(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

/// A copyable, redacted summary of one slot explanation. It contains reason codes, local
/// times and per-account ordinals only: no installation ID, account names or tokens.
public enum SlotDiagnostic {
    public static func text(_ result: SlotExplanationResult, engineVersion: String?) -> String {
        let e = result.explanation
        var lines = [
            "Warm-up slot \(e.slot) (\(result.zone))",
            "Verdict: \(e.verdict)" + (e.notAdmitted.map { " — \($0.cause)" } ?? ""),
            "Configured now: \(e.configured.map { $0 ? "yes" : "no" } ?? "unknown")" + (e.exclusion.map { ", excluded (\($0))" } ?? ""),
            "Admission: \(e.admission ?? "unknown")",
            "Heartbeat after admission minute: \(e.heartbeat.observedAfterAdmission.map { $0 ? "yes" : "no" } ?? "unknown")",
        ]
        for (index, account) in e.accounts.enumerated() {
            lines.append("Account \(index + 1): dispatch=\(account.dispatch) response=\(account.response) reason=\(account.reason ?? "none") guidance=\(account.guidance)")
        }
        if e.accounts.isEmpty { lines.append("Accounts: none recorded") }
        lines.append("Usage window effect: \(e.windowEffect)")
        lines.append("Engine: \(engineVersion ?? "unknown"); evidence retained \(e.retentionDays) days")
        return lines.joined(separator: "\n")
    }
}
