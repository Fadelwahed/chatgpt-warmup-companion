import Foundation

// App 0.6 Schedule text: spacing advice (F7), the row selected on open (X5), row words and folded
// future days (X6). Pure functions over status, projection and the app's usage log.

/// Advice when two times are closer than the observed short window plus 10 minutes.
public enum SpacingAdvice {
    public static let marginMinutes = 10
    static let lastMinute = 23 * 60 + 55

    /// One sentence per close pair of consecutive times on the same day ("HH:mm", any order; no
    /// overnight wrap). Nothing without an observed window length.
    public static func make(times: [String], windowMinutes: Int?) -> [String] {
        guard let window = windowMinutes, window > 0 else { return [] }
        let minutes = Set(times.compactMap(Self.minutes)).sorted()
        return zip(minutes, minutes.dropFirst()).compactMap { earlier, later in
            let gap = later - earlier
            guard gap < window + Self.marginMinutes else { return nil }
            let first = Self.clock(earlier)
            let second = Self.clock(later)
            let sentence: String
            if gap == window {
                sentence =
                    "\(second) is exactly \(Self.span(window)) after \(first). A warm-up can land just before the "
                    + "earlier window resets and start nothing."
            } else if gap > window {
                sentence =
                    "\(second) is \(Self.span(gap)) after \(first). A warm-up can land just before the earlier "
                    + "window resets and start nothing."
            } else {
                sentence =
                    "\(second) is \(Self.span(gap)) after \(first), inside the window it starts. It will not start "
                    + "a fresh one."
            }
            let suggested = Int((Double(earlier + window + Self.marginMinutes) / 5).rounded(.up)) * 5
            return suggested > Self.lastMinute ? sentence : "\(sentence) Try \(Self.clock(suggested))."
        }
    }

