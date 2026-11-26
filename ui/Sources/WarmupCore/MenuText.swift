import Foundation

// App 0.6 menu text (F9, plan 6.2): every menu line is built here as plain text, so the menu stays a
// native NSMenu and the words are tested. Nothing here reads or sends anything.

/// One of today's times with its mark, for the menu's Today line and the CLI.
public struct TodayMark: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case confirmed, uncertain, problem, missed, skipped, upcoming

        public init(_ mark: WeekDay.Mark) {
            switch mark {
            case .confirmed: self = .confirmed
            case .uncertain: self = .uncertain
            case .problem: self = .problem
            case .missed: self = .missed
            case .skipped: self = .skipped
            }
        }

        public var glyph: String {
            switch self {
            case .confirmed: "✓"
            case .uncertain: "?"
            case .problem: "!"
            case .missed: "✕"
            case .skipped: "–"
            case .upcoming: "○"
            }
        }

        public var words: String {
            switch self {
            case .upcoming: "upcoming"
            case .confirmed: WeekDay.Mark.confirmed.words
            case .uncertain: WeekDay.Mark.uncertain.words
            case .problem: WeekDay.Mark.problem.words
            case .missed: WeekDay.Mark.missed.words
            case .skipped: WeekDay.Mark.skipped.words
            }
        }
    }

    /// The configured time ("13:00"): the slot's key, for clicks and identity.
    public let time: String
    public let kind: Kind
    /// The local date ("2026-11-22") the mark belongs to, when known.
    public let date: String?
    /// The time it runs today ("13:10" after a move), shown to people; `time` when not moved.
    public let shown: String

    public init(time: String, kind: Kind, date: String? = nil, shown: String? = nil) {
        self.time = time
        self.kind = kind
        self.date = date
        self.shown = shown ?? time
    }

    /// The full slot label ("2026-11-22T13:00") a click opens; nil without a date.
    public var slot: String? { self.date.map { "\($0)T\(self.time)" } }

    /// Said in place of today's marks while no schedule projection has been read.
    public static let unavailableText = "Schedule not available"

    /// Today's marks from the week strip's day (recorded evidence) and today's projected admissions
    /// (what is still to come). A recorded mark wins; a time with no record is upcoming while its
    /// admission has not passed, skipped when paused or skipped by choice, missed with another
    /// cause, and uncertain otherwise. Without a projection (`available` false) there are no marks:
    /// recorded ones alone would hide the times still to come.
    /// `ledger` is the engine's record of times that passed unsent: a recorded one keeps the minute
    /// it was due then, even if the time was moved again later (0.6.8 review round 2).
    public static func make(
        week: WeekDay?, admissions: [ProjectedAdmission], now: Int, available: Bool = true, ledger: [LedgerRow] = []
    ) -> [TodayMark] {
        guard available else { return [] }
        var byTime: [String: Kind] = [:]
        for slot in week?.slots ?? [] { byTime[slot.time] = Kind(slot.mark) }
        for admission in admissions where byTime[String(admission.slot.suffix(5))] == nil {
            byTime[String(admission.slot.suffix(5))] = Self.kind(admission, now: now)
        }
        // A time moved for today (or for every day) is shown at the minute it runs, as on Schedule. The
        // marks are keyed by time alone, so both sources are keyed on one day before the shared rule.
        let day = week?.date ?? "today"
        let runs = RunTimes.resolve(
            projected: admissions.map { (slot: "\(day)T\($0.slot.suffix(5))", time: $0.admission) },
            recorded: ledger.filter { $0.slot.hasPrefix((week?.date ?? "") + "T") }
                .map { (slot: "\(day)T\($0.slot.suffix(5))", time: $0.admission) })
        return byTime.map { TodayMark(time: $0.key, kind: $0.value, shown: runs.time(of: "\(day)T\($0.key)")) }
            .sorted { ($0.shown, $0.time) < ($1.shown, $1.time) }
    }

    /// Today's marks for `today` (060-FIX4 item 3), each carrying its full slot label; nil while the
    /// projection cannot speak for that date (`ProjectionCheck.current`). The caller passes the date
    /// it shows, so after midnight a kept projection without the new date is "Schedule not
    /// available", never yesterday's marks.
    public static func marks(
        projection: ScheduleProjection?, status: EngineStatus, week: [WeekDay], today: String?, now: Int
    ) -> [TodayMark]? {
        guard let today, let projection, ProjectionCheck.current(projection: projection, status: status, today: today)
        else { return nil }
        let admissions = projection.days.first { $0.date == today }?.admissions ?? []
        let day = week.first { $0.date == today }
        return Self.make(week: day, admissions: admissions, now: now, ledger: day == nil ? [] : status.slotLedger).map {
            TodayMark(time: $0.time, kind: $0.kind, date: today, shown: $0.shown)
        }
    }

    /// What the Overview Today section says when there are no marks: "No warm-ups today", or
    /// "Schedule not available" while no projection has been read.
    public static func emptyText(available: Bool) -> String {
        available ? "No warm-ups today" : Self.unavailableText
    }

    /// The line under an Overview Today cell: "Confirmed", "Had problems", "Upcoming", or the
    /// countdown ("In 2 h 15 min") when one is given for the next time.
    public func cellWords(countdown: String?) -> String {
        let words = self.kind == .upcoming ? countdown ?? self.kind.words : self.kind.words
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "HH:mm" in ASCII digits, the only shape shown in place of the configured time.
    static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { ("0"..."9").contains($0) } }),
            let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return false }
        return hour < 24 && minute < 60
    }

    static func kind(_ admission: ProjectedAdmission, now: Int) -> Kind {
        if let cause = admission.cause {
            return SlotProblem.operatorChosenCauses.contains(cause) ? .skipped : .missed
        }
        if admission.state == "paused" { return .skipped }
        let passed = admission.at.map { $0 <= now } ?? (admission.state != "upcoming")
        return passed ? .uncertain : .upcoming
    }
}

