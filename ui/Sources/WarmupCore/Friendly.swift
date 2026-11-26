import Foundation

/// Friendly local times for the engine's slot labels (`yyyy-MM-ddTHH:mm`, already in the schedule
/// zone) and dates (`yyyy-MM-dd`). Relative words use the schedule zone's "today".
public enum FriendlyTime {
    /// "Today", "Yesterday", "Tomorrow", or "Mon 16 Nov".
    public static func day(_ date: String, today: String?) -> String {
        if let today, let offset = self.days(from: today, to: date) {
            switch offset {
            case 0: return "Today"
            case -1: return "Yesterday"
            case 1: return "Tomorrow"
            default: break
            }
        }
        guard let parsed = self.parse(date) else { return date }
        return self.formatter("EEE d MMM").string(from: parsed)
    }

    /// "Fri 27 Nov" for a date picker's value in `zone`, shown beside the picker: the system field
    /// prints digits only ("27/11/2026"), so the words carry the app's usual form (app 0.7.1).
    public static func picked(_ date: Date, zone: TimeZone) -> String {
        self.day(ClockTime.day(from: date, zone: zone), today: nil)
    }

    /// "Today 08:00", "Yesterday 18:00", "Mon 16 Nov 08:00". The time is the minute the slot runs
    /// (`runs`, app 0.6.9), else the label's own.
    public static func slot(_ slot: String, today: String?, runs: RunTimes = .none) -> String {
        guard let (date, own) = self.split(slot) else { return slot }
        return "\(self.day(date, today: today)) \(runs.time(of: slot) ?? own)"
    }

    /// Time first, for a sentence: "08:00 today", "18:00 yesterday", "08:00 Mon 16 Nov".
    public static func slotShort(_ slot: String, today: String?, runs: RunTimes = .none) -> String {
        guard let (date, own) = self.split(slot) else { return slot }
        return self.time(runs.time(of: slot) ?? own, on: date, today: today)
    }

    /// `time` on `date`, time first: "08:00 tomorrow", "08:00 Mon 16 Nov".
    public static func time(_ time: String, on date: String, today: String?) -> String {
        let day = self.day(date, today: today)
        return ["Today", "Yesterday", "Tomorrow"].contains(day) ? "\(time) \(day.lowercased())" : "\(time) \(day)"
    }

    /// Epoch milliseconds shown like a slot, in `zone`: "Today 12:31".
    public static func instant(_ milliseconds: Int, now: Date = Date(), zone: String) -> String {
        let timeZone = TimeZone(identifier: zone) ?? .current
        let label = self.formatter("yyyy-MM-dd'T'HH:mm", zone: timeZone)
            .string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
        let today = self.formatter("yyyy-MM-dd", zone: timeZone).string(from: now)
        return self.slot(label, today: today)
    }

    /// Today's date in `zone`, `yyyy-MM-dd`.
    public static func today(zone: String, now: Date = Date()) -> String? {
        guard let timeZone = TimeZone(identifier: zone) else { return nil }
        return self.formatter("yyyy-MM-dd", zone: timeZone).string(from: now)
    }

    static func split(_ slot: String) -> (String, String)? {
        let parts = slot.split(separator: "T", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1].count == 5 else { return nil }
        return (parts[0], parts[1])
    }

    static func days(from: String, to: String) -> Int? {
        guard let start = self.parse(from), let end = self.parse(to) else { return nil }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    static func parse(_ date: String) -> Date? { self.formatter("yyyy-MM-dd").date(from: date) }

    static func formatter(_ pattern: String, zone: TimeZone = TimeZone(identifier: "UTC")!) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter
    }
}

