import Foundation

public enum CommandError: Error, Equatable, Sendable {
    case invalidArgument(String)
}

enum Selector {
    static func check(_ value: String, _ pattern: String, _ name: String) throws {
        guard value.range(of: pattern, options: .regularExpression) != nil else { throw CommandError.invalidArgument(name) }
    }

    // Stricter than the engine: a leading "-" could read as a flag, so selectors start alphanumeric.
    static let identifier = "^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$"
    static let time = "^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"
    static let date = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    static let slot = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]$"
    static let since = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{3})?Z$"
    static let installation = "^[a-zA-Z0-9_-]{12,100}$"
}

/// One schedule edit in the engine's argument shape. The same value previews through
/// `schedule inspect` and saves through the guarded mutation.
public enum ScheduleEdit: Sendable, Equatable {
    case add(time: String, today: Bool)
    case remove(time: String, today: Bool)
    case move(from: String, to: String, today: Bool)
    case weekdays([Int])

    /// True for an edit that changes today only.
    public var isToday: Bool {
        switch self {
        case let .add(_, today), let .remove(_, today), let .move(_, _, today): today
        case .weekdays: false
        }
    }

    /// One sentence for the confirmation: "Adds 21:05 every day, from tomorrow."
    public var summary: String {
        let when = self.isToday ? "today only" : "every day, from tomorrow"
        switch self {
        case let .add(time, _): return "Adds \(time) \(when)."
        case let .remove(time, _): return "Removes \(time) \(when)."
        case let .move(from, to, _): return "Moves \(from) to \(to) \(when)."
        case let .weekdays(days):
            let names = days.sorted().map { Wording.weekday($0) }.joined(separator: ", ")
            return "Runs on \(names.isEmpty ? "no days" : names), from tomorrow."
        }
    }

    func arguments() throws -> [String] {
        switch self {
        case let .add(time, today):
            try Selector.check(time, Selector.time, "time")
            return ["add", time] + (today ? ["--today"] : [])
        case let .remove(time, today):
            try Selector.check(time, Selector.time, "time")
            return ["remove", time] + (today ? ["--today"] : [])
        case let .move(from, to, today):
            try Selector.check(from, Selector.time, "time")
            try Selector.check(to, Selector.time, "time")
            return ["move", from, to] + (today ? ["--today"] : [])
        case let .weekdays(days):
            let sorted = days.sorted()
            guard !sorted.isEmpty, sorted.count <= 7, Set(sorted).count == sorted.count, sorted.allSatisfy({ (1...7).contains($0) }) else {
                throw CommandError.invalidArgument("weekdays")
            }
            return ["weekdays", sorted.map(String.init).joined(separator: ",")]
        }
    }
}

/// Increment B schedule settings (engine 1.2): vacations, scheduled accounts, one undo, daily caps.
public enum ScheduleSetting: Sendable, Equatable {
    case exclude(start: String, end: String)
    case include(start: String, end: String)
    /// nil schedules every enabled account; a list (possibly empty) schedules only those.
    case accounts([String]?)
    /// Added or removed by the engine under its lock, against the enrollments it holds then.
    case addAccount(String)
    case removeAccount(String)
    case undo
    /// nil turns the cap off.
    case cap(enrollmentId: String, count: Int?)

    func arguments() throws -> [String] {
        switch self {
        case let .exclude(start, end), let .include(start, end):
            try Selector.check(start, Selector.date, "start")
            try Selector.check(end, Selector.date, "end")
            guard start <= end else { throw CommandError.invalidArgument("range") }
            return [self.isExclude ? "exclude" : "include", start, end]
        case let .accounts(ids):
            guard let ids else { return ["accounts", "all"] }
            guard ids.count <= 1000, Set(ids).count == ids.count else { throw CommandError.invalidArgument("accounts") }
            for id in ids { try Selector.check(id, Selector.identifier, "enrollment") }
            return ["accounts", "--only"] + ids.sorted()
        case let .addAccount(id), let .removeAccount(id):
            try Selector.check(id, Selector.identifier, "enrollment")
            return ["accounts", self.isAdd ? "--add" : "--remove", id]
        case .undo:
            return ["undo"]
        case let .cap(id, count):
            try Selector.check(id, Selector.identifier, "enrollment")
            guard let count else { return ["cap", id, "off"] }
            guard (1...48).contains(count) else { throw CommandError.invalidArgument("cap") }
            return ["cap", id, String(count)]
        }
    }

    var isExclude: Bool { if case .exclude = self { true } else { false } }
    var isAdd: Bool { if case .addAccount = self { true } else { false } }

    /// Only date-sensitive settings carry the local-date guard.
    public var usesLocalDate: Bool {
        switch self {
        case .exclude, .include, .undo: true
        case .accounts, .addAccount, .removeAccount, .cap: false
        }
    }

    var feature: String {
        switch self {
        case .exclude, .include: "schedule_vacations"
        case .accounts, .addAccount, .removeAccount: "scheduled_accounts"
        case .undo: "schedule_undo"
        case .cap: "daily_caps"
        }
    }
}

/// The complete allowlist of engine invocations the app may make. Anything else cannot be
/// expressed, so unknown commands fail locally without spawning a process.
public enum EngineCommand: Sendable, Equatable {
    // Read-only
    case status
    case list
    case history(account: String?, since: String?)
    case timing(account: String?)
    case scheduleInspect
    case scheduleInspectSlot(String)
    case scheduleInspectProposal(ScheduleEdit)
    // Guarded mutations (every one carries --expected-installation-id)
    /// `overlapAt` scopes the override to one admission instant (engine feature `scoped_slot_overlap`).
    case runAll(allowSlotOverlap: Bool, overlapAt: Int? = nil)
    case runAccount(enrollmentId: String, allowSlotOverlap: Bool, overlapAt: Int? = nil)
    case enroll(routerAccountId: String)
    case scheduleEnable(expectedRevision: Int)
    case scheduleDisable(expectedRevision: Int)
    case scheduleEdit(ScheduleEdit, expectedRevision: Int, expectedLocalDate: String)
    case scheduleSetting(ScheduleSetting, expectedRevision: Int, expectedLocalDate: String?)

