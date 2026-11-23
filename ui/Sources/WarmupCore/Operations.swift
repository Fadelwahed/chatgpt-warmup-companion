import Foundation

/// One operator action the app can request. Each maps to exactly one allowlisted command.
public enum WarmupAction: Sendable, Equatable {
    case runAll(allowSlotOverlap: Bool, overlapAt: Int? = nil)
    case runAccount(enrollmentId: String, allowSlotOverlap: Bool, overlapAt: Int? = nil)
    case enroll(routerAccountId: String)
    case pause(expectedRevision: Int)
    case resume(expectedRevision: Int)
    case saveEdit(ScheduleEdit, expectedRevision: Int, expectedLocalDate: String)
    case setting(ScheduleSetting, expectedRevision: Int, expectedLocalDate: String?)

    public var command: EngineCommand {
        switch self {
        case let .runAll(overlap, at): .runAll(allowSlotOverlap: overlap, overlapAt: at)
        case let .runAccount(id, overlap, at):
            .runAccount(enrollmentId: id, allowSlotOverlap: overlap, overlapAt: at)
        case let .enroll(ref): .enroll(routerAccountId: ref)
        case let .pause(revision): .scheduleDisable(expectedRevision: revision)
        case let .resume(revision): .scheduleEnable(expectedRevision: revision)
        case let .saveEdit(edit, revision, date): .scheduleEdit(edit, expectedRevision: revision, expectedLocalDate: date)
        case let .setting(setting, revision, date):
            .scheduleSetting(setting, expectedRevision: revision, expectedLocalDate: date)
        }
    }

    public var title: String {
        switch self {
        case .runAll: "Warm up all accounts"
        case .runAccount: "Warm up one account"
        case .enroll: "Enroll account"
        case .pause: "Pause scheduling"
        case .resume: "Resume scheduling"
        case .saveEdit: "Save schedule change"
        case let .setting(setting, _, _):
            switch setting {
            case .exclude: "Add time off"
            case .include: "Remove time off"
            case let .accounts(ids): ids == nil ? "Schedule all accounts" : "Change scheduled accounts"
            case .addAccount: "Add to scheduled warm-ups"
            case .removeAccount: "Remove from scheduled warm-ups"
            case .undo: "Undo last time change"
            case let .cap(_, count): count == nil ? "Remove daily limit" : "Set daily limit"
            }
        }
    }

    /// The confirm button: a short verb, in title case.
    public var confirmLabel: String {
        switch self {
        case .runAll, .runAccount: "Warm Up"
        case .enroll: "Enroll"
        case .pause: "Pause"
        case .resume: "Resume"
        case .saveEdit: "Save"
        case let .setting(setting, _, _):
            switch setting {
            case .exclude, .addAccount: "Add"
            case .include, .removeAccount: "Remove"
            case .accounts: "Save"
            case .undo: "Undo"
            case let .cap(_, count): count == nil ? "Remove Limit" : "Set Limit"
            }
        }
    }

    /// The plain sentence shown when the engine accepted the change.
    public var doneText: String {
        switch self {
        case .runAll, .runAccount: "Warm-up finished."
        case .enroll: "Account enrolled."
        case .pause: "Scheduling is paused."
        case .resume: "Scheduling is on again."
        case .saveEdit: "Schedule saved."
        case let .setting(setting, _, _):
            switch setting {
            case .exclude: "Time off added."
            case .include: "Time off removed from tomorrow."
            case .accounts: "Scheduled accounts updated."
            case .addAccount: "Account added to scheduled warm-ups."
            case .removeAccount: "Account removed from scheduled warm-ups."
            case .undo: "Last time change undone."
            case let .cap(_, count): count == nil ? "Daily limit removed." : "Daily limit set."
            }
        }
    }

    public var sendsRequests: Bool {
        switch self {
        case .runAll, .runAccount: true
        default: false
        }
    }

    /// Two tiers (app 0.5): a dialog for anything that sends, enrolls, pauses, resumes or changes
    /// times. Time off, scheduled accounts and caps send nothing and are undone with the same control,
    /// so they apply at once; each still carries the revision guard and reports its result.
    public var needsConfirmation: Bool {
        switch self {
        case .runAll, .runAccount, .enroll, .pause, .resume, .saveEdit: true
        case let .setting(setting, _, _):
            switch setting {
            case .undo: true
            case .exclude, .include, .accounts, .addAccount, .removeAccount, .cap: false
            }
        }
    }
}

/// What happened, stated from the engine's reply only.
public struct OperationReport: Sendable, Equatable {
    public enum Kind: String, Sendable { case completed, partial, refused, busy, noWork, conflict, overlap, unknown }

    public let operation: WarmupAction
    public let kind: Kind
    public let headline: String
    public let details: [String]
    public let reason: String?
    /// Set when the engine refused a manual run near a scheduled admission; a new, explicit
    /// confirmation may resend it with the overlap override. Never resent automatically.
    public let overlap: OverlapSlot?
}