extension Wording {
    /// Plain words for the engine's reason codes (ledger causes, skips, refusals). Unknown codes
    /// fall back to the code with spaces, so nothing is hidden.
    public static func reason(_ code: String) -> String {
        switch code {
        // Slot ledger causes.
        case "no_tick_between": "nothing ran at that minute"
        case "schedule_spacing": "too close to the previous warm-up"
        case "zone_changed": "the time zone changed"
        case "manual_run_overlap": "a manual warm-up was running"
        case "clock_hold": "the clock moved backward"
        case "schedule_disabled": "scheduling was paused"
        case "compatibility_blocked": "Router needed a review"
        case "recovery_skip_through": "skipped while recovering"
        case "no_scheduled_accounts": "no account was chosen"
        // Per-account results and skips.
        case "marker_confirmed": "confirmed"
        case "daily_cap_reached": "daily limit reached"
        case "pilot_required": "needs a first manual warm-up"
        case "correction_required": "the account needs a review"
        case "cooldown": "cooling down"
        case "already_reserved": "already reserved; not sent again"
        case "batch_unprocessed": "the batch stopped before this account"
        case "batch_deadline_or_clock": "ran out of time or the clock changed"
        case "reader_global_block": "Router could not be read"
        case "probe_result_untrusted": "the reply could not be trusted"
        case "transport_before_send": "the network was unavailable"
        // Refusals.
        case "slot_overlap_risk": "a scheduled warm-up is about to start"
        case "schedule_time_elapsed": "that time has already passed today"
        case "schedule_slot_unavailable": "that time is already taken or passed"
        case "schedule_spacing_conflict": "too close to another time"
        case "schedule_revision_conflict": "the schedule changed meanwhile; refresh and try again"
        case "schedule_date_changed": "the date changed meanwhile; refresh and try again"
        case "schedule_date_excluded": "that day is off"
        case "vacation_not_future": "past days and today cannot change"
        case "vacation_overlap": "it overlaps another time off"
        case "vacation_missing": "that time off no longer exists"
        case "invalid_account_selection": "that would make the account list too long"
        case "undo_unavailable": "there is nothing to undo"
        case "undo_expired": "undo only works on the same day"
        case "lock_busy": "the engine is busy; try again shortly"
        case "no_enabled_enrollments": "no account is turned on"
        default: Wording.code(code)
        }
    }
}

/// One sentence for the most recent slot: "08:00 today: all 3 confirmed".
public enum LastSlotText {
    public static func outcome(_ outcome: SlotOutcome, today: String?, runs: RunTimes = .none) -> String {
        let time = FriendlyTime.slotShort(outcome.slot, today: today, runs: runs)
        let results = outcome.results ?? []
        if outcome.outcome == "blocked" { return "\(time): did not complete" }
        let counted = results.filter { !SlotProblem.chosenSkipReasons.contains($0.reason) }
        guard !counted.isEmpty else {
            if !results.isEmpty { return "\(time): skipped (\(Wording.reason(results[0].reason)))" }
            return
                "\(time): \(outcome.outcome == "idle" ? "nothing to run" : Wording.reason(outcome.outcome ?? "unknown"))"
        }
        let confirmed = counted.filter { $0.outcome == "success" }.count
        let unknown = counted.filter { $0.outcome == "uncertain" }.count
        if confirmed == counted.count {
            return counted.count == 1 ? "\(time): confirmed" : "\(time): all \(confirmed) confirmed"
        }
        return "\(time): \(confirmed) of \(counted.count) confirmed" + (unknown > 0 ? ", \(unknown) unknown" : "")
    }

    public static func ledger(_ row: LedgerRow, today: String?, runs: RunTimes = .none) -> String {
        let time = FriendlyTime.slotShort(row.slot, today: today, runs: runs)
        let word = SlotProblem.operatorChosenCauses.contains(row.cause) ? "skipped" : "missed"
        return "\(time): \(word) (\(Wording.reason(row.cause)))"
    }
}

/// When the app reads status in the background, so the menu-bar icon is right without a click:
/// two minutes after the next slot (its result is in by then), otherwise every 15 minutes, and
/// after a minute when nothing could be read. Launch and wake read at once. In Low Power Mode the
/// regular interval is 30 minutes.
public enum RefreshPlan {
    public static let regular: TimeInterval = 15 * 60
    public static let lowPowerRegular: TimeInterval = 30 * 60
    public static let retry: TimeInterval = 60
    public static let afterSlot = 120_000

