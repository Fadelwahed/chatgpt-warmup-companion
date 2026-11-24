import Foundation

// App 0.6 read-only CLI (F10): `WarmupMenu --status` prints the verdict, today's times, health and
// accounts; `--json` the same facts for agents. It reads only `status` and `schedule inspect` through
// the stored binding. Output numbers accounts "Account N" and carries no IDs, paths, nicknames or
// emails, like Copy Status Summary.

public enum StatusCLI {
    public enum Mode: Sendable, Equatable {
        case status, json, app
        case provision([String])
        case usage(String)
    }

    public static let usageText =
        "usage: WarmupMenu --status | --json | --provision-binding --node PATH --script PATH --expect-build sha256:HEX"
    public static let unreadableMessage = "Warm-up: no engine connection. Open the app's Settings to reconnect."
    public static let scheduleUnreadableMessage = "Warm-up: the schedule could not be read."
    /// The reply names a time zone the CLI cannot check, so nothing is printed from it.
    public static let uncheckedMessage = "Warm-up: the engine reply could not be checked."
    /// Shown in place of a time or date the engine sent in an unexpected shape.
    public static let unknownText = "unknown"
    /// Shown in place of a block reason that is not a plain code.
    public static let blockedText = "Blocked"
    public static let exitGood: Int32 = 0
    public static let exitAttention: Int32 = 1
    public static let exitUnreadable: Int32 = 2
    public static let exitUsage: Int32 = 64

    /// Only an exact first argument selects a CLI mode; anything else (including the `-psn_…` and
    /// `-NS…` arguments macOS may pass) starts the app.
    public static func parse(_ arguments: [String]) -> Mode {
        guard let first = arguments.first else { return .app }
        switch first {
        case "--status": return arguments.count == 1 ? .status : .usage(Self.usageText)
        case "--json": return arguments.count == 1 ? .json : .usage(Self.usageText)
        case "--provision-binding": return .provision(Array(arguments.dropFirst()))
        default: return .app
        }
    }

    /// One validated read: status and, when it could be read, the projection.
    public struct Snapshot: Sendable, Equatable {
        public let status: EngineStatus
        public let observedAt: Int?
        public let projection: ScheduleProjection?

        public init(status: EngineStatus, observedAt: Int?, projection: ScheduleProjection?) {
            self.status = status
            self.observedAt = observedAt
            self.projection = projection
        }
    }

    /// The facts both outputs carry. Encoded as the `--json` reply.
    public struct Report: Codable, Sendable, Equatable {
        public struct Time: Codable, Sendable, Equatable {
            public let time: String
            public let mark: String
        }

        public struct Check: Codable, Sendable, Equatable {
            public let name: String
            public let ok: Bool
            public let text: String
        }

        public struct Account: Codable, Sendable, Equatable {
            public let label: String
            public let state: String
            public let usage: String
        }

        public let verdict: String
        public let state: String
        public let next: String
        public let today: [Time]
        public let health: [Check]
        public let accounts: [Account]
        public let checkedAt: String
        /// Possible sends with no recorded result (count only); absent when there are none.
        public let unresolvedSends: Int?
        /// True when the engine cut the unresolved list, so `unresolvedSends` is a lower bound; absent
        /// otherwise (060-FIX7 item 5).
        public let unresolvedTruncated: Bool?
    }

    /// How many status + inspect pairs `read` tries before giving up on a matching schedule.
    static let pairAttempts = 2

