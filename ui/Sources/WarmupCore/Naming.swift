import Foundation

// App 0.6: account nicknames and "Hide account names" (F3), the reconnect command (F4) and reviewed
// possible sends (F8). Nicknames and reviewed times live only in the app's private folder; copied
// text, logs and CLI output keep "Account N". Nothing here is sent to the engine.

/// Nicknames by enrollment ID. Shown on screen, in menus and in VoiceOver labels only.
public struct AccountNames: Codable, Sendable, Equatable {
    public static let maxLength = 40

    public private(set) var names: [String: String]

    public init(names: [String: String] = [:]) {
        self.names = names.compactMapValues { name in
            let cleaned = Self.clean(name)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// A stored file is cleaned the same way, so a hand-edited name cannot carry control characters.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(names: try container.decode([String: String].self, forKey: .names))
    }

    public func nickname(for account: String) -> String? { self.names[account] }

    /// A new value with `name` (cleaned) for `account`; a blank name removes the nickname.
    public func setting(_ name: String, for account: String) -> AccountNames {
        var copy = self
        let cleaned = Self.clean(name)
        copy.names[account] = cleaned.isEmpty ? nil : cleaned
        return copy
    }

    /// Trims whitespace, removes control characters and newlines, and keeps at most 40 characters.
    /// An empty result means "no nickname".
    public static func clean(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(Self.maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum AccountNaming {
    /// Status accounts first, then any extra IDs from `list`, each once, in their order.
    public static func order(status: [String], list: [String]) -> [String] {
        var seen = Set(status)
        var order = status
        for account in list where !seen.contains(account) {
            seen.insert(account)
            order.append(account)
        }
        return order
    }

    /// The label per account: its nickname unless hidden or unset, otherwise "Account N" in `order`.
    public static func labels(order: [String], names: AccountNames, hidden: Bool) -> [String: String] {
        var labels: [String: String] = [:]
        for (index, account) in order.enumerated() where labels[account] == nil {
            let number = "Account \(index + 1)"
            labels[account] = hidden ? number : names.nickname(for: account) ?? number
        }
        return labels
    }

    /// "Account N" per account in `order`, whatever the nicknames: the names run results use.
    public static func numbers(order: [String]) -> [String: String] {
        self.labels(order: order, names: AccountNames(names: [:]), hidden: true)
    }

    /// The number shown beside a nickname, so a result naming "Account 2" matches its row (0.6.4).
    /// Nil when the row already shows its number.
    public static func numberBeside(label: String, number: String?) -> String? {
        guard let number, number != label else { return nil }
        return number
    }
}

/// The "Reconnect to the engine" card after an engine update. The app never rebinds itself; it only
/// fills in the operator's provisioning command.
public enum ReconnectCard {
    /// `'<executable>' --provision-binding --node '<node>' --script '<script>' --expect-build '<build>'`,
    /// or nil when status names no engine paths or build.
    public static func command(executable: String, status: EngineStatus) -> String? {
        guard let engine = status.engine, let build = status.engineBuild, !engine.nodePath.isEmpty,
            !engine.scriptPath.isEmpty, !build.isEmpty, !executable.isEmpty
        else { return nil }
        return [
            Self.quote(executable), "--provision-binding", "--node", Self.quote(engine.nodePath), "--script",
            Self.quote(engine.scriptPath), "--expect-build", Self.quote(build),
        ].joined(separator: " ")
    }

    /// Shown only when the engine no longer matches its binding.
    public static func shown(issue: BindingIssue?) -> Bool {
        if case .engineMismatch = issue { return true }
        return false
    }

    /// POSIX shell single quotes: `'` becomes `'\''`.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Possible sends without a result that the operator marked as reviewed, by their `at` time (engine
/// milliseconds). The engine's data is untouched; reviewed rows are only hidden in the app.
public struct ReviewedSends: Codable, Sendable, Equatable {
    public static let maxTimes = 2_000

    /// Reviewed times, oldest first, at most 2,000.
    public private(set) var times: [Int]

    public init(times: [Int] = []) {
        self.times = Array(Set(times).sorted().suffix(Self.maxTimes))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(times: try container.decode([Int].self, forKey: .times))
    }

    /// Rows not yet reviewed.
    public func visible(_ rows: [UnresolvedReservation]) -> [UnresolvedReservation] {
        let reviewed = Set(self.times)
        return rows.filter { !reviewed.contains($0.at) }
    }

    /// Rows already reviewed, for "Show reviewed".
    public func reviewed(_ rows: [UnresolvedReservation]) -> [UnresolvedReservation] {
        let reviewed = Set(self.times)
        return rows.filter { reviewed.contains($0.at) }
    }

    /// A new value with `rows`' times added; the oldest are dropped past 2,000.
    public func marking(_ rows: [UnresolvedReservation]) -> ReviewedSends {
        ReviewedSends(times: self.times + rows.map(\.at))
    }
}

public typealias AccountNamesStore = PrivateJSONStore<AccountNames>
public typealias ReviewedSendsStore = PrivateJSONStore<ReviewedSends>

extension PrivateJSONStore where Value == AccountNames {
    public static var maxBytes: Int { 64 << 10 }
    public init(directory: URL) {
        self.init(directory: directory, name: "account-names.json", limit: Self.maxBytes) { AccountNames() }
    }
}

extension PrivateJSONStore where Value == ReviewedSends {
    public static var maxBytes: Int { 64 << 10 }
    public init(directory: URL) {
        self.init(directory: directory, name: "reviewed-sends.json", limit: Self.maxBytes) { ReviewedSends() }
    }
}