/// Whether a kept schedule projection can speak for today (060-FIX3 item 5): only when it was read
/// for the current schedule revision and zone and lists today's date. Otherwise Today says
/// "Schedule not available" rather than trusting an older, possibly empty, projection.
public enum ProjectionCheck {
    public static func current(projection: ScheduleProjection, status: EngineStatus, today: String) -> Bool {
        Self.sameSchedule(projection: projection, status: status) && projection.days.contains { $0.date == today }
    }

    /// The projection was read for the status's schedule: same revision and zone.
    public static func sameSchedule(projection: ScheduleProjection, status: EngineStatus) -> Bool {
        projection.scheduleRevision == status.scheduleRevision && projection.zone == status.schedule.zone
    }
}

public struct TodayLine: Sendable, Equatable {
    /// "Today:  ✓ 08:00   ○ 13:00   ○ 18:00"
    public let title: String
    /// "Today: 08:00 confirmed, 13:00 upcoming, 18:00 upcoming."
    public let accessibilityLabel: String
}

public enum MenuText {
    public static let accountsHeader = "Accounts · seen at the last warm-up"

    /// The Accounts section header: `accountsHeader` while every reading is 24 hours old or less,
    /// otherwise "Accounts · last seen Tue 00:10" for the oldest one ("18 Nov 00:10" past 6 days). Only
    /// accounts that are not turned off (`turnedOff` enrollment IDs) and have a reading count.
    public static func accountsTitle(accounts: [AccountState], turnedOff: Set<String>, now: Int, zone: String)
        -> String
    {
        let oldest = accounts.filter { !turnedOff.contains($0.enrollmentId) }.compactMap { $0.usage?.observedAt }.min()
        guard let oldest, now - oldest > UsageText.staleAfter else { return Self.accountsHeader }
        let pattern = now - oldest > UsageText.weekdayLimit ? "d MMM HH:mm" : "EEE HH:mm"
        return "Accounts · last seen " + LocalTime.format(oldest, zone: zone, pattern: pattern)
    }