    public static func delay(nowMilliseconds now: Int, status: EngineStatus?, lowPower: Bool = false) -> TimeInterval {
        guard let status else { return self.retry }
        let regular = lowPower ? self.lowPowerRegular : self.regular
        // A batch is running: check again soon, so the icon does not keep saying so for long.
        if status.activeBatch?.state == "running" { return self.retry }
        guard let at = status.next?.at, at + self.afterSlot > now else { return regular }
        return max(30, min(regular, TimeInterval(at + self.afterSlot - now) / 1000))
    }
}

extension Wording {
    /// A projected admission's state in plain words: "upcoming", "missed: nothing ran at that minute".
    public static func admission(state: String, cause: String?) -> String {
        if let cause {
            return (SlotProblem.operatorChosenCauses.contains(cause) ? "skipped: " : "missed: ") + self.reason(cause)
        }
        switch state {
        case "upcoming": return "upcoming"
        case "claimed": return "ran"
        case "elapsed": return "passed"
        case "paused": return "paused"
        case "unavailable": return "not offered"
        case "spacing_hold": return "too close to the last warm-up"
        case "nonexistent_local_time": return "skipped: clocks go forward"
        case "not_admitted": return "missed"
        default: return self.code(state)
        }
    }

    /// A symbol per slot verdict, so the detail's headline is not the same icon for every state.
    public static func verdictSymbol(_ code: String) -> String {
        switch code {
        case "admitted": "checkmark.circle"
        case "in_progress": "arrow.triangle.2.circlepath"
        case "not_admitted", "unobserved": "xmark.circle"
        case "scheduled": "clock"
        case "excluded", "not_configured", "nonexistent_local_time": "minus.circle"
        default: "questionmark.circle"
        }
    }
}

/// Time-off ranges as people say them: "1–5 Dec (5 days)", "30 Nov – 2 Dec (3 days)", "1 Dec (1 day)".
public enum VacationText {
    public static func range(start: String, end: String) -> String {
        guard let span = self.span(start: start, end: end), let days = FriendlyTime.days(from: start, to: end)
        else { return "\(start) to \(end)" }
        let count = days + 1
        return "\(span) (\(count) day\(count == 1 ? "" : "s"))"
    }

    /// The dates alone: "15–21 Nov", "28 Nov – 4 Dec", "1 Dec"; nil when either date is invalid
    /// or the range runs backward.
    public static func span(start: String, end: String) -> String? {
        guard let first = FriendlyTime.parse(start), let last = FriendlyTime.parse(end),
            let days = FriendlyTime.days(from: start, to: end), days >= 0
        else { return nil }
        let dayMonth = FriendlyTime.formatter("d MMM")
        if days == 0 { return dayMonth.string(from: first) }
        if start.prefix(7) == end.prefix(7) {
            return "\(FriendlyTime.formatter("d").string(from: first))–\(dayMonth.string(from: last))"
        }
        return "\(dayMonth.string(from: first)) – \(dayMonth.string(from: last))"
    }
}

/// The engine's 24-hour `HH:mm` for a picked time, whatever the Mac's 12- or 24-hour setting.
public enum ClockTime {
    public static let utc = TimeZone(identifier: "UTC")!

    public static func string(from date: Date, zone: TimeZone) -> String {
        FriendlyTime.formatter("HH:mm", zone: zone).string(from: date)
    }

    /// The engine's `yyyy-MM-dd` for `date` in `zone`, in ASCII digits whatever the Mac's locale.
    public static func day(from date: Date, zone: TimeZone) -> String {
        FriendlyTime.formatter("yyyy-MM-dd", zone: zone).string(from: date)
    }

    /// The next time's admission as `HH:mm` in `local` (the Mac's zone), for wake guidance.
    public static func localAdmission(_ next: NextSlot, scheduleZone: String, local: TimeZone = .current) -> String? {
        Countdown.date(of: next, zone: scheduleZone).map { self.string(from: $0, zone: local) }
    }

    /// Today at `HH:mm` in `zone`, for a picker's starting value.
    public static func date(from time: String, zone: TimeZone, now: Date = Date()) -> Date? {
        let day = FriendlyTime.formatter("yyyy-MM-dd", zone: zone).string(from: now)
        return FriendlyTime.formatter("yyyy-MM-dd HH:mm", zone: zone).date(from: "\(day) \(time)")
    }
}

