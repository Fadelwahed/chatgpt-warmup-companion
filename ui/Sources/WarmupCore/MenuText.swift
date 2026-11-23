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

    public let time: String
    public let kind: Kind
    /// The local date ("2026-11-22") the mark belongs to, when known.
    public let date: String?

    public init(time: String, kind: Kind, date: String? = nil) {
        self.time = time
        self.kind = kind
        self.date = date
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
    public static func make(week: WeekDay?, admissions: [ProjectedAdmission], now: Int, available: Bool = true)
        -> [TodayMark]
    {
        guard available else { return [] }
        var byTime: [String: Kind] = [:]
        for slot in week?.slots ?? [] { byTime[slot.time] = Kind(slot.mark) }
        for admission in admissions {
            let time = String(admission.slot.suffix(5))
            guard byTime[time] == nil else { continue }
            byTime[time] = Self.kind(admission, now: now)
        }
        return byTime.sorted { $0.key < $1.key }.map { TodayMark(time: $0.key, kind: $0.value) }
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
        return Self.make(week: week.first { $0.date == today }, admissions: admissions, now: now).map {
            TodayMark(time: $0.time, kind: $0.kind, date: today)
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
        let title = "Today:  " + marks.map { "\($0.kind.glyph) \($0.time)" }.joined(separator: "   ")
        let spoken = "Today: " + marks.map { "\($0.time) \($0.kind.words)" }.joined(separator: ", ") + "."
        return TodayLine(title: title, accessibilityLabel: spoken)
    }

    /// The full slot the Today line opens on Schedule (060-FIX5 item 4): the first upcoming mark, else
    /// the latest one; nil without dated marks.
    public static func todayTarget(marks: [TodayMark]) -> String? {
        (marks.first { $0.kind == .upcoming } ?? marks.last)?.slot
    }

    /// The attention line, only while the latest problem is unseen; nil otherwise.
    public static func attention(glance: Glance) -> String? {
        glance.unseenProblemSlot == nil ? nil : glance.headline
    }

    /// "2 new possible sends with no result", or nil for none. Count only rows newer than the last review.
    public static func unreviewed(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 new possible send with no result" : "\(count) new possible sends with no result"
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
