import Foundation

// Read-only insights derived from validated engine replies and, for wake readiness, from the
// system's own `pmset -g sched` text. Nothing here sends a request or changes any state.

extension Wording {
    /// Full weekday names, for VoiceOver and headings. ISO numbering: 1 is Monday.
    public static func weekdayName(_ iso: Int) -> String {
        ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][max(0, min(7, iso))]
    }
}

/// When the next configured slot is due, and a short "in 2 h 15 min" phrase for it.
public enum Countdown {
    /// The moment `next` is admitted: the engine's own epoch when it sent one, otherwise the
    /// local date and time in the schedule's zone; nil when neither can be formed.
    public static func date(of next: NextSlot, zone: String) -> Date? {
        if let at = next.at { return Date(timeIntervalSince1970: Double(at) / 1000) }
        guard let timeZone = TimeZone(identifier: zone) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        return formatter.date(from: "\(next.date) \(next.admission)")
    }

    /// A compact form for the menu bar: "45m", "2h 15m", "3d", or "now".
    public static func compact(from now: Date, to due: Date) -> String {
        let minutes = Int((due.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }

    /// "in 45 min", "in 2 h 15 min", "in 3 days", or "now" once due.
    public static func phrase(from now: Date, to due: Date) -> String {
        let minutes = Int((due.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        if hours < 48 {
            let rest = minutes % 60
            return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
        }
        return "in \(hours / 24) days"
    }
}

/// A copyable, redacted summary of the whole engine state: codes, counts and local times only.
/// No installation ID, enrollment or reservation ID, account name or path appears in it.
public enum StatusDiagnostic {
    public static func text(_ status: EngineStatus, engineVersion: String?, appVersion: String?, observedAt: Date)
        -> String
    {
        let zone = status.schedule.zone
        let stamp = Self.local(observedAt, zone: zone)
        let safe = Self.safe
        var lines = [
            "Warm-up status at \(stamp) (\(safe(zone)), \(status.timeZoneMode == "local" ? "Mac local time" : "fixed zone"))",
            "Scheduling: \(status.scheduleEnabled ? "enabled" : "paused"), revision \(status.scheduleRevision)",
            "Job: \(safe(status.job)); compatibility: \(safe(status.compatibility)); recovery: \(safe(status.recovery))",
            "Weekdays: \((status.schedule.weekdays ?? Array(1...7)).map(Wording.weekday).joined(separator: " "))",
            "Last heartbeat: \(status.lastTick.map { Self.local(Date(timeIntervalSince1970: Double($0) / 1000), zone: zone) } ?? "none")",
            "Next slot: \(status.next.map { "\(safe($0.date)) \(safe($0.admission))" } ?? "none in 7 days")",
            "Accounts: \(status.enabled) enabled of \(status.enrolled), \(status.pilots) pilots",
            "Possible sends without an outcome: \(status.unresolved.count)\(status.unresolvedTruncated == true ? " or more (list cut)" : "")",
        ]
        if status.clockHold != nil { lines.append("Clock hold: yes (the clock moved backward)") }
        if let batch = status.activeBatch { lines.append("Active batch: \(safe(batch.slot)) \(safe(batch.state))") }
        if let lock = status.workLock { lines.append("Engine lock: \(safe(lock.state))") }
        if let last = status.lastSlotOutcome {
            let results = last.results ?? []
            let sent = results.filter { $0.dispatched == true }.count
            let confirmed = results.filter { $0.outcome == "success" }.count
            lines.append(
                "Last batch: \(safe(last.slot)) \(safe(last.outcome ?? "unknown")), \(sent) sent, \(confirmed) confirmed"
            )
        }
        for row in status.slotLedger.prefix(5) { lines.append("Not admitted: \(safe(row.slot)) \(safe(row.cause))") }
        lines.append("Engine: \(safe(engineVersion ?? "unknown")); app: \(safe(appVersion ?? "unknown"))")
        return lines.joined(separator: "\n")
    }

    /// Engine-supplied text is copied only in a known shape: a lowercase code (`no_tick_between`),
    /// a date, time or slot, a version (`2.0.1`), or a real time-zone name. Text that starts like an
    /// identifier (`acct_`, `enr_`, `install_` …) or contains this Mac's user name is withheld, and
    /// so is anything else, such as an account handle or a path.
    static func safe(_ value: String) -> String {
        let lower = value.lowercased()
        let identifier = ["acct", "account", "enr", "res", "install", "router", "user", "org", "sess", "tok"]
            .contains { lower.hasPrefix($0 + "_") || lower.hasPrefix($0 + "-") }
        let userName = NSUserName().lowercased()
        let personal = identifier || (userName.count >= 3 && lower.contains(userName))
        guard !personal, !value.isEmpty, value.count <= 48, !value.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return Self.withheld }
        if value.contains("/") {
            return TimeZone.knownTimeZoneIdentifiers.contains(value) ? value : Self.withheld
        }
        let shapes = [
            #"^[a-z][a-z0-9_]*$"#,  // reason, state and outcome codes
            #"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?Z?)?$"#,  // dates and slots
            #"^\d{2}:\d{2}$"#,  // admission times
            #"^v?\d+(\.\d+){0,3}([-+][a-z0-9.]{1,16})?$"#,  // versions
            #"^UTC$"#,
        ]
        let fits = shapes.contains { value.range(of: $0, options: .regularExpression) != nil }
        return fits ? value : Self.withheld
    }

    static let withheld = "(withheld)"

    static func local(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: zone) ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// The last seven local days of scheduled slots, for the "This week" strip.
public struct WeekDay: Sendable, Equatable, Identifiable {
    public enum Mark: String, Sendable, Equatable {
        case confirmed, uncertain, problem, missed, skipped

        public var symbolName: String {
            switch self {
            case .confirmed: "checkmark.circle.fill"
            case .uncertain: "questionmark.circle.fill"
            case .problem: "exclamationmark.triangle.fill"
            case .missed: "xmark.circle.fill"
            case .skipped: "minus.circle.fill"
            }
        }

        public var words: String {
            switch self {
            case .confirmed: "confirmed"
            case .uncertain: "uncertain"
            case .problem: "had problems"
            case .missed: "missed"
            case .skipped: "skipped"
            }
        }
    }

    public struct Slot: Sendable, Equatable, Identifiable {
        public let date: String
        public let time: String
        public let mark: Mark
        /// The full slot label: a time alone repeats across days and broke list identity (0.6.1).
        public var id: String { "\(self.date)T\(self.time)" }
    }

    public let date: String
    public let weekday: Int
    public let slots: [Slot]
    /// Account results from manual warm-ups that day (one per account, skipped ones included).
    public let manualRuns: Int
    public var id: String { self.date }

    /// "Monday 16 November: 08:00 confirmed, 13:00 missed."
    public var spoken: String {
        let date = FriendlyTime.parse(self.date).map { FriendlyTime.formatter("d MMMM").string(from: $0) } ?? self.date
        let day = "\(Wording.weekdayName(self.weekday)) \(date)"
        var parts = self.slots.map { "\($0.time) \($0.mark.words)" }
        if self.manualRuns > 0 {
            parts.append("\(self.manualRuns) manual account \(self.manualRuns == 1 ? "result" : "results")")
        }
        return parts.isEmpty ? "\(day): no scheduled warm-ups recorded." : "\(day): \(parts.joined(separator: ", "))."
    }
}

extension WeekDay.Slot {
    /// The minute shown in the week strip: the run or due minute (`RunTimes`, as on Today), else the
    /// keyed time. Clicks and VoiceOver actions still use `id`, the slot label.
    public func shown(runs: RunTimes) -> String { runs.time(of: self.id) ?? self.time }
}

extension WeekDay {
    static let legendOrder: [Mark] = [.confirmed, .uncertain, .problem, .missed, .skipped]

    /// "+2 manual results", "+1 manual result"; nil for none.
    public var manualText: String? {
        guard self.manualRuns > 0 else { return nil }
        return "+\(self.manualRuns) manual result\(self.manualRuns == 1 ? "" : "s")"
    }

    /// The legend line for the manual count, shown when any day has one.
    public static let manualLegend = "+N manual results: account results from manual warm-ups that day."

    /// The marks that appear in `days`, in legend order, so the legend lists only what is shown.
    public static func marksPresent(_ days: [WeekDay]) -> [Mark] {
        let present = Set(days.flatMap { $0.slots.map(\.mark) })
        return Self.legendOrder.filter { present.contains($0) }
    }
}

/// The line under Last 7 days when the latest history read failed and the strip was rebuilt from
/// fresh status plus the last history rows read successfully at `readAt` (epoch milliseconds).
/// With no earlier good read (`readAt` nil) the strip shows fresh status alone.
public enum WeekStaleText {
    public static let unreadText = "History could not be read."

    public static func line(readAt: Int?, now: Date = Date(), zone: String) -> String {
        guard let readAt else { return Self.unreadText }
        return "History could not be read; earlier days are from \(FriendlyTime.instant(readAt, now: now, zone: zone))."
    }
}

public enum WeekSummary {
    /// Seven days ending `today` (yyyy-MM-dd, the schedule's local date), oldest first. Slots come
    /// from history rows, not-admitted ledger rows and the latest batch outcome; only recorded
    /// evidence is shown, so a day can be empty. A batch still running, or the oldest batch in a
    /// truncated history (its other rows may be cut off), is never shown as confirmed.
    public static func make(today: String, status: EngineStatus, history: [HistoryEntry], truncated: Bool = false)
        -> [WeekDay]
    {
        let dates = self.lastSevenDates(endingOn: today)
        guard !dates.isEmpty else { return [] }
        var marks: [String: WeekDay.Mark] = [:]
        for row in status.slotLedger {
            marks[row.slot] = SlotProblem.operatorChosenCauses.contains(row.cause) ? .skipped : .missed
        }
        var bySlot: [String: [HistoryEntry]] = [:]
        var manual: [String: Int] = [:]
        for row in history {
            if row.mode == "scheduled", let slot = row.slot {
                bySlot[slot, default: []].append(row)
            } else if row.mode == "manual", let at = row.at {
                manual[
                    StatusDiagnostic.local(Date(timeIntervalSince1970: Double(at) / 1000), zone: status.schedule.zone)
                        .prefix(10).description, default: 0] += 1
            }
        }
        for (slot, rows) in bySlot { marks[slot] = self.mark(rows) }
        var partial: Set<String> = []
        if truncated,
            let oldest = history.filter({ $0.mode == "scheduled" }).min(by: { ($0.at ?? 0) < ($1.at ?? 0) })?.slot
        {
            partial.insert(oldest)
        }
        if let running = status.activeBatch?.slot { partial.insert(running) }
        // History is read after status: a batch that started in between is newer than the last
        // outcome status knows about, and may not have finished.
        if let last = status.lastSlotOutcome?.slot {
            partial.formUnion(bySlot.keys.filter { $0 > last })
        } else if let newest = bySlot.keys.max() {
            partial.insert(newest)  // no finished batch known yet: the newest may still be running
        }
        for slot in partial where marks[slot] == .confirmed { marks[slot] = .uncertain }
        // A batch the engine stopped is a problem even when none of its rows was saved.
        for blocked in status.blockedSlots ?? [] { marks[blocked.slot] = .problem }
        if let last = status.lastSlotOutcome {
            let results = last.results ?? []
            let fromOutcome = self.mark(outcome: last.outcome, results: results)
            // A finished batch that dispatched nothing keeps the mark its history rows give (all
            // skipped), so it reads the same while it is the latest batch and after it.
            let sentNothing = !results.isEmpty && results.allSatisfy { $0.dispatched != true }
            // Only when history holds a row for every result: a cut history must not decide it.
            if fromOutcome == .problem, last.outcome != "blocked", sentNothing, let rows = bySlot[last.slot],
                rows.count == results.count,
                self.mark(rows) == .skipped
            {
                marks[last.slot] = .skipped
            } else {
                marks[last.slot] = fromOutcome
            }
        }
        return dates.map { date in
            let slots = marks.filter { $0.key.hasPrefix(date + "T") && SlotProblem.isSlot($0.key) }
                .map { WeekDay.Slot(date: date, time: String($0.key.suffix(5)), mark: $0.value) }
                .sorted { $0.time < $1.time }
            return WeekDay(date: date, weekday: self.isoWeekday(date), slots: slots, manualRuns: manual[date] ?? 0)
        }
    }

    static func mark(_ all: [HistoryEntry]) -> WeekDay.Mark {
        if all.contains(where: { $0.batchOutcome == "blocked" }) { return .problem }
        // Accounts held back by the operator's own daily cap neither confirm nor fail a slot.
        let rows = all.filter { !SlotProblem.chosenSkipReasons.contains($0.reason ?? "") }
        if rows.isEmpty { return .skipped }
        if rows.allSatisfy({ $0.status == "success" }) { return .confirmed }
        if rows.allSatisfy({ $0.status == "success" || $0.status == "uncertain" }) { return .uncertain }
        if rows.allSatisfy({ $0.status == "skipped" }) { return .skipped }
        return .problem
    }

    static func mark(outcome: String?, results all: [AccountResult]) -> WeekDay.Mark {
        // The engine stopped or could not finish the batch: a problem whatever its rows say.
        if outcome == "blocked" { return .problem }
        let results = all.filter { !SlotProblem.chosenSkipReasons.contains($0.reason) }
        if !all.isEmpty, results.isEmpty { return .skipped }
        if !results.isEmpty, results.allSatisfy({ $0.outcome == "success" }) { return .confirmed }
        switch outcome {
        case "success": return .confirmed
        case "idle": return .skipped
        default:
            // Engine 1.1 flags skipped accounts in the batch itself, so no history read is needed.
            if !results.isEmpty, results.allSatisfy({ $0.skipped == true }) { return .skipped }
            let settled = results.allSatisfy { $0.outcome == "success" || $0.outcome == "uncertain" }
            return !results.isEmpty && settled ? .uncertain : .problem
        }
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func parse(_ date: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: date)
    }

    static func lastSevenDates(endingOn today: String) -> [String] {
        guard let end = self.parse(today) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<7).reversed().compactMap { offset in
            self.calendar.date(byAdding: .day, value: -offset, to: end).map { formatter.string(from: $0) }
        }
    }

    static func dayBefore(_ date: String) -> String? {
        guard let day = self.parse(date), let previous = self.calendar.date(byAdding: .day, value: -1, to: day) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: previous)
    }

    static func isoWeekday(_ date: String) -> Int {
        guard let day = self.parse(date) else { return 0 }
        let sundayFirst = self.calendar.component(.weekday, from: day)  // 1 = Sunday
        return sundayFirst == 1 ? 7 : sundayFirst - 1
    }
}

/// Whether the Mac has a wake scheduled before the next slot. A sleeping Mac cannot run the job,
/// so without a wake (or an awake, plugged-in Mac) the slot is missed. Wakes the operator set with
/// `pmset` count, whatever owner name they carry; the system's own short maintenance wakes
/// (owners starting `com.apple.`) do not.
public enum WakeReadiness: Sendable, Equatable {
    case ready(wakeAt: String)
    case notScheduled
    case unknown

    /// How long before the admission minute a wake still helps.
    public static let leadMinutes = 30
    /// A repeating wake the operator can add; it needs an administrator password. `pmset repeat`
    /// replaces any repeating events already set, so the UI warns when `hasRepeating` is true.
    public static func suggestedCommand(admission: String) -> String {
        "sudo pmset repeat wakeorpoweron MTWRFSU \(self.minus(admission, minutes: 5)):00"
    }

    /// True when `pmset -g sched` lists any repeating power event.
    public static func hasRepeating(pmset output: String) -> Bool {
        var repeating = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Repeating power events") { repeating = true; continue }
            if line.hasPrefix("Scheduled power events") { repeating = false; continue }
            if repeating, line.contains(" at ") { return true }
        }
        return false
    }

    /// Reads `pmset -g sched` output against the next slot (`date` yyyy-MM-dd, `admission` HH:mm,
    /// both in the Mac's local time). A wake on the previous evening counts for a slot just after
    /// midnight: times are compared as minutes from the slot date's midnight, so the day before is
    /// negative.
    public static func assess(pmset output: String, date: String, admission: String) -> WakeReadiness {
        let weekday = WeekSummary.isoWeekday(date)
        guard let slot = self.minuteOfDay(admission), weekday > 0, let previous = WeekSummary.dayBefore(date) else {
            return .unknown
        }
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        var repeating = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Repeating power events") { repeating = true; continue }
            if line.hasPrefix("Scheduled power events") { repeating = false; continue }
            guard Self.isWake(line) else { continue }
            if repeating {
                if let hit = self.repeatingWake(line, weekday: weekday, previousWeekday: previousWeekday, slot: slot) {
                    return .ready(wakeAt: hit)
                }
            } else if !line.contains("'com.apple.") {
                if let hit = self.oneTimeWake(line, date: date, previous: previous, slot: slot) {
                    return .ready(wakeAt: hit)
                }
            }
        }
        return .notScheduled
    }

