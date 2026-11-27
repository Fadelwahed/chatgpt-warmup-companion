import Foundation

// App 0.6 ("measurement and visibility"): the "count from" date, progress, the per-send list and the
// decision card for "Did it help?" (F1), and the usage cell text for Accounts and the menu (F2).
// Everything here is a pure view of the app's own usage log and of status; nothing is sent.

/// "3 of 10 warm-ups measured since 1 Dec": how far the measurement is from a decision.
public enum EffectProgress {
    /// `upcoming`: the start date is still ahead, so nothing is counted yet: "Counting starts 1 Dec."
    public static func text(clear: Int, countFromLabel: String?, upcoming: Bool = false) -> String {
        if upcoming, let countFromLabel { return "Counting starts \(countFromLabel)." }
        let period = countFromLabel.map { "since \($0)" } ?? "in the last \(EffectReport.periodDays) days"
        let goal = EffectReport.minimumSends
        let noun = clear == 1 ? "warm-up" : "warm-ups"
        if clear > goal { return "\(clear) \(noun) measured \(period)" }
        return "\(clear) of \(goal) warm-ups measured \(period)"
    }

    /// The share of the sends a decision needs, 0…1, for a progress bar.
    public static func fraction(clear: Int) -> Double {
        min(1, max(0, Double(clear) / Double(EffectReport.minimumSends)))
    }
}

/// One send in the per-send list. `label` may be a nickname (screen only); `numberLabel` is always
/// "Account N" and is the only account name copied text uses.
public struct EffectRow: Sendable, Equatable, Identifiable {
    public let id: String
    /// "Today 08:00", "Sat 21 Nov 08:00".
    public let time: String
    public let label: String
    public let numberLabel: String
    public let effect: WindowEffect
    public let effectWords: String
    /// "resets 4 h 58 min later", "reset 6 min later", or "" when unknown.
    public let resetText: String
}

/// The decision card, shown once a count-from date is set and 10 sends have a clear answer.
public enum EffectDecision: String, Sendable, Equatable {
    case keep, stop, undecided

    public var text: String {
        switch self {
        case .keep: "Most started a fresh window: keep the schedule"
        case .stop: "Most did not: turn the schedule off"
        case .undecided: "No clear answer yet: keep measuring"
        }
    }

    /// Only `.stop` offers Pause Scheduling… (through the existing confirmed action).
    public var offersPause: Bool { self == .stop }

    /// Nil unless `countFrom` is set and at least 10 sends have a clear answer. The majority rule is the
    /// verdict's: strictly more than half.
    public static func make(counts: [WindowEffect: Int], total: Int, countFrom: Int?) -> EffectDecision? {
        let fresh = counts[.startedFresh] ?? 0
        let notFresh = (counts[.insideRunning] ?? 0) + (counts[.noShortWindow] ?? 0)
        let clear = fresh + notFresh
        guard countFrom != nil, total > 0, clear >= EffectReport.minimumSends else { return nil }
        if fresh * 2 > clear { return .keep }
        if notFresh * 2 > clear { return .stop }
        return .undecided
    }
}

extension EffectReport {
    public static let maxRows = 50
    /// The Overview footer under "Did it help?".
    public static let footer = "Read from the usage the provider reported at each warm-up. An observation, not proof."
    /// Shown on Overview instead of a decision while no "count from" date is set (app 0.7.0).
    public static let noCountFrom = "Decision period hasn't started."
    /// Settings while no "count from" date is set: "Decision period hasn't started. Counting the last 14 days."
    public static let notStarted = "\(noCountFrom) Counting the last \(periodDays) days."
    /// Settings once a "count from" date is set (work order 145).
    public static let started = "Decision period started. Counting from the date below."
    /// Settings while the "count from" date is still ahead (work order 146).
    public static let starts = "Decision period starts on the date below. Nothing is counted before then."
    /// How many days ahead the "count from" date can be picked (work order 146).
    public static let maxDaysAhead = 31
    /// The "Did it help?" headline while the start date is still ahead (work order 147).
    public static let notCountingYet = "Not counting yet."

