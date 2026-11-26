import Foundation

// App 0.3 evidence views: the engine work lock, usage windows, the app's own sleep journal and the
// weekly outcomes report. All are read-only views of recorded evidence; none sends a request.

enum LocalTime {
    static func format(_ milliseconds: Int, zone: String, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: zone) ?? .current
        formatter.dateFormat = pattern
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// "14:05", or "2026-11-20 14:05" when `milliseconds` is on an earlier local day than `reference`.
    static func short(_ milliseconds: Int, reference: Int, zone: String) -> String {
        let sameDay =
            self.format(milliseconds, zone: zone, pattern: "yyyy-MM-dd")
            == self.format(reference, zone: zone, pattern: "yyyy-MM-dd")
        return self.format(milliseconds, zone: zone, pattern: sameDay ? "HH:mm" : "yyyy-MM-dd HH:mm")
    }
}

/// Names what holds the engine's work lock, so a stopped heartbeat has a stated cause.
public enum WorkLockCheck {
    /// A live owner is normal while a batch runs; it is worth a note only after this long.
    public static let busyNoteAfterMilliseconds = 10 * 60_000

    public static func note(_ status: EngineStatus, observedAt: Int?) -> String? {
        guard let lock = status.workLock, let observedAt else { return nil }
        let zone = status.schedule.zone
        let since = lock.since.map { " since " + LocalTime.short($0, reference: observedAt, zone: zone) } ?? ""
        switch lock.state {
        case "stale":
            return
                "The engine is busy\(since): a stopped process left it held. The engine clears this at a later check when no other recovery is running."
        case "unknown":
            return
                "The engine is busy\(since) and Warm-up cannot tell why, so checks wait. Pause and resume scheduling to clear a stopped process."
        case "held":
            guard let start = lock.since, observedAt - start >= self.busyNoteAfterMilliseconds else { return nil }
            return "The engine has been busy\(since)."
        default:
            return nil
        }
    }
}

