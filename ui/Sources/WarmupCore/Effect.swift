import Foundation

// App 0.5, backlog item 3 ("Did it help?"): the app keeps every usage observation it reads and
// reports whether warm-ups start a fresh short window. The engine's `history` carries no usage and
// `status` only the latest observation per account, so this covers sends seen while the app ran.
// It is an observation of the provider's headers, never a control and never proof of cause.

/// The short usage window (under a day) the engine saw at one send. Accounts are kept by their
/// enrollment ID in the app's private folder only; reports number them instead.
public struct UsageObservation: Codable, Sendable, Equatable {
    public let account: String
    public let observedAt: Int
    public let windowMinutes: Int?
    public let resetsAt: Int?
    public let usedPercent: Double?

    public init(account: String, observedAt: Int, windowMinutes: Int?, resetsAt: Int?, usedPercent: Double?) {
        self.account = account
        self.observedAt = observedAt
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.usedPercent = usedPercent
    }
}

public struct UsageLog: Codable, Sendable, Equatable {
    public static let retentionMilliseconds = 60 * 86_400_000
    public static let maxRows = 1_000
    /// Windows of a day or longer are weekly-style allowances, not the window a warm-up starts.
    public static let shortWindowLimitMinutes = 1_440

    public private(set) var rows: [UsageObservation] = []

    public init(rows: [UsageObservation] = []) { self.rows = rows.sorted { $0.observedAt < $1.observedAt } }

    /// Adds each account's latest observation when it is new, then drops rows past retention (on
    /// every read, so nothing outlives the 60 days). Returns whether the log changed.
    public mutating func record(_ accounts: [AccountState], now: Int) -> Bool {
        var changed = false
        for account in accounts {
            guard let usage = account.usage, usage.observedAt > 0, usage.observedAt <= now + 60_000,
                !self.rows.contains(where: { $0.account == account.enrollmentId && $0.observedAt == usage.observedAt })
            else { continue }
            let window = Self.shortWindow(usage)
            self.rows.append(
                UsageObservation(
                    account: account.enrollmentId, observedAt: usage.observedAt, windowMinutes: window?.windowMinutes,
                    resetsAt: window?.resetsAt, usedPercent: window?.usedPercent))
            changed = true
        }
        let before = self.rows.count
        if changed { self.rows.sort { $0.observedAt < $1.observedAt } }
        let cutoff = now - Self.retentionMilliseconds
        self.rows.removeAll { $0.observedAt < cutoff }
        if self.rows.count > Self.maxRows { self.rows.removeFirst(self.rows.count - Self.maxRows) }
        return changed || self.rows.count != before
    }

    /// Primary first, then secondary; nil when neither reports a window shorter than a day.
    static func shortWindow(_ usage: AccountUsage) -> UsageWindow? {
        [usage.primary, usage.secondary].compactMap { $0 }
            .first { ($0.windowMinutes ?? Int.max) < Self.shortWindowLimitMinutes }
    }
}

/// What one send's headers say about the short window.
public enum WindowEffect: String, Sendable, CaseIterable {
    /// The reset is one window length after the send: this send (or one just before it) opened it.
    case startedFresh
    /// The reset comes sooner: a window was already running, so the send changed nothing.
    case insideRunning
    /// Inside a running window with 10 minutes or less left: it may have reset seconds later, so the
    /// send says nothing either way. Named "landed just before the old window reset".
    case atBoundary
    /// No window shorter than a day was reported.
    case noShortWindow
    /// A window without a reset time, or a reset that fits neither case.
    case unclear
}

public struct EffectSummary: Sendable, Equatable {
    public let counts: [WindowEffect: Int]
    public let total: Int
    public let verdict: String
    /// One line per account, numbered in status order: "Account 1: 5 fresh, 1 inside a running window".
    public let lines: [String]

    public func count(_ effect: WindowEffect) -> Int { self.counts[effect] ?? 0 }

    /// Sends with a clear answer, as the verdict counts them: fresh, inside a running window, or no short window.
    public var clear: Int { self.count(.startedFresh) + self.count(.insideRunning) + self.count(.noShortWindow) }
}