    /// `available` is false while no schedule projection has been read: the line then says so
    /// instead of claiming there are no warm-ups.
    public static func today(marks: [TodayMark], available: Bool = true) -> TodayLine {
        guard available else {
            return TodayLine(
                title: "Today:  \(TodayMark.unavailableText)",
                accessibilityLabel: "Today: \(TodayMark.unavailableText.lowercased()).")
        }
        guard !marks.isEmpty else {
            return TodayLine(title: "Today:  no warm-ups", accessibilityLabel: "Today: no warm-ups.")
        }
        let title = "Today:  " + marks.map { "\($0.kind.glyph) \($0.shown)" }.joined(separator: "   ")
        let spoken = "Today: " + marks.map { "\($0.shown) \($0.kind.words)" }.joined(separator: ", ") + "."
        return TodayLine(title: title, accessibilityLabel: spoken)
    }

    /// The full slot the Today line opens on Schedule (060-FIX5 item 4): the first upcoming mark, else
    /// the latest one; nil without dated marks.
    public static func todayTarget(marks: [TodayMark]) -> String? {
        (marks.first { $0.kind == .upcoming } ?? marks.last)?.slot
    }

    /// The menu header: the headline, the countdown while the next time is its subject, then today's
    /// note: "Next 08:00 · in 4 h 57 min · 1 missed today", "All good · next 13:00 · in 2 h".
    public static func header(glance: Glance, status: EngineStatus?, now: Date) -> String {
        var title = glance.headline
        if glance.state == .scheduled, let status, let next = status.next,
            let due = Countdown.date(of: next, zone: status.schedule.zone)
        {
            title += " · \(Countdown.phrase(from: now, to: due))"
        }
        return glance.todayNote.map { "\(title) · \($0)" } ?? title
    }

    /// The menu-bar item's tooltip and spoken label: "Warm-up: Next 08:00 · 1 missed today".
    public static func itemLabel(glance: Glance) -> String {
        "Warm-up: \(glance.headlineWithNote)"
    }

    /// The attention line, only while the latest problem is unseen; nil otherwise.
    public static func attention(glance: Glance) -> String? {
        glance.unseenProblemSlot == nil ? nil : glance.headline
    }

    /// "2 new sends without a result", or nil for none. Count only rows newer than the last review.
    public static func unreviewed(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 new send without a result" : "\(count) new sends without a result"
    }

    /// One line per account in order, at most `limit`, then "5 accounts…". Labels fall back to "Account N".
    public static func accounts(cells: [(account: String, cell: UsageCell)], labels: [String: String], limit: Int = 4)
        -> [String]
    {
        let lines = cells.prefix(max(0, limit)).enumerated().map { index, entry in
            UsageText.menuLine(label: labels[entry.account] ?? "Account \(index + 1)", cell: entry.cell)
        }
        return cells.count > limit ? lines + ["\(cells.count) accounts…"] : lines
    }
}

/// What the menu-bar item shows beside its icon. Stored in UserDefaults by its raw value.
public enum MenuBarMode: String, Sendable, Equatable, CaseIterable {
    case iconOnly, timeLeft, nextTime

    /// "2h 15m" (time left), "13:00" (next time) or nil (icon only, or no next time).
    public func title(for next: NextSlot?, zone: String, now: Date) -> String? {
        guard let next else { return nil }
        switch self {
        case .iconOnly: return nil
        case .timeLeft: return Countdown.date(of: next, zone: zone).map { Countdown.compact(from: now, to: $0) }
        case .nextTime: return next.admission
        }
    }

    /// The 0.5 countdown switch: on becomes Time left, off Icon only.
    public static func migrated(oldCountdownSwitch: Bool) -> MenuBarMode { oldCountdownSwitch ? .timeLeft : .iconOnly }
}