    /// The most common short window length among the log's rows (the log keeps 60 days); ties go to
    /// the larger. Nil when none was observed.
    public static func observedWindow(log: UsageLog) -> Int? {
        var counts: [Int: Int] = [:]
        for row in log.rows {
            guard let minutes = row.windowMinutes, (1..<UsageLog.shortWindowLimitMinutes).contains(minutes) else {
                continue
            }
            counts[minutes, default: 0] += 1
        }
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    /// "5 hours", "1 hour", "45 min", "5 h 5 min".
    static func span(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return DurationText.short(minutes: minutes)
    }

    static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let hour = Int(parts[0]),
            let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// The Schedule row selected on open (X5).
public enum ScheduleSelection {
    /// The unseen problem's slot, else the latest finished time today, else the next upcoming one,
    /// else nil. `today` is today's projected admissions; `now` is epoch milliseconds.
    public static func initial(unseenProblem: String?, today: [ProjectedAdmission], now: Int) -> String? {
        if let unseenProblem { return unseenProblem }
        let timed = today.compactMap { admission in admission.at.map { (admission, $0) } }
        if let finished = timed.filter({ $0.1 <= now }).max(by: { $0.1 < $1.1 }) { return finished.0.slot }
        return timed.filter { $0.1 > now }.min { $0.1 < $1.1 }?.0.slot
    }
}

/// Words for one Schedule row (X6): past rows carry the week strip's mark, the next row a countdown.
public enum ScheduleRowText {
    /// "✓ Confirmed", "✕ Missed: nothing ran at that minute", "– Skipped: scheduling was paused",
    /// "Next · in 2 h", "Upcoming". `mark` is the week strip's mark for this time, when recorded.
    public static func words(admission: ProjectedAdmission, mark: WeekDay.Mark?, isNext: Bool, now: Int) -> String {
        let past = admission.at.map { $0 <= now } ?? (admission.state != "upcoming")
        if !past {
            guard isNext, let at = admission.at else { return "Upcoming" }
            let due = Date(timeIntervalSince1970: Double(at) / 1000)
            return "Next · " + Countdown.phrase(from: Date(timeIntervalSince1970: Double(now) / 1000), to: due)
        }
        if let cause = admission.cause {
            let glyph = SlotProblem.operatorChosenCauses.contains(cause) ? TodayMark.Kind.skipped : .missed
            return "\(glyph.glyph) " + Self.capitalized(Wording.admission(state: admission.state, cause: cause))
        }
        if let mark {
            let kind = TodayMark.Kind(mark)
            return "\(kind.glyph) " + Self.capitalized(kind.words)
        }
        if admission.state == "paused" { return "\(TodayMark.Kind.skipped.glyph) Paused" }
        return Self.capitalized(Wording.admission(state: admission.state, cause: nil))
    }

    /// A recorded past time ("Earlier this week"): "✓ Confirmed", "✕ Missed".
    public static func past(_ mark: WeekDay.Mark) -> String {
        let kind = TodayMark.Kind(mark)
        return "\(kind.glyph) " + Self.capitalized(kind.words)
    }

    /// A day the schedule leaves out: "– Skipped: time off", "– Skipped: day off".
    public static func excluded(_ exclusion: String) -> String {
        let words =
            switch exclusion {
            case "vacation": "time off"
            case "weekday": "day off"
            default: Wording.code(exclusion)
            }
        return "\(TodayMark.Kind.skipped.glyph) Skipped: \(words)"
    }

    /// The secondary label on a Today row whose time is not one of the every-day times (app 0.7.0).
    public static let todayOnly = "today only"

    /// `todayOnly` for an upcoming time in the projection's today whose logical time is not among the
    /// projection's every-day times (a time added for today, or one that changes from tomorrow); nil
    /// for a past time, an every-day time or no projection.
    public static func todayOnly(admission: ProjectedAdmission, projection: ScheduleProjection?, now: Int) -> String? {
        guard let projection,
            let today = projection.days.first(where: { $0.date == projection.localDate }),
            today.admissions.contains(where: { $0.id == admission.id })
        else { return nil }
        let past = admission.at.map { $0 <= now } ?? (admission.state != "upcoming")
        guard !past, !projection.times.contains(admission.logicalTime) else { return nil }
        return self.todayOnly
    }

    static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}

/// Wake marks on Schedule (work order 132): one word per upcoming time today, a count per coming
/// day and one line on how far the bookings reach. Nothing when the wake read is unknown.
public enum ScheduleWakeText {
    public static let booked = "wake booked"
    public static let notBooked = "no wake"
    public static let bookedSymbol = "alarm"

    /// "wake booked" or "no wake" for a time still to come; nil for a past time or an unknown wake.
    public static func row(admission: ProjectedAdmission, plan: WakePlan, now: Int) -> String? {
        let past = admission.at.map { $0 <= now } ?? (admission.state != "upcoming")
        guard !past else { return nil }
        switch plan.readiness(admission.id) {
        case .ready: return self.booked
        case .notScheduled: return self.notBooked
        case .unknown: return nil
        }
    }

    /// "3 wakes booked", "1 of 3 wakes booked" or "no wakes booked" for a coming day's times. Nil when
    /// the day has none or any of them is not in the plan.
    public static func day(_ admissions: [ProjectedAdmission], plan: WakePlan) -> String? {
        let readiness = admissions.map { plan.readiness($0.id) }
        guard !readiness.isEmpty, !readiness.contains(.unknown) else { return nil }
        let total = readiness.count
        let booked = readiness.filter { $0 != .notScheduled }.count
        let noun = total == 1 ? "wake" : "wakes"
        if booked == 0 { return "no wakes booked" }
        if booked == total { return "\(total) \(noun) booked" }
        return "\(booked) of \(total) \(noun) booked"
    }

    /// The line under the schedule summary. Nil when the wake read is unknown or scheduling is paused.
    public static func summary(plan: WakePlan, scheduleEnabled: Bool) -> String? {
        guard plan.isKnown, scheduleEnabled else { return nil }
        if let last = plan.lastBookedDay { return "Wakes booked through \(FriendlyTime.day(last, today: nil))." }
        // `hasRepeating` is true for any repeating event (a repeating sleep too): require a match.
        if plan.hasRepeating, plan.bySlot.values.contains(where: { $0 != .notScheduled && $0 != .unknown }) {
            return "A repeating wake is set."
        }
        return "No wakes booked. A warm-up is missed if the Mac is asleep at its time."
    }
}

/// Future days that only repeat the recurring times fold to one line each (X6).
public enum ScheduleFold {
    public enum Row: Sendable, Equatable, Identifiable {
        /// "Tomorrow, Sun 22 Nov · 08:00, 13:00, 18:00"
        case folded(date: String, text: String)
        /// A day that differs (moved time, time off, clock change, missing time) stays expanded.
        case expanded(ProjectedDay)

        public var id: String {
            switch self {
            case let .folded(date, _): date
            case let .expanded(day): day.date
            }
        }
    }

    /// Rows for the days after the projection's local date, in order. Folded rows are named against
    /// `today`, the current date in the schedule zone (`ScheduleDayName.coming`), never the projection's
    /// own date, so a projection left from yesterday does not call today "Tomorrow" (060-FIX7 item 4).
    public static func days(projection: ScheduleProjection, recurring: [String], today: String?) -> [Row] {
        projection.days.filter { $0.date > projection.localDate }.map { day in
            guard Self.matches(day, recurring: recurring) else { return .expanded(day) }
            let title = ScheduleDayName.coming(day.date, today: today)
            return .folded(date: day.date, text: "\(title) · \(recurring.joined(separator: ", "))")
        }
    }

    static func matches(_ day: ProjectedDay, recurring: [String]) -> Bool {
        guard day.exclusion == nil, !recurring.isEmpty, day.admissions.map(\.admission) == recurring else {
            return false
        }
        return day.admissions.allSatisfy { admission in
            admission.admission == admission.logicalTime && admission.cause == nil
                && admission.repeatedLocalTime == nil && admission.state == "upcoming"
        }
    }
}

/// Day headings on Schedule (060-FIX6 item 5). "Today" names only the current date in the schedule
/// zone (`FriendlyTime.today(zone:)`), never the projection's own date, so a projection left from
/// yesterday after a failed read is not labelled "Today"; every other day gets its weekday and date.
public enum ScheduleDayName {
    /// "Today, Sun 22 Nov" or "Mon 23 Nov".
    public static func name(_ date: String, today: String?) -> String {
        let full = FriendlyTime.day(date, today: nil)
        return date == today ? "Today, \(full)" : full
    }

    /// A folded coming day: "Today, Sun 22 Nov", "Tomorrow, Mon 23 Nov" or "Tue 24 Nov".
    public static func coming(_ date: String, today: String?) -> String {
        guard FriendlyTime.day(date, today: today) == "Tomorrow" else { return self.name(date, today: today) }
        return "Tomorrow, \(FriendlyTime.day(date, today: nil))"
    }

    /// "Today, Sun 22 Nov · 3 warm-ups", "Mon 23 Nov · 1 warm-up".
    public static func title(_ date: String, count: Int, today: String?) -> String {
        "\(self.name(date, today: today)) · \(count) warm-up\(count == 1 ? "" : "s")"
    }
}