public enum EffectReport {
    public static let periodDays = 14
    public static let minimumSends = 10
    /// The send is recorded when its reply ends, up to about a minute after the request.
    public static let toleranceMilliseconds = 10 * 60_000
    public static let stopRule =
        "Stop rule: if, after OpenAI's December allowance change, most warm-ups start no fresh window, "
        + "turn the schedule off and keep only manual warm-ups."
    public static let scope =
        "Read from the latest send the engine reports at each status check while Warm-up is open, so "
        + "some sends can be missed or seen late. An observation of the provider's headers, not proof."
    /// Sane epoch milliseconds (2001 to 2286): anything else in a stored file is not evidence.
    static let validInstants = 1_000_000_000_000...9_999_999_999_999

    public static func classify(_ row: UsageObservation) -> WindowEffect {
        guard let minutes = row.windowMinutes else { return .noShortWindow }
        // Bounded inputs keep the arithmetic below from overflowing on a tampered file.
        guard let reset = row.resetsAt, Self.validInstants.contains(reset), Self.validInstants.contains(row.observedAt),
            (1..<UsageLog.shortWindowLimitMinutes).contains(minutes), reset > row.observedAt
        else { return .unclear }
        let freshReset = row.observedAt + minutes * 60_000
        let fresh = abs(reset - freshReset) <= Self.toleranceMilliseconds
        let nearEnd = reset - row.observedAt <= Self.toleranceMilliseconds
        // A window this short can match both; neither reading is safe, so it is unclear.
        if fresh && nearEnd { return .unclear }
        if fresh { return .startedFresh }
        if reset < freshReset - Self.toleranceMilliseconds { return nearEnd ? .atBoundary : .insideRunning }
        return .unclear
    }

    /// The last 14 days for the accounts in `order` (status order); rows of other accounts are left out.
    /// With `countFrom` (epoch ms, the start of the chosen day) every kept row from then on counts instead.
    public static func summary(_ log: UsageLog, order: [String], now: Int, countFrom: Int? = nil) -> EffectSummary {
        let rows = Self.counted(log, order: order, now: now, countFrom: countFrom)
        var counts: [WindowEffect: Int] = [:]
        for row in rows { counts[Self.classify(row), default: 0] += 1 }
        let lines = order.enumerated().compactMap { index, account -> String? in
            let own = rows.filter { $0.account == account }
            guard !own.isEmpty else { return nil }
            var tally: [WindowEffect: Int] = [:]
            for row in own { tally[Self.classify(row), default: 0] += 1 }
            return "Account \(index + 1): " + Self.parts(tally).joined(separator: ", ")
        }
        return EffectSummary(
            counts: counts, total: rows.count, verdict: Self.verdict(counts, total: rows.count), lines: lines)
    }

    /// Rows in the counting period, oldest first: from `countFrom` when set, otherwise the last 14 days.
    static func counted(_ log: UsageLog, order: [String], now: Int, countFrom: Int?) -> [UsageObservation] {
        let cutoff = countFrom ?? now - Self.periodDays * 86_400_000
        return log.rows.filter {
            $0.observedAt >= cutoff && $0.observedAt <= now + 60_000 && order.contains($0.account)
        }
    }

    /// Counts only sends with a clear answer (never `atBoundary` or `unclear`); a tie or too few of them says so instead of a verdict.
    /// The stop rule itself is for data after the December change, so the verdict never invokes it.
    static func verdict(_ counts: [WindowEffect: Int], total: Int) -> String {
        let fresh = counts[.startedFresh] ?? 0
        let notFresh = (counts[.insideRunning] ?? 0) + (counts[.noShortWindow] ?? 0)
        let clear = fresh + notFresh
        if total == 0 { return "No warm-up with usage data seen yet." }
        if clear < Self.minimumSends {
            return "Too early to tell: \(clear) of \(Self.minimumSends) warm-ups with a clear answer."
        }
        if fresh * 2 > clear {
            return "Of \(clear) warm-ups with a clear answer, \(fresh) started a fresh window."
        }
        if notFresh * 2 > clear {
            return "Of \(clear) warm-ups with a clear answer, \(notFresh) started no fresh window."
        }
        return "No clear answer: \(fresh) of \(clear) warm-ups with a clear answer started a fresh window."
    }