/// One status phrase per account row, so three code columns become one answer: can it warm up?
public enum AccountText {
    /// Said for a block reason that is not a known code, so no engine text reaches the screen or the CLI.
    public static let blockedText = "Blocked"
    public static let coolingDown = "Cooling down"

    /// The row's state. With the account's `state` from status, "Ready" becomes the block reason in
    /// plain words or "Cooling down" (app 0.7.0: one rule for the table and the CLI). Without it, the
    /// row alone decides, as before.
    public static func readiness(_ row: AccountRow, state: AccountState? = nil, now: Int = 0) -> String {
        let base = self.rowReadiness(row)
        guard base == "Ready", let state else { return base }
        return self.hold(state, now: now) ?? base
    }

    /// The block reason in plain words ("Blocked" when the reason is not a known code), "Cooling down"
    /// while the cooldown is ahead, or nil when neither holds the account.
    public static func hold(_ state: AccountState, now: Int) -> String? {
        if let block = state.block {
            let words = Wording.reason(block)
            guard words != Wording.code(block) else { return self.blockedText }
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        if let until = state.cooldownUntil, until > now { return self.coolingDown }
        return nil
    }

    static func rowReadiness(_ row: AccountRow) -> String {
        switch row.enrollmentState {
        case "not_enrolled": return row.eligible ? "Not added yet" : self.router(row.registryReason)
        case "disabled": return "Turned off"
        case "enrolled_unregistered": return "Missing from Router"
        default:
            if row.registryReason != "eligible" { return self.router(row.registryReason) }
            return row.pilot ? "Ready" : "Needs a first manual warm-up"
        }
    }

    /// The state's symbol: a check only for Ready, a minus for Turned off, a plus for Not added yet,
    /// an hourglass for Cooling down, and a warning for anything that needs the operator.
    public static func symbol(_ row: AccountRow, state: AccountState? = nil, now: Int = 0) -> String {
        switch self.readiness(row, state: state, now: now) {
        case "Ready": "checkmark.circle"
        case "Turned off": "minus.circle"
        case "Not added yet": "plus.circle"
        case self.coolingDown: "hourglass"
        default: "exclamationmark.triangle"
        }
    }

    /// True when the phrase needs the operator (a block does; a cooldown does not).
    public static func needsLook(_ row: AccountRow, state: AccountState? = nil, now: Int = 0) -> Bool {
        let fine = ["Ready", "Not added yet", "Turned off", self.coolingDown]
        return !fine.contains(self.readiness(row, state: state, now: now))
    }

    /// The state line under the account's name: "Ready · last seen Tue" once the usage reading is more
    /// than 24 hours old ("Ready · last seen 18 Nov" past 6 days). Only an exact "Ready" gets it, and
    /// never a nicknamed row, whose line already carries "· Account N" (its usage cell shows the time).
    public static func stateLine(
        readiness: String, observedAt: Int?, nicknamed: Bool, now: Int, zone: String
    ) -> String {
        guard readiness == "Ready", !nicknamed, let observedAt,
            let seen = UsageText.lastSeen(observedAt: observedAt, now: now, zone: zone)
        else { return readiness }
        return "\(readiness) · \(seen)"
    }

    static func router(_ reason: String) -> String {
        switch reason {
        case "revoked": "Router sign-in revoked"
        case "paused": "Paused in Router"
        case "identity_unknown": "Router sign-in needed"
        case "unregistered": "Missing from Router"
        case "eligible": "Ready"
        default: "Not available in Router"
        }
    }

    /// "Confirmed · Today 08:00", or "None yet".
    public static func last(_ row: AccountRow, zone: String, now: Date = Date()) -> String {
        guard let outcome = row.lastOutcome else { return "None yet" }
        let words =
            switch outcome {
            case "success": "Confirmed"
            case "uncertain": "Uncertain"
            default:
                Wording.reason(row.lastReason ?? outcome).prefix(1).uppercased()
                    + Wording.reason(row.lastReason ?? outcome).dropFirst()
            }
        return row.lastAt.map { "\(words) · \(FriendlyTime.instant($0, now: now, zone: zone))" } ?? words
    }
}

/// What a previewed change adds or removes, day by day, so the proposal can mark its rows.
public enum ProposalDiff {
    /// Keys `date|HH:mm` of admissions the proposal adds.
    public static func added(current: [ProjectedDay], proposed: [ProjectedDay]) -> Set<String> {
        self.keys(proposed).subtracting(self.keys(current))
    }

