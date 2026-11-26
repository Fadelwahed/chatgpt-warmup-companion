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
    /// Still scheduled, but a time today had a problem that was already opened. Neutral, never the
    /// attention tint.
    public static let todayProblemSymbol = "clock.badge.exclamationmark"
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
    /// "1 missed today" or "2 not confirmed today" while scheduled after a problem today was opened;
    /// nil otherwise.
    public let todayNote: String?

    init(
        state: GlanceState, headline: String, lastOutcome: String?, lastOutcomeSlot: String?, notes: [String],
        symbolName: String? = nil, unseenProblemSlot: String? = nil, unresolvedNote: String? = nil,
        todayNote: String? = nil
    ) {
        self.state = state
        self.headline = headline
        self.lastOutcome = lastOutcome
        self.lastOutcomeSlot = lastOutcomeSlot
        self.notes = notes
        self.symbolName = symbolName ?? state.symbolName
        self.unseenProblemSlot = unseenProblemSlot
        self.unresolvedNote = unresolvedNote
        self.todayNote = todayNote
    }

    /// The headline with today's note: "Next 08:00 · 1 missed today".
    public var headlineWithNote: String {
        self.todayNote.map { "\(self.headline) · \($0)" } ?? self.headline
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
    /// `runs` names each slot at the minute it ran or runs (app 0.6.9); the labels stay the keys.
    public static func make(
        status: EngineStatus, today: String?, observedAt: Int? = nil, macZone: String? = TimeZone.current.identifier,
        acknowledgedSlot: String? = nil, runs: RunTimes = .none, history: [HistoryEntry] = []
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
            if let batch = status.activeBatch, batch.state == "running" { return (.running, "Warming up: \(runs.time(of: batch.slot) ?? String(batch.slot.suffix(5)))") }
            guard let next = status.next else { return (.noUpcoming, "No warm-up in the next 7 days") }
            let when = next.date == today ? next.admission : FriendlyTime.time(next.admission, on: next.date, today: today)
            return (.scheduled, Self.scheduledPrefix + when + zoneSuffix)
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
            headline = "Needs a look: \(FriendlyTime.slotShort(lastSlot, today: today, runs: runs))"
            unseen = lastSlot
        }
        // A problem today that was already opened: the next time stays the subject, but not "All good".
        var todayNote: String?
        if state == .scheduled, let note = Self.todayNote(Self.problemsToday(status, today: today, history: history)) {
            headline = Self.nextLine(headline)
            symbol = GlanceState.todayProblemSymbol
            todayNote = note
        }
        // Engine 1.1 names what holds the work lock: the likeliest cause of a stopped heartbeat.
        if let lockNote = WorkLockCheck.note(status, observedAt: observedAt) {
            notes.insert(lockNote, at: state == .attention ? 0 : notes.count)
        }
        var last: String?
        let ledger = status.slotLedger.first
        let batchIsNewer = (status.lastSlotOutcome?.slot ?? "") >= (ledger?.slot ?? "")
        if let outcome = status.lastSlotOutcome, batchIsNewer {
            last = LastSlotText.outcome(outcome, today: today, runs: runs)
        } else if let ledger {
            last = LastSlotText.ledger(ledger, today: today, runs: runs)
        }
        return Glance(
            state: state, headline: headline, lastOutcome: last, lastOutcomeSlot: lastSlot, notes: notes, symbolName: symbol,
            unseenProblemSlot: unseen, unresolvedNote: status.unresolved.isEmpty ? nil : UnresolvedText.line(status),
            todayNote: todayNote)
    }

    static let scheduledPrefix = "All good · next "
    static let nextPrefix = "Next "

    /// "All good · next 13:00" becomes "Next 13:00" when another headline takes its place.
    static func nextLine(_ headline: String) -> String {
        headline.hasPrefix(Self.scheduledPrefix)
            ? Self.nextPrefix + headline.dropFirst(Self.scheduledPrefix.count) : headline
    }

    /// Today's recorded problems: not-admitted ledger rows, stopped batches and the latest finished
    /// batch, each dated `today`. Status keeps only the latest batch, so the app passes its loaded
    /// `history` to keep an earlier batch that finished with a problem; the CLI reads none. None when
    /// `today` is unknown.
    public static func problemsToday(
        _ status: EngineStatus, today: String?, history: [HistoryEntry] = []
    ) -> [SlotProblem] {
        guard let today else { return [] }
        return SlotProblem.from(status, history: history).filter { $0.slot.prefix(10) == today }
    }

    /// "1 missed today" when every problem is a time not admitted, else "2 not confirmed today"; nil
    /// for none.
    public static func todayNote(_ problems: [SlotProblem]) -> String? {
        guard !problems.isEmpty else { return nil }
        let missed = problems.allSatisfy {
            if case .notAdmitted = $0.kind { return true }
            return false
        }
        return "\(problems.count) \(missed ? "missed" : "not confirmed") today"
    }
}

/// The Overview hero says the next time once: "All good" as the headline, then "Next warm-up 13:00,
/// in 2 h 15 min" below it. Other headlines stay as they are.
public enum HeroText {
    static let scheduledPrefix = GlanceBuilder.scheduledPrefix

    /// "All good", or the headline with today's note ("Next 08:00 · 1 missed today").
    public static func headline(_ glance: Glance) -> String {
        Self.when(glance) == nil ? glance.headlineWithNote : "All good"
    }