    /// Reads `status`, checks it against the binding, then `schedule inspect`. Nil when status cannot be
    /// read or the engine no longer matches its binding. The projection must be of the same schedule
    /// (revision and zone) and its own `localDate` must be the status observation's local date
    /// (`paired`); an edit or midnight between the two reads is retried once, and a second mismatch
    /// returns no projection, so nothing is printed (060-FIX4 item 2, 060-FIX5 item 3, 060-FIX6 item 4).
    /// A reply without a valid `observedAt` is a mismatch too: the date is never taken from the wall
    /// clock (060-FIX7 item 3). A failed or not-ready inspect is retried the same way (060-FIX8 item 4).
    public static func read(client: EngineClient) async -> Snapshot? {
        var unpaired: Snapshot?
        for _ in 0..<Self.pairAttempts {
            guard case let .success(reply) = await client.read(.status, as: EngineStatus.self),
                reply.envelope.outcome == "ready", let status = reply.payload,
                BindingVerifier.compare(client.binding, envelope: reply.envelope, status: status) == nil
            else { return nil }
            await client.setCapability(status.capability)
            let observedAt = HeartbeatCheck.milliseconds(iso8601: reply.envelope.observedAt)
            unpaired = Snapshot(status: status, observedAt: observedAt, projection: nil)
            guard case let .success(inspect) = await client.read(.scheduleInspect, as: ScheduleProjection.self),
                inspect.envelope.outcome == "ready", let projection = inspect.payload
            else { continue }
            guard let observedAt, Self.paired(projection: projection, status: status, observedAt: observedAt) else {
                continue
            }
            return Snapshot(status: status, observedAt: observedAt, projection: projection)
        }
        return unpaired
    }

    /// The projection is of the status's schedule, was read on `today` (its own `localDate`) and lists
    /// that date. With a zone that has no date, only the schedule must match (render rejects the zone).
    static func paired(projection: ScheduleProjection, status: EngineStatus, today: String?) -> Bool {
        guard let today else { return ProjectionCheck.sameSchedule(projection: projection, status: status) }
        return projection.localDate == today
            && ProjectionCheck.current(projection: projection, status: status, today: today)
    }

    /// `paired` on the observation's own local date.
    static func paired(projection: ScheduleProjection, status: EngineStatus, observedAt: Int) -> Bool {
        let today = Self.observedDay(status: status, observedAt: observedAt)
        return Self.paired(projection: projection, status: status, today: today)
    }

    /// The status observation's local date in the schedule zone. Output treats this date as "today",
    /// not the wall clock at render time.
    static func observedDay(status: EngineStatus, observedAt: Int) -> String? {
        FriendlyTime.today(zone: status.schedule.zone, now: Date(timeIntervalSince1970: Double(observedAt) / 1000))
    }

    /// `observedDay`, or the date at `now` for the output builders called without an observation time.
    /// The CLI itself never renders without one (`read`, `render`).
    static func observedDay(status: EngineStatus, observedAt: Int?, now: Date) -> String? {
        guard let observedAt else { return FriendlyTime.today(zone: status.schedule.zone, now: now) }
        return Self.observedDay(status: status, observedAt: observedAt)
    }

    /// What to print and the exit code: stdout text (or JSON), or one stderr line when unreadable.
    /// `acknowledgedSlot` is the app's stored problem slot already opened (`GlanceBuilder.acknowledgedSlotKey`),
    /// so the CLI and the app agree on "Needs a look" (0.6.3).
    public static func render(_ snapshot: Snapshot?, json: Bool, now: Date, acknowledgedSlot: String? = nil) -> (
        stdout: Data, stderr: String?, code: Int32
    ) {
        guard let snapshot else { return (Data(), Self.unreadableMessage, Self.exitUnreadable) }
        guard let projection = snapshot.projection else {
            return (Data(), Self.scheduleUnreadableMessage, Self.exitUnreadable)
        }
        let status = snapshot.status
        guard Self.isZone(status.schedule.zone) else { return (Data(), Self.uncheckedMessage, Self.exitUnreadable) }
        // A projection read on another day cannot speak for Today (060-FIX5 item 3, 060-FIX6 item 4), and
        // without a valid observation time the day is unknown: never the wall clock (060-FIX7 item 3).
        guard let observedAt = snapshot.observedAt,
            Self.paired(projection: projection, status: status, observedAt: observedAt)
        else { return (Data(), Self.scheduleUnreadableMessage, Self.exitUnreadable) }
        let today = Self.observedDay(status: status, observedAt: observedAt)
        let glance = GlanceBuilder.make(
            status: status, today: today, observedAt: snapshot.observedAt,
            // A malformed stored value never hides a problem.
            acknowledgedSlot: acknowledgedSlot.flatMap { Self.isSlot($0) ? $0 : nil })
        let code = Self.exitCode(
            glance: glance, health: Self.health(status, observedAt: snapshot.observedAt, now: now),
            unresolved: status.unresolved.count)
        let output =
            json
            ? Self.json(
                status: status, glance: glance, projection: projection, now: now,
                observedAt: snapshot.observedAt)
            : Data(
                Self.text(
                    status: status, glance: glance, projection: projection, now: now,
                    observedAt: snapshot.observedAt
                )
                .utf8)
        return (output + Data("\n".utf8), nil, code)
    }