    /// The "Did it help?" headline: `notCountingYet` while the start date is ahead, else the verdict.
    public static func headline(_ summary: EffectSummary, upcoming: Bool) -> String {
        upcoming ? Self.notCountingYet : summary.verdict
    }

    /// The Settings status line: not set, set but still ahead of `now`, or started (all in ms).
    public static func measurementLine(countFrom: Int?, now: Int) -> String {
        guard let countFrom else { return Self.notStarted }
        return countFrom > now ? Self.starts : Self.started
    }
    /// The Overview button that opens Settings to set the "count from" date.
    public static let setStartDate = "Set Start Date…"

    /// The start of `day` (`yyyy-MM-dd`) in `zone`, in epoch milliseconds; nil for a bad day or zone.
    public static func countFromStart(day: String, zone: String) -> Int? {
        guard let timeZone = TimeZone(identifier: zone) else { return nil }
        let formatter = FriendlyTime.formatter("yyyy-MM-dd", zone: timeZone)
        formatter.isLenient = false
        guard let parsed = formatter.date(from: day), formatter.string(from: parsed) == day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Int((calendar.startOfDay(for: parsed).timeIntervalSince1970 * 1000).rounded())
    }

    /// "1 Dec", with the year only when it is not the year of `now`: "1 Dec 2025".
    public static func countFromLabel(ms: Int, zone: String, now: Int) -> String {
        let pattern =
            LocalTime.format(ms, zone: zone, pattern: "yyyy") == LocalTime.format(now, zone: zone, pattern: "yyyy")
            ? "d MMM" : "d MMM yyyy"
        return LocalTime.format(ms, zone: zone, pattern: pattern)
    }

    /// The per-send list for the accounts in `order`, newest first, at most 50. Labels come from
    /// `labels` (see `AccountNaming.labels`), falling back to "Account N" in `order`.
    public static func rows(
        log: UsageLog, order: [String], labels: [String: String], countFrom: Int?, now: Int, zone: String
    ) -> [EffectRow] {
        let counted = Self.counted(log, order: order, now: now, countFrom: countFrom)
        let nowDate = Date(timeIntervalSince1970: Double(now) / 1000)
        return counted.reversed().prefix(Self.maxRows).map { row in
            let number = "Account \((order.firstIndex(of: row.account) ?? 0) + 1)"
            let effect = Self.classify(row)
            return EffectRow(
                id: "\(row.account)#\(row.observedAt)",
                time: FriendlyTime.instant(row.observedAt, now: nowDate, zone: zone),
                label: labels[row.account] ?? number,
                numberLabel: number, effect: effect, effectWords: Self.words(effect),
                resetText: Self.resetText(row, now: now))
        }
    }

    /// "resets 4 h 58 min later" while the reset is ahead, "reset 6 min later" once passed, "" when unknown.
    static func resetText(_ row: UsageObservation, now: Int) -> String {
        guard let reset = row.resetsAt, Self.validInstants.contains(reset), Self.validInstants.contains(row.observedAt),
            reset > row.observedAt
        else { return "" }
        let minutes = (reset - row.observedAt) / 60_000
        let verb = reset > now ? "resets" : "reset"
        return "\(verb) \(DurationText.short(minutes: minutes)) later"
    }
}

/// "6 min", "5 h", "4 h 58 min".
enum DurationText {
    static func short(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}

/// The usage cell for one account: what the provider reported at the last warm-up.
public struct UsageCell: Sendable, Equatable {
    /// "96% left · resets 13:02", "Ended 13:04", "No usage seen yet" (app 0.7.0: no "seen" part, which
    /// is `seen`). With no percent and no reset it stays "seen 08:00" and `seen` is nil.
    public let main: String
    /// `main` without its "seen" part, for the menu.
    public let brief: String
    /// "Week: 12% used, resets Sun 09:00", when a window of a day or more was reported.
    public let weekly: String?
    /// The used part of the short window, 0…1.
    public let fraction: Double?
    /// The short window's reset has passed.
    public let ended: Bool
    /// "Seen Tue 00:10": when the reading was taken; nil without usage, or when `main` already says it.
    public let seen: String?
    /// The pre-0.7.0 one-line form, "96% left · resets 13:02 · seen 08:00", which the CLI and `--json`
    /// keep byte for byte.
    public let line: String
}

public enum UsageText {
    public static let noUsage = "No usage seen yet"