/// One line per account from the usage headers seen at the last send.
public enum UsageSummary {
    public static func windowName(_ minutes: Int?) -> String {
        guard let minutes else { return "Usage window" }
        if minutes == 10_080 { return "Weekly window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }

    /// "5-hour window 42% used, resets 13:30. Weekly window 12% used, resets Fri 09:00. Seen at 08:00."
    public static func line(_ usage: AccountUsage, zone: String, now: Int) -> String? {
        let parts = [usage.primary, usage.secondary].compactMap { window -> String? in
            guard let window else { return nil }
            var text = self.windowName(window.windowMinutes)
            if let used = window.usedPercent { text += " \(Self.percent(used)) used" }
            if let reset = window.resetsAt {
                text += reset <= now ? ", reset since" : ", resets " + self.resetTime(reset, zone: zone, now: now)
            }
            return text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ". ") + ". Seen at "
            + LocalTime.short(usage.observedAt, reference: now, zone: zone) + "."
    }

    static func percent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    static func resetTime(_ reset: Int, zone: String, now: Int) -> String {
        let sameDay =
            LocalTime.format(reset, zone: zone, pattern: "yyyy-MM-dd")
            == LocalTime.format(now, zone: zone, pattern: "yyyy-MM-dd")
        return LocalTime.format(reset, zone: zone, pattern: sameDay ? "HH:mm" : "EEE HH:mm")
    }
}

/// Sleep and wake times this app observed while it was running. It is the app's own record: it
/// says nothing about periods when Warm-up was not open, and it never claims more than it saw.
public struct SleepJournal: Codable, Sendable, Equatable {
    /// `launch` marks a new app session: a sleep is never paired with a wake across one, because
    /// the Mac may have shut down or the app may have quit in between.
    public enum Kind: String, Codable, Sendable { case sleep, wake, launch }

    public struct Event: Codable, Sendable, Equatable {
        public let kind: Kind
        public let at: Int
    }

    public static let retentionMilliseconds = 14 * 86_400_000
    public static let maxEvents = 400

    public private(set) var events: [Event] = []

    public init(events: [Event] = []) { self.events = events.sorted { $0.at < $1.at } }

    public mutating func record(_ kind: Kind, at: Int) {
        if let last = self.events.last, at < last.at { return }  // the clock moved back: keep order
        self.events.append(Event(kind: kind, at: at))
        let cutoff = at - Self.retentionMilliseconds
        self.events.removeAll { $0.at < cutoff }
        if self.events.count > Self.maxEvents { self.events.removeFirst(self.events.count - Self.maxEvents) }
    }

    /// The recorded sleep that covers the whole interval: the latest event at or before `from` is a
    /// sleep, and the very next event is a wake at or after `to` (no launch or second sleep between).
    public func asleep(from: Int, to: Int) -> (from: Int, to: Int)? {
        guard let index = self.events.lastIndex(where: { $0.at <= from }), self.events[index].kind == .sleep,
            index + 1 < self.events.count
        else { return nil }
        let next = self.events[index + 1]
        guard next.kind == .wake, next.at >= to else { return nil }
        return (self.events[index].at, next.at)
    }

    /// For a not-admitted slot whose whole admission minute falls inside a recorded sleep. It states
    /// only what was recorded, not the cause.
    public func explanation(admissionAt: Int, zone: String) -> String? {
        guard let span = self.asleep(from: admissionAt, to: admissionAt + 60_000) else { return nil }
        let from = LocalTime.short(span.from, reference: admissionAt, zone: zone)
        let to = LocalTime.short(span.to, reference: admissionAt, zone: zone)
        return "Warm-up recorded the Mac asleep from \(from) to \(to), which covers that minute."
    }
}

/// Increment C: a seven-day outcomes report built from the same evidence as the "This week" strip.
public struct WeekReport: Sendable, Equatable {
    public struct AccountLine: Sendable, Equatable, Identifiable {
        public let enrollmentId: String
        public let sent: Int
        public let confirmed: Int
        public var id: String { self.enrollmentId }
    }

    public struct Cause: Sendable, Equatable {
        public let cause: String
        public let count: Int
    }

    public let firstDate: String
    public let lastDate: String
    public let days: Int
    public let slots: Int
    public let confirmed: Int
    public let uncertain: Int
    public let problems: Int
    public let missed: Int
    /// Skipped by the operator's own choice: a pause, a recovery boundary, or no account selected.
    public let skippedByChoice: Int
    /// Batches that ran but sent nothing (cooldown, pilot or correction needed): they count.
    public let notSent: Int
    public let manual: Int
    /// Not-admitted causes in the seven days, most frequent first.
    public let causes: [Cause]
    public let accounts: [AccountLine]
    /// The history read was cut at its row limit, so older days may be incomplete.
    public let truncated: Bool
    /// Status lists at most 50 not-admitted slots; when the oldest listed one is inside the week,
    /// older misses in the week may be missing from the counts.
    public let ledgerMayBeCut: Bool
    /// When the evidence was read (epoch milliseconds).
    public let asOf: Int
    /// "Nothing ran" misses in the week whose minute the app's sleep journal records the Mac asleep through.
    public internal(set) var asleepNoTick = 0

    /// `asleepSlots`: slot labels whose due minute the app recorded the Mac asleep through.
    public static func make(
        week: [WeekDay], status: EngineStatus, history: [HistoryEntry], truncated: Bool, asOf: Int,
        asleepSlots: Set<String> = []
    ) -> WeekReport {
        let dates = Set(week.map(\.date))
        // Slots where every account was held back by its daily cap are the operator's choice too.
        var capped: [String: [HistoryEntry]] = [:]
        for row in history where row.mode == "scheduled" {
            if let slot = row.slot { capped[slot, default: []].append(row) }
        }
        let cappedSlots = capped.filter { _, rows in
            rows.allSatisfy { SlotProblem.chosenSkipReasons.contains($0.reason ?? "") && $0.batchOutcome != "blocked" }
        }.keys
        let chosen = Set(cappedSlots).union(
            status.slotLedger.filter { SlotProblem.operatorChosenCauses.contains($0.cause) }.map(\.slot)
                + [status.lastSlotOutcome].compactMap { $0?.outcome == "idle" ? $0?.slot : nil })
        var counts: [WeekDay.Mark: Int] = [:]
        var byChoice = 0
        for day in week {
            for slot in day.slots {
                if slot.mark == .skipped, chosen.contains("\(day.date)T\(slot.time)") {
                    byChoice += 1
                } else {
                    counts[slot.mark, default: 0] += 1
                }
            }
        }
        var causes: [String: Int] = [:]
        var asleepNoTick = 0
        for row in status.slotLedger
        where dates.contains(String(row.slot.prefix(10))) && !SlotProblem.operatorChosenCauses.contains(row.cause) {
            causes[row.cause, default: 0] += 1
            if row.cause == Self.noTickCause, asleepSlots.contains(row.slot) { asleepNoTick += 1 }
        }
        var sent: [String: Int] = [:]
        var confirmed: [String: Int] = [:]
        for row in history where row.mode == "scheduled" {
            guard let id = row.enrollmentId, let slot = row.slot, dates.contains(String(slot.prefix(10))) else {
                continue
            }
            if row.dispatched == true { sent[id, default: 0] += 1 }
            if row.status == "success" { confirmed[id, default: 0] += 1 }
        }
        let accounts = Set(sent.keys).union(confirmed.keys).sorted().map {
            AccountLine(enrollmentId: $0, sent: sent[$0] ?? 0, confirmed: confirmed[$0] ?? 0)
        }
        let ordered = causes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return WeekReport(
            firstDate: week.first?.date ?? "", lastDate: week.last?.date ?? "", days: week.count,
            slots: counts.values.reduce(0, +) + byChoice,
            confirmed: counts[.confirmed] ?? 0, uncertain: counts[.uncertain] ?? 0, problems: counts[.problem] ?? 0,
            missed: counts[.missed] ?? 0, skippedByChoice: byChoice, notSent: counts[.skipped] ?? 0,
            manual: week.map(\.manualRuns).reduce(0, +),
            causes: ordered.map { Cause(cause: $0.key, count: $0.value) },
            accounts: accounts, truncated: truncated,
            ledgerMayBeCut: status.slotLedger.count >= Self.ledgerLimit
                && (status.slotLedger.map(\.slot).min().map { String($0.prefix(10)) >= (week.first?.date ?? "") }
                    ?? false),
            asOf: asOf, asleepNoTick: asleepNoTick)
    }

    static let ledgerLimit = 50
    static let noTickCause = "no_tick_between"

    /// "14 missed: nothing ran at that minute ×10 (7 while the Mac was recorded asleep), Router needed a
    /// review ×4." States what was recorded; never that sleep caused a miss. Nil when nothing was missed.
    public var causeLine: String? {
        guard !self.causes.isEmpty else { return nil }
        let total = self.causes.map(\.count).reduce(0, +)
        let parts = self.causes.map { cause in
            let asleep =
                cause.cause == Self.noTickCause && self.asleepNoTick > 0
                ? " (\(self.asleepNoTick) while the Mac was recorded asleep)" : ""
            return "\(Wording.reason(cause.cause)) ×\(cause.count)\(asleep)"
        }
        return "\(total) missed: " + parts.joined(separator: ", ") + "."
    }

    /// "Read at Thu 12 Nov 14:05 (Asia/Gaza)" for the on-screen report.
    public func readTime(zone: String) -> String {
        "Read at " + LocalTime.format(self.asOf, zone: zone, pattern: "EEE d MMM HH:mm") + " (\(zone))"
    }

    /// Scheduled warm-ups that counted: only the operator's own skips are left out.
    public var counted: Int { self.slots - self.skippedByChoice }

    /// "2 of 6 scheduled warm-ups confirmed · 15–21 Nov".
    public var headline: String {
        let span = VacationText.span(start: self.firstDate, end: self.lastDate) ?? "the last \(self.days) days"
        guard self.counted > 0 else { return "No scheduled warm-ups recorded · \(span)" }
        return "\(self.confirmed) of \(self.counted) scheduled warm-ups confirmed · \(span)"
    }

    /// The breakdown on screen; the cause line sits under the headline instead (`causeLine`).
    public var details: [String] { self.lines(withCauses: false) }

    /// The breakdown; the copied report keeps its "Missed because" line in the same place.
    func lines(withCauses: Bool) -> [String] {
        var lines: [String] = []
        let other = [
            (self.uncertain, "uncertain"), (self.problems, "with problems"), (self.missed, "missed"),
            (self.notSent, "ran but sent nothing (cooling down, first manual warm-up or review needed)"),
            (self.skippedByChoice, "skipped by your pause or account selection, not counted"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if !other.isEmpty { lines.append("Also: " + other.joined(separator: "; ") + ".") }
        if withCauses, !self.causes.isEmpty {
            lines.append(
                "Missed because: "
                    + self.causes.map { "\(Wording.reason($0.cause)) ×\($0.count)" }.joined(separator: ", ")
                    + ".")
        }
        if self.manual > 0 { lines.append("\(self.manual) manual account \(self.manual == 1 ? "result" : "results").") }
        if self.truncated {
            lines.append("Only the most recent results fit in one read, so older days may be incomplete.")
        }
        if self.ledgerMayBeCut {
            lines.append(
                "The missed list reached its \(Self.ledgerLimit)-row limit; older misses in this week may be missing from these counts."
            )
        }
        return lines
    }

    /// Copyable text with account identifiers replaced by position, so it is safe to share. Unlike
    /// the screen, it keeps full dates and the engine's cause codes for whoever reads it later.
    public func text(zone: String) -> String {
        var lines = [
            "Warm-up weekly report (read \(LocalTime.format(self.asOf, zone: zone, pattern: "yyyy-MM-dd HH:mm")) \(zone))",
            self.headline,
        ]
        if !self.firstDate.isEmpty { lines.append("Dates: \(self.firstDate) to \(self.lastDate)") }
        lines += self.lines(withCauses: true)
        if !self.causes.isEmpty {
            lines.append("Cause codes: " + self.causes.map { "\($0.cause) ×\($0.count)" }.joined(separator: ", "))
        }
        for (index, account) in self.accounts.enumerated() {
            lines.append("Account \(index + 1): \(account.confirmed) confirmed of \(account.sent) sent")
        }
        return lines.joined(separator: "\n")
    }
}

/// The admission instant of a not-admitted ledger row, from the minute and zone recorded with the
/// miss (not today's schedule). Nil when the zone is unknown or that local minute was skipped or
/// repeated by a clock change, so a note can never name the wrong minute.
public enum LedgerInstant {
    public static func admissionAt(_ row: LedgerRow) -> Int? {
        guard let zone = TimeZone(identifier: row.zone), SlotProblem.isSlot(row.slot) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let label = "\(row.slot.prefix(10)) \(row.admission)"
        guard let date = formatter.date(from: label), formatter.string(from: date) == label else { return nil }
        // Any other instant within three hours that shows the same local minute means a fold
        // (30 minutes at Lord Howe, an hour usually, two hours at Troll): no single instant.
        for step in -12...12
        where step != 0
            && formatter.string(from: date.addingTimeInterval(Double(step) * 900)) == label
        {
            return nil
        }
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }
}