    /// 0 all good; 1 something needs attention (including unresolved sends); 2 nothing could be read
    /// (no glance).
    public static func exitCode(glance: Glance?, health: [HealthRow], unresolved: Int = 0) -> Int32 {
        guard let glance else { return Self.exitUnreadable }
        let good: Set<GlanceState> = [.scheduled, .running]
        let fine = good.contains(glance.state) && HealthCheck.allFine(health) && unresolved == 0
        return fine ? Self.exitGood : Self.exitAttention
    }

    public static func report(
        status: EngineStatus, glance: Glance, projection: ScheduleProjection?, now: Date, observedAt: Int? = nil
    ) -> Report {
        let zone = status.schedule.zone
        let nowMs = Int((now.timeIntervalSince1970 * 1000).rounded())
        let fields = Fields.make(
            status: status, glance: glance, projection: projection, now: now, observedAt: observedAt)
        let accounts = status.accounts.enumerated().map { index, account in
            Report.Account(
                label: "Account \(index + 1)", state: Self.accountState(account, now: nowMs),
                usage: UsageText.cell(usage: account.usage, now: nowMs, zone: zone).main)
        }
        let checks = Self.health(status, observedAt: observedAt, now: now).map {
            Report.Check(name: $0.title, ok: $0.level != .warning, text: $0.value)
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        return Report(
            verdict: Self.verdict(glance, fields: fields, status: status, observedAt: observedAt),
            state: glance.state.rawValue, next: Self.next(status, fields: fields, now: now),
            today: fields.today.map { Report.Time(time: $0.shown, mark: $0.kind.rawValue) }, health: checks,
            accounts: accounts,
            checkedAt: stamp.string(from: now),
            unresolvedSends: status.unresolved.isEmpty ? nil : status.unresolved.count,
            unresolvedTruncated: status.unresolvedTruncated == true ? true : nil)
    }

    public static func text(
        status: EngineStatus, glance: Glance, projection: ScheduleProjection?, now: Date, observedAt: Int? = nil
    ) -> String {
        let report = Self.report(
            status: status, glance: glance, projection: projection, now: now, observedAt: observedAt)
        let marks = report.today.map { TodayMark(time: $0.time, kind: TodayMark.Kind(rawValue: $0.mark) ?? .upcoming) }
        let day = Self.observedDay(status: status, observedAt: observedAt, now: now)
        let available = projection.map { Self.paired(projection: $0, status: status, today: day) } ?? false
        let empty = available ? "Today: no warm-ups" : "Today: \(TodayMark.unavailableText)"
        let today =
            marks.isEmpty ? empty : "Today: " + marks.map { "\($0.kind.glyph) \($0.time)" }.joined(separator: " ")
        var lines = [report.verdict, "Next: \(report.next)", today]
        // Printed whatever the verdict (paused, running, …): count only, no IDs (060-FIX6 item 6).
        if let unresolved = report.unresolvedSends {
            lines.append(Self.unresolvedLine(unresolved, truncated: report.unresolvedTruncated == true))
        }
        lines.append("Health:")
        lines += report.health.map { "  \($0.ok ? "✓" : "!") \($0.name): \($0.text)" }
        lines += report.accounts.map { "\($0.label): \($0.state) · \($0.usage)" }
        return lines.joined(separator: "\n")
    }

    public static func json(
        status: EngineStatus, glance: Glance, projection: ScheduleProjection?, now: Date, observedAt: Int? = nil
    ) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = Self.report(
            status: status, glance: glance, projection: projection, now: now, observedAt: observedAt)
        return (try? encoder.encode(report)) ?? Data("{}".utf8)
    }