    public var isMutation: Bool {
        switch self {
        case .status, .list, .history, .timing, .scheduleInspect, .scheduleInspectSlot, .scheduleInspectProposal: false
        default: true
        }
    }

    /// The `command` field the engine must echo in its envelope.
    public var engineName: String {
        switch self {
        case .status: "status"
        case .list: "list"
        case .history: "history"
        case .timing: "timing"
        case .runAll, .runAccount: "run"
        case .enroll: "enroll"
        case .scheduleInspect, .scheduleInspectSlot, .scheduleInspectProposal, .scheduleEnable, .scheduleDisable, .scheduleEdit,
            .scheduleSetting:
            "schedule"
        }
    }

    /// Engine capability features this command needs before the app may offer it.
    public var requiredFeatures: [String] {
        switch self {
        case .status, .list, .history, .timing: []
        case .scheduleInspect: ["schedule_inspect"]
        case .scheduleInspectSlot: ["slot_explanation"]
        case let .scheduleInspectProposal(edit):
            ["schedule_inspect"] + (edit.isWeekdays ? ["schedule_weekdays"] : [])
        case let .runAll(_, at), let .runAccount(_, _, at):
            ["expected_installation_id"] + (at == nil ? [] : ["scoped_slot_overlap"])
        case .enroll: ["expected_installation_id"]
        case .scheduleEnable, .scheduleDisable: ["expected_installation_id", "expected_revision"]
        case let .scheduleSetting(setting, _, date):
            ["expected_installation_id", "expected_revision", setting.feature] + (date == nil ? [] : ["expected_local_date"])
        case let .scheduleEdit(edit, _, _):
            ["expected_installation_id", "expected_revision", "expected_local_date"] + (edit.isWeekdays ? ["schedule_weekdays"] : [])
        }
    }

    /// Structured argv after the script path. `installationId` is required for mutations.
    public func arguments(installationId: String?) throws -> [String] {
        var args: [String]
        switch self {
        case .status: args = ["status"]
        case .list: args = ["list"]
        case let .history(account, since):
            args = ["history"]
            if let account { try Selector.check(account, Selector.identifier, "account"); args += ["--account", account] }
            if let since { try Selector.check(since, Selector.since, "since"); args += ["--since", since] }
        case let .timing(account):
            args = ["timing"]
            if let account { try Selector.check(account, Selector.identifier, "account"); args += ["--account", account] }
        case .scheduleInspect: args = ["schedule", "inspect"]
        case let .scheduleInspectSlot(slot):
            try Selector.check(slot, Selector.slot, "slot")
            args = ["schedule", "inspect", "--slot", slot]
        case let .scheduleInspectProposal(edit): args = ["schedule", "inspect"] + (try edit.arguments())
        case let .runAll(overlap, at): args = ["run"] + (try Self.overlap(overlap, at))
        case let .runAccount(id, overlap, at):
            try Selector.check(id, Selector.identifier, "enrollment")
            args = ["run", "--account", id] + (try Self.overlap(overlap, at))
        case let .enroll(ref):
            try Selector.check(ref, Selector.identifier, "routerAccount")
            args = ["enroll", "--account", ref]
        case let .scheduleEnable(revision): args = ["schedule", "enable"] + (try Self.revision(revision))
        case let .scheduleDisable(revision): args = ["schedule", "disable"] + (try Self.revision(revision))
        case let .scheduleSetting(setting, revision, date):
            args = ["schedule"] + (try setting.arguments()) + (try Self.revision(revision))
            if let date {
                guard setting.usesLocalDate else { throw CommandError.invalidArgument("localDate") }
                try Selector.check(date, Selector.date, "localDate")
                args += ["--expected-local-date", date]
            }
        case let .scheduleEdit(edit, revision, date):
            try Selector.check(date, Selector.date, "localDate")
            args = ["schedule"] + (try edit.arguments()) + (try Self.revision(revision)) + ["--expected-local-date", date]
        }
        if self.isMutation {
            guard let installationId else { throw CommandError.invalidArgument("installationId") }
            try Selector.check(installationId, Selector.installation, "installationId")
            args += ["--expected-installation-id", installationId]
        }
        return args
    }

    /// An instant scope is meaningful only with the override itself, and the override is only
    /// sent scoped to one instant: a bare override could cover a slot that became next later.
    private static func overlap(_ allowed: Bool, _ at: Int?) throws -> [String] {
        guard allowed else {
            if at != nil { throw CommandError.invalidArgument("overlapAt") }
            return []
        }
        guard let at else { throw CommandError.invalidArgument("overlapAt") }
        let valid = 100_000_000_000...9_007_199_254_740_991
        guard valid.contains(at) else { throw CommandError.invalidArgument("overlapAt") }
        return ["--allow-slot-overlap", "--overlap-at", String(at)]
    }

    private static func revision(_ value: Int) throws -> [String] {
        guard value >= 0, value <= 9_007_199_254_740_991 else { throw CommandError.invalidArgument("revision") }
        return ["--expected-revision", String(value)]
    }
}

extension ScheduleEdit {
    var isWeekdays: Bool { if case .weekdays = self { true } else { false } }
}