    /// Per date, the admission times the proposal removes, in order.
    public static func removed(current: [ProjectedDay], proposed: [ProjectedDay]) -> [String: [String]] {
        let gone = self.keys(current).subtracting(self.keys(proposed))
        var byDate: [String: [String]] = [:]
        for key in gone.sorted() {
            let parts = key.split(separator: "|").map(String.init)
            if parts.count == 2 { byDate[parts[0], default: []].append(parts[1]) }
        }
        return byDate
    }

    public static func key(date: String, admission: String) -> String { "\(date)|\(admission)" }

    static func keys(_ days: [ProjectedDay]) -> Set<String> {
        Set(days.flatMap { day in day.admissions.map { self.key(date: day.date, admission: $0.admission) } })
    }
}

/// What a slot's batch recorded when its explanation alone cannot show it: a batch the engine
/// stopped may have no account rows, so the detail must not read as a plain "Ran".
public enum BatchNote {
    public static func text(status: EngineStatus, slot: String) -> String? {
        let last = status.lastSlotOutcome?.slot == slot ? status.lastSlotOutcome?.outcome : nil
        if last == "blocked" || (status.blockedSlots ?? []).contains(where: { $0.slot == slot }) {
            return "The engine stopped this batch before it finished. Accounts below without a recorded "
                + "result may or may not have been sent; uncertain sends are never resent."
        }
        return last == "partial" ? "This batch finished with problems; see each account below." : nil
    }
}

/// The one-line count of sends without a result, for Needs attention and the menu (app 0.7.0: one name,
/// "sends without a result"). A list the engine cut says "or more": "50 or more sends have no recorded
/// result."
public enum UnresolvedText {
    public static func line(_ status: EngineStatus) -> String {
        Self.line(count: status.unresolved.count, truncated: status.unresolvedTruncated == true)
    }

    /// The same line for a filtered count (Needs attention counts only rows not marked as reviewed).
    public static func line(count: Int, truncated: Bool) -> String {
        if truncated {
            return "\(count) or more sends have no recorded result. They are never resent."
        }
        return count == 1
            ? "1 send has no recorded result. It is never resent."
            : "\(count) sends have no recorded result. They are never resent."
    }

    /// "3 reviewed sends without a result", the quiet line's words before "· Show".
    public static func reviewed(count: Int) -> String {
        "\(count) reviewed send\(count == 1 ? "" : "s") without a result"
    }
}

/// "Needs attention" rows for possible sends without a recorded outcome, one per slot (newest
/// first) and one for all manual warm-ups, so a long legacy list stays short.
public struct UnresolvedGroup: Sendable, Equatable, Identifiable {
    /// The slot to explain, or nil for the manual group.
    public let slot: String?
    public let text: String
    public var id: String { self.slot ?? "manual" }

    public static func make(_ rows: [UnresolvedReservation], today: String?, runs: RunTimes = .none)
        -> [UnresolvedGroup]
    {
        var perSlot: [String: Int] = [:]
        var manual = 0
        for row in rows {
            if let slot = row.slot { perSlot[slot, default: 0] += 1 } else { manual += 1 }
        }
        let slots = perSlot.keys.sorted(by: >).map { slot in
            let count = perSlot[slot] ?? 0
            let who = count == 1 ? "1 account" : "\(count) accounts"
            let when = FriendlyTime.slot(slot, today: today, runs: runs)
            return UnresolvedGroup(slot: slot, text: "\(when): \(who), no result recorded")
        }
        guard manual > 0 else { return slots }
        let text =
            manual == 1 ? "1 manual warm-up, no result recorded" : "\(manual) manual warm-ups, no result recorded"
        return slots + [UnresolvedGroup(slot: nil, text: text)]
    }
}