    static let effectWords: [(WindowEffect, String)] = [
        (.startedFresh, "started a fresh window"), (.insideRunning, "inside a running window"),
        (.atBoundary, "landed just before the old window reset"), (.noShortWindow, "no short window"),
        (.unclear, "unclear"),
    ]

    /// The plain words for one class, as the per-account lines use them.
    public static func words(_ effect: WindowEffect) -> String {
        Self.effectWords.first { $0.0 == effect }?.1 ?? "unclear"
    }

    static func parts(_ tally: [WindowEffect: Int]) -> [String] {
        Self.effectWords.compactMap { effect, word in
            guard let count = tally[effect], count > 0 else { return nil }
            return "\(count) \(word)"
        }
    }

    /// Copyable text: counts, accounts numbered, no IDs. Per-send lines (only when `rows` are passed)
    /// use each row's "Account N" label, never a nickname.
    public static func text(_ summary: EffectSummary, rows: [EffectRow] = [], countFromLabel: String? = nil) -> String {
        let period = countFromLabel.map { "since \($0)" } ?? "last \(Self.periodDays) days"
        var lines = ["Did it help? (\(period))", summary.verdict]
        lines.append(EffectProgress.text(clear: summary.clear, countFromLabel: countFromLabel))
        if let countFromLabel { lines.append("Counting from \(countFromLabel)") }
        lines += summary.lines
        lines += rows.map { "\($0.time) · \($0.numberLabel): \($0.effectWords)" }
        return (lines + [Self.scope, Self.stopRule]).joined(separator: "\n")
    }
}

/// A Codable value kept in the app's private 0700 folder as a 0600 regular file. Reads are bounded
/// and never follow a link; writes go to a 0600 temporary file that is renamed into place. Anything
/// unexpected loads the empty value: these files are evidence, not controls.
public struct PrivateJSONStore<Value: Codable>: Sendable {
    public let file: URL
    public let limit: Int
    private let empty: @Sendable () -> Value

    public init(directory: URL, name: String, limit: Int, empty: @escaping @Sendable () -> Value) {
        self.file = directory.appendingPathComponent(name)
        self.limit = limit
        self.empty = empty
    }

    var directoryIsPrivate: Bool {
        var info = stat()
        let path = self.file.deletingLastPathComponent().path
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    public func load() -> Value {
        guard self.directoryIsPrivate else { return self.empty() }
        let fd = open(self.file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return self.empty() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
            (info.st_mode & 0o077) == 0, info.st_size >= 0, info.st_size <= self.limit
        else { return self.empty() }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, Int(info.st_size)) }
        guard count == Int(info.st_size), let value = try? JSONDecoder().decode(Value.self, from: data)
        else { return self.empty() }
        return value
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        guard self.directoryIsPrivate, let data = try? JSONEncoder().encode(value), data.count <= self.limit
        else { return false }
        let temporary = self.file.deletingLastPathComponent().appendingPathComponent(
            ".\(self.file.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temporary.path, self.file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// Deletes the file; true when it is gone (or was never there).
    @discardableResult
    public func remove() -> Bool {
        unlink(self.file.path) == 0 || errno == ENOENT
    }
}

public typealias SleepJournalStore = PrivateJSONStore<SleepJournal>
public typealias UsageLogStore = PrivateJSONStore<UsageLog>

extension PrivateJSONStore where Value == SleepJournal {
    public static var maxBytes: Int { 256 << 10 }
    public init(directory: URL) {
        self.init(directory: directory, name: "sleep-journal.json", limit: Self.maxBytes) { SleepJournal() }
    }
}

extension PrivateJSONStore where Value == UsageLog {
    public static var maxBytes: Int { 512 << 10 }
    public init(directory: URL) {
        self.init(directory: directory, name: "usage-log.json", limit: Self.maxBytes) { UsageLog() }
    }
}