    /// "Next warm-up 13:00, in 2 h 15 min" (or without the countdown), only while scheduled. When the
    /// headline already names the next time ("Next 08:00 · 1 missed today"), the countdown alone.
    public static func next(_ glance: Glance, countdown: String?) -> String? {
        guard let when = Self.when(glance) else {
            return glance.state == .scheduled && glance.todayNote != nil ? countdown : nil
        }
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
/// times and per-account ordinals only: no installation ID, account names or tokens. Every engine
/// string passes an allowlist: a code outside its set prints `other`, a malformed slot, time, zone
/// or version prints `unknown`, so no engine reply can put free text into the copied summary.
public enum SlotDiagnostic {
    // Closed code sets, from engine 1.2.x `runtime.mjs` (`slotExplanation`, `GUIDANCE`, `LEDGER_CAUSES`,
    // reader and probe reasons) and `chatgpt-probe.mjs`.
    static let verdicts: Set<String> = [
        "admitted", "in_progress", "not_admitted", "unknown", "excluded", "not_configured",
        "nonexistent_local_time", "scheduled", "unobserved",
    ]
    static let causes: Set<String> = [
        "zone_changed", "schedule_disabled", "compatibility_blocked", "recovery_skip_through", "clock_hold",
        "manual_run_overlap", "no_tick_between", "schedule_spacing", "no_scheduled_accounts",
    ]
    static let exclusions: Set<String> = ["vacation", "weekday"]
    static let dispatches: Set<String> = ["confirmed", "unknown", "ruled_out", "pending"]
    static let responses: Set<String> = ["unobserved", "confirmed", "uncertain", "failed"]
    static let reasons: Set<String> = [
        "success", "marker_confirmed", "pilot_required", "correction_required", "cooldown",
        "compatibility_blocked", "schedule_disabled", "no_tick_between", "clock_hold", "zone_changed",
        "manual_run_overlap", "schedule_spacing", "recovery_skip_through", "batch_deadline_or_clock",
        "batch_unprocessed", "reader_global_block", "reader_unavailable", "credential_expired_or_unknown",
        "already_reserved", "probe_result_untrusted", "stream_or_transport_uncertain", "deadline_exceeded",
        "deadline_before_send", "transport_before_send", "transport_unavailable", "redirect_refused",
        "rate_limited", "upstream_rejected", "authentication_rejected", "forbidden_or_challenged",
        "unsupported_model", "protocol_failure", "output_mismatch", "invalid_probe", "registry_ineligible",
        "login_lease", "primary_untrusted", "saved_untrusted", "identity_ambiguous", "identity_mismatch",
        "invalid_enrollment", "invalid_router_account_id", "snapshot_changed", "send_check_failed",
        "daily_cap_reached", "no_scheduled_accounts",
    ]
    static let guidances: Set<String> = [
        "none", "run_manual_pilot", "review_account_block", "wait_for_cooldown", "review_source_compatibility",
        "resume_schedule_if_intended", "check_job_and_mac_awake", "review_clock", "review_time_zone",
        "review_schedule_spacing", "review_history", "review_router_state", "refresh_router_login",
        "outcome_unknown_no_resend", "check_network", "retry_after_router_login", "review_unresolved_reservation",
    ]
    static let windowEffects: Set<String> = ["unverified"]

    // Pattern-checked fields; ASCII digits only.
    static var slotPattern: Regex<Substring> { #/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}/# }
    static var timePattern: Regex<Substring> { #/[0-9]{2}:[0-9]{2}/# }
    static var versionPattern: Regex<(Substring, Substring?)> { #/[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+)?/# }

    public static func text(_ result: SlotExplanationResult, engineVersion: String?) -> String {
        let e = result.explanation
        let slot = Self.matching(e.slot, Self.slotPattern)
        // A real time zone only (as the CLI checks), so a token-shaped value is never copied.
        let zone = StatusCLI.isZone(result.zone) ? result.zone : "unknown"
        let verdict = Self.code(e.verdict, in: Self.verdicts)
        let cause = e.notAdmitted.map { " — " + Self.code($0.cause, in: Self.causes) } ?? ""
        let exclusion = e.exclusion.map { ", excluded (\(Self.code($0, in: Self.exclusions)))" } ?? ""
        let admission = e.admission.map { Self.matching($0, Self.timePattern) } ?? "unknown"
        var lines = [
            "Warm-up slot \(slot) (\(zone))",
            "Verdict: \(verdict)" + cause,
            "Configured now: \(e.configured.map { $0 ? "yes" : "no" } ?? "unknown")" + exclusion,
            "Admission: \(admission)",
            "Heartbeat after admission minute: \(e.heartbeat.observedAfterAdmission.map { $0 ? "yes" : "no" } ?? "unknown")",
        ]
        for (index, account) in e.accounts.enumerated() {
            let dispatch = Self.code(account.dispatch, in: Self.dispatches)
            let response = Self.code(account.response, in: Self.responses)
            let reason = account.reason.map { Self.code($0, in: Self.reasons) } ?? "none"
            let guidance = Self.code(account.guidance, in: Self.guidances)
            lines.append(
                "Account \(index + 1): dispatch=\(dispatch) response=\(response) reason=\(reason) guidance=\(guidance)")
        }
        if e.accounts.isEmpty { lines.append("Accounts: none recorded") }
        lines.append("Usage window effect: \(Self.code(e.windowEffect, in: Self.windowEffects))")
        let engine = engineVersion.map { Self.matching($0, Self.versionPattern) } ?? "unknown"
        lines.append("Engine: \(engine); evidence retained \(e.retentionDays) days")
        return lines.joined(separator: "\n")
    }

    static func code(_ value: String, in known: Set<String>) -> String {
        known.contains(value) ? value : "other"
    }

    static func matching<Output>(_ value: String, _ pattern: Regex<Output>) -> String {
        (try? pattern.wholeMatch(in: value)) != nil ? value : "unknown"
    }
}