public enum OperationReporter {
    // Installation changes never reach here: the reply validator rejects them first, and they
    // surface as an unknown outcome that forces a fresh status read.
    static let conflictReasons: Set<String> = ["schedule_revision_conflict", "schedule_date_changed"]

    public static func unknown(_ operation: WarmupAction, issue: ClientIssue) -> OperationReport {
        OperationReport(
            operation: operation, kind: .unknown,
            headline: "\(operation.title): outcome unknown",
            details: [issue.description, "The engine may have acted. Status is being refreshed; no action is repeated."],
            reason: nil, overlap: nil)
    }

    public static func refused(_ operation: WarmupAction, issue: ClientIssue) -> OperationReport {
        OperationReport(operation: operation, kind: .refused, headline: "\(operation.title): not started", details: [issue.description], reason: nil, overlap: nil)
    }

    /// `labels` maps enrollment IDs to the on-screen account names (nickname or "Account N"), so a
    /// result names the account it is about, never its place in the reply (0.6.3).
    public static func run(
        _ operation: WarmupAction, envelope: Envelope, reply: RunReply, labels: [String: String] = [:]
    ) -> OperationReport {
        if envelope.reason == "slot_overlap_risk", let overlap = reply.overlap {
            let due = FriendlyTime.time(overlap.admission, on: overlap.date, today: nil)
            return OperationReport(
                operation: operation, kind: .overlap,
                headline: "Not started: a scheduled warm-up is due at \(due)",
                details: ["Running now could overlap that warm-up. Nothing was sent.", "You can run anyway; the scheduled warm-up may then be skipped."],
                reason: envelope.reason, overlap: overlap)
        }
        let confirmed = reply.results.filter { $0.outcome == "success" }.count
        let uncertain = reply.results.filter { $0.outcome == "uncertain" }.count
        // Accounts are listed only when one did not succeed.
        var details: [String] = []
        for result in reply.results where result.outcome != "success" {
            let sent = result.dispatched == true ? "sent" : result.outcome == "uncertain" ? "may have been sent" : "not sent"
            let name = labels[result.enrollmentId] ?? "An account"
            details.append("\(name): \(sent), \(Wording.reason(result.reason)).")
        }
        if uncertain > 0 { details.append("Uncertain sends are never resent.") }
        let kind: OperationReport.Kind = switch envelope.outcome {
        case "success": .completed
        case "partial": .partial
        case "no_work": .noWork
        case "busy": .busy
        default: .refused
        }
        let count = reply.results.count
        let headline = switch kind {
        case .completed: count == 1 ? "The account confirmed." : "All \(count) accounts confirmed."
        case .partial: "\(confirmed) of \(count) accounts confirmed."
        case .noWork: "Nothing to warm up: \(Wording.reason(envelope.reason))."
        case .busy: "Busy: \(Wording.reason(envelope.reason)). Nothing was retried."
        default: "Warm-up not completed: \(Wording.reason(envelope.reason))."
        }
        return OperationReport(operation: operation, kind: kind, headline: headline, details: details, reason: envelope.reason, overlap: nil)
    }

    public static func change(_ operation: WarmupAction, envelope: Envelope, reply: ScheduleChangeReply?, enrolled: EnrollReply? = nil) -> OperationReport {
        if self.conflictReasons.contains(envelope.reason) {
            return OperationReport(
                operation: operation, kind: .conflict,
                headline: "\(operation.title): refused because the schedule or installation changed",
                details: ["Nothing was saved. Refresh and preview again before confirming."], reason: envelope.reason, overlap: nil)
        }
        switch envelope.outcome {
        case "ready", "idle", "success":
            var details: [String] = []
            if case .enroll = operation {
                details.append(envelope.reason == "already_enrolled" ? "This account was already enrolled." : "Run one manual warm-up for it before it can be scheduled.")
            }
            if case let .saveEdit(edit, _, _) = operation, reply?.localDate != nil {
                details.append(edit.isToday ? "It applies today." : "It starts tomorrow; today's times stay as they were.")
            }
            if reply?.job != nil, reply?.job != "loaded", case .resume = operation {
                details.append("The background job is not running yet. Refresh in a moment.")
            }
            return OperationReport(operation: operation, kind: .completed, headline: operation.doneText, details: details, reason: envelope.reason, overlap: nil)
        case "busy":
            return OperationReport(
                operation: operation, kind: .busy, headline: "Busy: \(Wording.reason(envelope.reason)).",
                details: ["Nothing was retried. Try again when the current batch finishes."], reason: envelope.reason, overlap: nil)
        default:
            return OperationReport(
                operation: operation, kind: .refused, headline: "Not done: \(Wording.reason(envelope.reason)).",
                details: [], reason: envelope.reason, overlap: nil)
        }
    }
}

/// Wording for the confirmation shown before each action.
public enum Confirmation {
    static let overrideNote = " This overrides the overlap check: the scheduled warm-up that is due may be skipped."