    static func health(_ status: EngineStatus, observedAt: Int?, now: Date) -> [HealthRow] {
        HealthCheck.rows(status: status, observedAt: observedAt, wake: .unknown, nextLocalAdmission: nil, now: now)
    }

    /// "13:00, in 2 h 15 min", "none, scheduling is paused", "none in the next 7 days".
    static func next(_ status: EngineStatus, fields: Fields, now: Date) -> String {
        guard status.scheduleEnabled else { return "none, scheduling is paused" }
        guard status.next != nil else { return "none in the next 7 days" }
        guard let when = fields.nextWhen else { return Self.unknownText }
        guard let due = fields.nextDue else { return when }
        return "\(when), \(Countdown.phrase(from: now, to: due))"
    }

    /// "Ready", "Cooling down", or the engine's block reason in plain words ("Blocked" when the reason
    /// is not a known code, so no engine text, email, path or ID reaches the output).
    static func accountState(_ account: AccountState, now: Int) -> String {
        if let block = account.block {
            let words = Wording.reason(block)
            guard words != Wording.code(block) else { return Self.blockedText }
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        if let until = account.cooldownUntil, until > now { return "Cooling down" }
        return "Ready"
    }

    // MARK: - Engine strings (060-FIX1 item 2)

    /// An IANA-shaped identifier ("Asia/Gaza", "America/Argentina/Buenos_Aires", "UTC") that
    /// Foundation also accepts.
    static func isZone(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+){0,2}/) != nil && TimeZone(identifier: value) != nil
    }

    /// A slot label: "2026-11-12T08:00".
    static func isSlot(_ value: String) -> Bool {
        value.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}/) != nil
    }

    static func isTime(_ value: String) -> Bool {
        value.wholeMatch(of: /[0-9]{2}:[0-9]{2}/) != nil
    }

    static func isDate(_ value: String) -> Bool {
        value.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil
    }

    static func safeTime(_ value: String) -> String {
        Self.isTime(value) ? value : Self.unknownText
    }

    /// Every engine string the output quotes, each checked on its own before any line is composed
    /// (060-FIX3 item 2). A malformed value is nil (or "unknown" for a today time), never patched
    /// out of composed text.
    struct Fields: Sendable, Equatable {
        /// The schedule zone, nil when it is not an IANA-shaped identifier.
        let zone: String?
        /// The status observation's local date in that zone (`observedDay`).
        let date: String?
        /// "08:00" or "08:00 tomorrow"; nil when the next time or date is malformed or missing.
        let nextWhen: String?
        /// When the next time is due; nil with `nextWhen`.
        let nextDue: Date?
        /// The running batch's slot label, nil when malformed.
        let batchSlot: String?
        /// The latest unopened problem slot, nil when malformed.
        let problemSlot: String?
        /// Today's marks, each time either "HH:mm" or "unknown".
        let today: [TodayMark]

        static func make(
            status: EngineStatus, glance: Glance, projection: ScheduleProjection?, now: Date, observedAt: Int? = nil
        ) -> Fields {
            let zone = status.schedule.zone
            let date = StatusCLI.observedDay(status: status, observedAt: observedAt, now: now)
            var when: String?
            var due: Date?
            if let next = status.next, StatusCLI.isTime(next.admission), StatusCLI.isDate(next.date) {
                when =
                    next.date == date
                    ? next.admission : FriendlyTime.time(next.admission, on: next.date, today: date)
                due = Countdown.date(of: next, zone: zone)
            }
            let nowMs = Int((now.timeIntervalSince1970 * 1000).rounded())
            let week = date.flatMap { WeekSummary.make(today: $0, status: status, history: []).last }
            let available = projection.map { StatusCLI.paired(projection: $0, status: status, today: date) } ?? false
            let admissions = projection?.days.first { $0.date == date }?.admissions ?? []
            let marks = TodayMark.make(
                week: week, admissions: admissions, now: nowMs, available: available,
                ledger: week == nil ? [] : status.slotLedger)
            return Fields(
                zone: StatusCLI.isZone(zone) ? zone : nil, date: date, nextWhen: when, nextDue: due,
                batchSlot: status.activeBatch.map(\.slot).flatMap { StatusCLI.isSlot($0) ? $0 : nil },
                problemSlot: glance.unseenProblemSlot.flatMap { StatusCLI.isSlot($0) ? $0 : nil },
                today: marks.map {
                    TodayMark(time: StatusCLI.safeTime($0.time), kind: $0.kind, shown: StatusCLI.safeTime($0.shown))
                })
        }
    }

    /// The verdict, rebuilt from the checked fields: the glance supplies only which kind of headline
    /// it is; a fixed headline is kept, and anything else prints "unknown".
    static func verdict(_ glance: Glance, fields: Fields, status: EngineStatus, observedAt: Int?) -> String {
        let headline = glance.headline
        // Unresolved sends are never "All good" (060-FIX5 item 5): count only, no IDs.
        if headline.hasPrefix(Self.scheduledPrefix),
            let attention = Self.unresolvedVerdict(
                status.unresolved.count, truncated: status.unresolvedTruncated == true)
        {
            return attention
        }
        if Self.fixedVerdicts.contains(headline) { return headline }
        if headline.hasPrefix(Self.runningPrefix) {
            return Self.runningPrefix + (fields.batchSlot.map { String($0.suffix(5)) } ?? Self.unknownText)
        }
        if headline.hasPrefix(Self.problemPrefix) {
            let slot = fields.problemSlot.map { FriendlyTime.slotShort($0, today: fields.date) }
            return Self.problemPrefix + (slot ?? Self.unknownText)
        }
        if headline.hasPrefix(Self.scheduledPrefix) {
            // The glance names the zone only when it is not the Mac's own.
            let suffix = fields.zone.map { " (\($0))" }.flatMap { headline.hasSuffix($0) ? $0 : nil } ?? ""
            return Self.scheduledPrefix + (fields.nextWhen ?? Self.unknownText) + suffix
        }
        if headline.hasPrefix(Self.checkInPrefix), let tick = status.lastTick, let observedAt, let zone = fields.zone {
            return HeartbeatCheck.headline(tick: tick, observedAt: observedAt, zone: zone)
        }
        return Self.unknownText
    }

    /// "Needs attention: 2 unresolved sends"; "2 or more" when the engine cut the list (060-FIX8 item
    /// 5); nil for none.
    static func unresolvedVerdict(_ count: Int, truncated: Bool = false) -> String? {
        guard count > 0 else { return nil }
        if truncated { return "Needs attention: \(count) or more unresolved sends" }
        return "Needs attention: \(count) unresolved send\(count == 1 ? "" : "s")"
    }

    /// "Unresolved sends: 2", the text line printed whenever there are any; "2 or more" when the engine
    /// cut the list (060-FIX7 item 5).
    static func unresolvedLine(_ count: Int, truncated: Bool = false) -> String {
        "Unresolved sends: \(count)\(truncated ? " or more" : "")"
    }

    /// GlanceBuilder headlines that quote no engine value.
    static let fixedVerdicts: Set<String> = [
        "Blocked: Router needs a review", "Held: the clock moved backward", "Paused", "Background job not running",
        "No warm-up in the next 7 days",
    ]
    static let runningPrefix = "Warming up: "
    static let problemPrefix = "Needs a look: "
    static let scheduledPrefix = "All good · next "
    static let checkInPrefix = "No check-in since "
}