    static func isWake(_ line: String) -> Bool {
        ["wake", "wakepoweron", "wakeorpoweron", "poweron"].contains { line.contains("\($0) at ") }
    }

    /// `[0]  wake at 11/21/2026 07:55:00 by 'pmset'`
    static func oneTimeWake(_ line: String, date: String, previous: String, slot: Int) -> String? {
        guard let range = line.range(of: #"\d{2}/\d{2}/\d{4} \d{2}:\d{2}"#, options: .regularExpression) else {
            return nil
        }
        let stamp = String(line[range])
        let parts = stamp.split(separator: " ")
        let day = parts[0].split(separator: "/")
        guard day.count == 3, let minute = self.minuteOfDay(String(parts[1])) else { return nil }
        let wakeDate = "\(day[2])-\(day[0])-\(day[1])"
        let offset: Int
        if wakeDate == date {
            offset = minute
        } else if wakeDate == previous {
            offset = minute - 1440
        } else {
            return nil
        }
        return self.inWindow(offset, slot: slot) ? String(parts[1]) : nil
    }

    /// `wakepoweron at 7:55AM weekdays only` / `every day` / `weekends only` / named days.
    static func repeatingWake(_ line: String, weekday: Int, previousWeekday: Int, slot: Int) -> String? {
        guard let range = line.range(of: #"\d{1,2}:\d{2}(AM|PM)"#, options: .regularExpression) else { return nil }
        let text = String(line[range])
        let pm = text.hasSuffix("PM")
        let clock = text.dropLast(2).split(separator: ":")
        guard clock.count == 2, var hour = Int(clock[0]), let minute = Int(clock[1]) else { return nil }
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        let days = self.days(String(line[range.upperBound...]).lowercased())
        let value = hour * 60 + minute
        let sameDay = days.contains(weekday) && self.inWindow(value, slot: slot)
        let dayBefore = days.contains(previousWeekday) && self.inWindow(value - 1440, slot: slot)
        guard sameDay || dayBefore else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// The days a repeating event names: "weekdays", "weekends", "every day", full or short day
    /// names, or pmset's letters (M T W R F S U). Unknown forms match nothing.
    static func days(_ text: String) -> Set<Int> {
        if text.contains("weekdays") { return Set(1...5) }
        if text.contains("weekends") { return [6, 7] }
        if text.contains("every day") { return Set(1...7) }
        let names = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        let words = text.split { !$0.isLetter }.map(String.init)
        let named = Set(words.compactMap { word in names.firstIndex { word.hasPrefix($0) }.map { $0 + 1 } })
        if !named.isEmpty { return named }
        let map: [Character: Int] = ["m": 1, "t": 2, "w": 3, "r": 4, "f": 5, "s": 6, "u": 7]
        guard let letters = words.first(where: { $0.count <= 7 && $0.allSatisfy { map[$0] != nil } }) else {
            return []
        }
        return Set(letters.compactMap { map[$0] })
    }

    static func inWindow(_ minute: Int, slot: Int) -> Bool {
        minute <= slot && slot - minute <= self.leadMinutes
    }

    static func minuteOfDay(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour),
            (0..<60).contains(minute)
        else {
            return nil
        }
        return hour * 60 + minute
    }

    static func minus(_ admission: String, minutes: Int) -> String {
        guard let value = self.minuteOfDay(admission) else { return admission }
        let shifted = (value - minutes + 1440) % 1440
        return String(format: "%02d:%02d", shifted / 60, shifted % 60)
    }

    // MARK: Many times (work order 132)

    /// One time to assess: `date` yyyy-MM-dd and `admission` HH:mm, both in the Mac's local time.
    public typealias Slot = (id: String, date: String, admission: String)

    /// The plan key of the status's next time; Schedule rows use `ProjectedAdmission.id`.
    public static let nextKey = "next"

    /// Every time one `pmset -g sched` read can speak for: the status's next time (`nextKey`) and each
    /// upcoming projected time with a known instant (keyed by its row id), converted to `local`.
    public static func slots(
        next: NextSlot?, scheduleZone: String, projection: ScheduleProjection?, local: TimeZone = .current
    ) -> [Slot] {
        var slots: [Slot] = []
        if let next, let due = Countdown.date(of: next, zone: scheduleZone) {
            slots.append(Self.slot(id: self.nextKey, at: due, local: local))
        }
        for admission in projection?.days.flatMap(\.admissions) ?? [] {
            guard admission.state == "upcoming" || admission.state == "next" || admission.next == true,
                let at = admission.at
            else { continue }
            slots.append(Self.slot(id: admission.id, at: Date(timeIntervalSince1970: Double(at) / 1000), local: local))
        }
        return slots
    }

    private static func slot(id: String, at date: Date, local: TimeZone) -> Slot {
        (id: id, date: ClockTime.day(from: date, zone: local), admission: ClockTime.string(from: date, zone: local))
    }

    /// Each slot assessed against one read, the latest day with a one-time wake not owned by the
    /// system, and whether any repeating event is listed.
    public static func plan(pmset output: String, slots: [Slot]) -> WakePlan {
        var bySlot: [String: WakeReadiness] = [:]
        for slot in slots {
            bySlot[slot.id] = self.assess(pmset: output, date: slot.date, admission: slot.admission)
        }
        return WakePlan(
            bySlot: bySlot, lastBookedDay: self.lastBookedDay(pmset: output),
            hasRepeating: self.hasRepeating(pmset: output))
    }

    /// The latest `yyyy-MM-dd` among one-time wakes whose owner does not start with `com.apple.`.
    static func lastBookedDay(pmset output: String) -> String? {
        var repeating = false
        var latest: String?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Repeating power events") { repeating = true; continue }
            if line.hasPrefix("Scheduled power events") { repeating = false; continue }
            guard !repeating, Self.isWake(line), !line.contains("'com.apple."),
                let range = line.range(of: #"\d{2}/\d{2}/\d{4}"#, options: .regularExpression)
            else { continue }
            let day = line[range].split(separator: "/")
            let date = "\(day[2])-\(day[0])-\(day[1])"
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }
}

/// What one wake read says about every coming time (work order 132).
public struct WakePlan: Sendable, Equatable {
    /// Each assessed time by key (`WakeReadiness.nextKey` or a Schedule row id).
    public let bySlot: [String: WakeReadiness]
    /// The latest day (yyyy-MM-dd, Mac local) with a one-time wake not owned by the system.
    public let lastBookedDay: String?
    /// `pmset` lists a repeating power event of any kind.
    public let hasRepeating: Bool
    /// False only for `unknown`: the read failed, so nothing is known.
    public let isKnown: Bool

    public init(bySlot: [String: WakeReadiness], lastBookedDay: String?, hasRepeating: Bool, isKnown: Bool = true) {
        self.bySlot = bySlot
        self.lastBookedDay = lastBookedDay
        self.hasRepeating = hasRepeating
        self.isKnown = isKnown
    }

    public static let unknown = WakePlan(bySlot: [:], lastBookedDay: nil, hasRepeating: false, isKnown: false)

    /// The readiness for a key; unknown when the plan is unknown or the time was not assessed.
    public func readiness(_ key: String) -> WakeReadiness {
        guard self.isKnown else { return .unknown }
        return self.bySlot[key] ?? .unknown
    }
}