    public static func cell(usage: AccountUsage?, now: Int, zone: String) -> UsageCell {
        guard let usage else {
            return UsageCell(
                main: Self.noUsage, brief: Self.noUsage, weekly: nil, fraction: nil, ended: false, seen: nil,
                line: Self.noUsage)
        }
        let time = UsageSummary.resetTime(usage.observedAt, zone: zone, now: now)
        let seen = "seen " + time
        let seenLine = "Seen " + time
        let weekly = Self.weekly(usage, zone: zone, now: now)
        guard let short = UsageLog.shortWindow(usage) else {
            let brief = "No short window"
            return UsageCell(
                main: brief, brief: brief, weekly: weekly, fraction: nil, ended: false, seen: seenLine,
                line: "\(brief) · \(seen)")
        }
        let used = short.usedPercent.map { min(100, max(0, $0)) }
        if let reset = short.resetsAt, reset <= now {
            let brief = "Ended " + UsageSummary.resetTime(reset, zone: zone, now: now)
            return UsageCell(
                main: brief, brief: brief, weekly: weekly, fraction: nil, ended: true, seen: seenLine,
                line: "\(brief) · \(seen)")
        }
        var parts: [String] = []
        if let used { parts.append("\(Int((100 - used).rounded(.down)))% left") }
        if let reset = short.resetsAt { parts.append("resets " + UsageSummary.resetTime(reset, zone: zone, now: now)) }
        // Nothing but the time: `main` stays "seen 08:00" and the time is not shown twice.
        guard !parts.isEmpty else {
            return UsageCell(
                main: seen, brief: seen, weekly: weekly, fraction: used.map { $0 / 100 }, ended: false, seen: nil,
                line: seen)
        }
        let brief = parts.joined(separator: " · ")
        return UsageCell(
            main: brief, brief: brief, weekly: weekly, fraction: used.map { $0 / 100 }, ended: false, seen: seenLine,
            line: "\(brief) · \(seen)")
    }

    /// A reading older than this reads as old on Accounts and in the menu header (app 0.7.0).
    public static let staleAfter = 24 * 3_600_000
    /// Past this, a weekday alone is ambiguous: the date is named instead.
    static let weekdayLimit = 6 * 24 * 3_600_000

    /// "last seen Tue", or "last seen 18 Nov" past 6 days; nil while the reading is 24 hours old or less.
    public static func lastSeen(observedAt: Int, now: Int, zone: String) -> String? {
        let age = now - observedAt
        guard age > Self.staleAfter else { return nil }
        let pattern = age > Self.weekdayLimit ? "d MMM" : "EEE"
        return "last seen " + LocalTime.format(observedAt, zone: zone, pattern: pattern)
    }

    /// "Work  ·  96% left · resets 13:02": no "seen" part (the menu's section header says when).
    public static func menuLine(label: String, cell: UsageCell) -> String { "\(label)  ·  \(cell.brief)" }

    static func weekly(_ usage: AccountUsage, zone: String, now: Int) -> String? {
        let long = [usage.primary, usage.secondary].compactMap { $0 }
            .first { ($0.windowMinutes ?? 0) >= UsageLog.shortWindowLimitMinutes }
        guard let long else { return nil }
        let name = long.windowMinutes == 10_080 ? "Week" : UsageSummary.windowName(long.windowMinutes)
        var parts: [String] = []
        if let used = long.usedPercent { parts.append("\(UsageSummary.percent(min(100, max(0, used)))) used") }
        if let reset = long.resetsAt {
            parts.append(
                reset <= now
                    ? "ended " + UsageSummary.resetTime(reset, zone: zone, now: now)
                    : "resets " + UsageSummary.resetTime(reset, zone: zone, now: now))
        }
        return parts.isEmpty ? nil : "\(name): \(parts.joined(separator: ", "))"
    }
}