    public static func text(for operation: WarmupAction, enabledAccounts: Int, pilots: Int, account: String? = nil) -> String {
        switch operation {
        case let .runAll(overlap, _):
            "Sends one warm-up request to each enabled account (\(enabledAccounts) at the last check). Each request counts toward that account's usage. Nothing is retried automatically."
                + (overlap ? self.overrideNote : "")
        case let .runAccount(id, overlap, _):
            "Sends one warm-up request to \(account ?? "this account"). It counts toward that account's usage. Nothing is retried automatically."
                + (overlap ? self.overrideNote : "")
        case let .enroll(ref):
            "Adds \(account.map { "Router account \($0)" } ?? "this Router account") to Warm-up. Nothing is sent. Scheduling needs one successful manual warm-up first."
        case .pause:
            "Stops automatic warm-ups. A running batch finishes first. Nothing runs until you resume."
        case .resume:
            "Starts automatic warm-ups again from the next eligible time, without catching up missed ones. At the last check: \(enabledAccounts) account(s) on, \(pilots) ready (they had a first manual warm-up)."
        case let .saveEdit(edit, _, _):
            "\(edit.summary) It is refused if the schedule or the date changed since the preview."
        case let .setting(setting, _, _):
            self.settingText(setting, account: account)
        }
    }
}

extension Confirmation {
    static func settingText(_ setting: ScheduleSetting, account: String?) -> String {
        switch setting {
        case let .exclude(start, end):
            "No scheduled warm-ups on \(Self.days(start, end)), both days included. Manual warm-ups still work. Nothing is sent now."
        case let .include(start, end):
            "Scheduled warm-ups return for \(Self.days(start, end)) from tomorrow. If the range has started, today stays a day off; to run today, resume or use a manual warm-up."
        case let .accounts(ids):
            ids == nil
                ? "Scheduled warm-ups go to every enabled account again, from the next scheduled time."
                : "From the next scheduled time, scheduled warm-ups go only to the selected accounts (\(ids?.count ?? 0)). Manual warm-ups still reach every enabled account. Accounts enrolled later stay outside the schedule until you add them."
        case .addAccount:
            "From the next scheduled time, scheduled warm-ups include \(account ?? "this account")."
        case .removeAccount:
            "From the next scheduled time, scheduled warm-ups leave out \(account ?? "this account"). Manual warm-ups still reach it. If every account was scheduled, the rest stay scheduled; accounts enrolled later stay out until you add them."
        case .undo:
            "Restores the schedule as it was before your last time change today. It is refused if an affected time has passed or already ran."
        case let .cap(_, count):
            count.map {
                "At most \($0) scheduled warm-up\($0 == 1 ? "" : "s") a day for \(account ?? "this account"). Manual warm-ups are not limited."
            } ?? "Removes the daily limit for \(account ?? "this account")."
        }
    }

    /// "20–22 Nov 2026" with the year, so a confirmation never names the wrong year's range. A range
    /// across a new year, or dates that cannot be read, keep the engine's dates.
    static func days(_ start: String, _ end: String) -> String {
        guard start.prefix(4) == end.prefix(4), let span = VacationText.span(start: start, end: end) else {
            return "\(start) to \(end)"
        }
        return "\(span) \(start.prefix(4))"
    }
}

/// "Run anyway" after an overlap refusal. The engine's override skips its overlap check
/// entirely, so the app offers it only while the slot named in the refusal is still the next
/// slot: an old refusal can never override the check for a later slot.
public enum OverlapOverride {
    public static func stillApplies(_ overlap: OverlapSlot, next: NextSlot?) -> Bool {
        guard let next else { return false }
        // The slot ID alone is not enough: a moved admission keeps its ID but changes time or date,
        // and the two fall-back occurrences share all three; the instant tells them apart.
        let sameInstant = overlap.at == nil || next.at == nil || overlap.at == next.at
        let sameSlot = next.slot == overlap.slot && next.admission == overlap.admission && next.date == overlap.date
        return sameSlot && sameInstant
    }
}

/// The Scheduled checkbox (Increment B2) as a setting for the value the operator chose.
public enum ScheduledAccounts {
    /// Nil when the account already has the chosen value. Re-adding the last enabled account that
    /// an explicit list left out returns to "all enabled accounts", so the checkbox is reversible.
    public static func change(
        _ enrollment: String, scheduled wanted: Bool, current: [String]?, enabled: [String]
    ) -> ScheduleSetting? {
        let scheduled = current?.contains(enrollment) ?? true
        guard scheduled != wanted else { return nil }
        guard wanted else { return .removeAccount(enrollment) }
        if let current, !enabled.isEmpty, Set(enabled).isSubset(of: Set(current).union([enrollment])) {
            return .accounts(nil)
        }
        return .addAccount(enrollment)
    }

    /// Every enrollment in this status reply, but only when all of them are enabled: the same reply
    /// that supplies the revision, never an older account list. Otherwise empty, so nothing widens
    /// to "all".
    public static func allEnabled(_ status: EngineStatus) -> [String] {
        status.enabled == status.accounts.count ? status.accounts.map(\.enrollmentId) : []
    }
}
