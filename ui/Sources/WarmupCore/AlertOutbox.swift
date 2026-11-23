import Foundation

// 060-FIX7 item 1: the outbox is the one record of what is owed, one entry per slot. An entry leaves
// it only after macOS accepted a notification naming its slot; only then is the slot announced and
// released from the tracker. Grouping happens only when a notification is composed for delivery.
// Entries hold only the problem fields needed to compose (slot label, codes, counts, zone): no
// installation, enrollment or account identifiers.
//
// The outbox file never shipped (0.5.1 has none), so a file that cannot be read in this shape, an
// earlier development shape included, loads as an empty outbox: there is no legacy handling.

/// One owed alert: a problem with one slot, or the incomplete-history notice.
public struct PendingAlert: Sendable, Equatable, Codable {
    public enum Problem: Sendable, Equatable, Codable {
        case slot(SlotProblem.Kind)
        /// "Some earlier warm-ups could not be checked"; opens `latestSlot`, or Overview when empty.
        case incompleteHistory(latestSlot: String)
    }

    /// The incomplete-history notice's fixed key: there is at most one, about no particular slot.
    public static let noticeKey = ""

    /// The outbox key: the slot label, or `noticeKey`.
    public let slot: String
    public let problem: Problem
    /// The schedule zone the slot label is in, for the notification text.
    public let zone: String
    /// Engine milliseconds: when the problem was recorded, or where the unread history gap starts.
    public let detectedAt: Int

    public init(slot: String, problem: Problem, zone: String, detectedAt: Int) {
        self.slot = slot
        self.problem = problem
        self.zone = zone
        self.detectedAt = detectedAt
    }

    public init(_ problem: SlotProblem, zone: String) {
        self.init(slot: problem.slot, problem: .slot(problem.kind), zone: zone, detectedAt: problem.at)
    }

    /// The notice for `status`, owed since the gap that could not be read starts at `gapStart`.
    public static func incompleteHistory(for status: EngineStatus, gapStart: Int) -> PendingAlert {
        PendingAlert(
            slot: Self.noticeKey, problem: .incompleteHistory(latestSlot: status.lastSlotOutcome?.slot ?? ""),
            zone: status.schedule.zone, detectedAt: gapStart)
    }

    /// The slot problem to compose from; nil for the notice.
    public var slotProblem: SlotProblem? {
        guard case let .slot(kind) = self.problem else { return nil }
        return SlotProblem(slot: self.slot, kind: kind, at: self.detectedAt)
    }

    /// A slot entry with a real slot label, or the notice under its fixed key.
    var isWellFormed: Bool {
        switch self.problem {
        case .slot: SlotProblem.isSlot(self.slot)
        case .incompleteHistory: self.slot == Self.noticeKey
        }
    }
}

/// Alerts owed and not yet accepted by macOS, oldest first, at most one per key.
public struct AlertOutbox: Sendable, Equatable, Codable {
    /// At most this many entries are kept. A new entry beyond it is refused, never an older one dropped.
    /// The 7-day look-back holds at most 21 scheduled slots; 200 also covers extra manual slots, so the
    /// refusal is for the impossible overflow only (060-FIX8 item 1).
    public static let limit = 200

    /// Shown while an alert is neither saved nor delivered.
    public static let unsavedIssue = "Alerts could not be saved; they will be retried."

    public let entries: [PendingAlert]

    public init(entries: [PendingAlert] = []) {
        self.entries = entries
    }

    /// Entries with a malformed key are left out, so they can never hold the cursor back.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decode([PendingAlert].self, forKey: .entries).filter(\.isWellFormed))
    }

    public var isEmpty: Bool { self.entries.isEmpty }

    public func contains(slot: String) -> Bool {
        self.entries.contains { $0.slot == slot }
    }

    /// Adds `entry` as the newest. A key already present is a no-op; at `limit` the entry is refused
    /// and the outbox returned unchanged. Check `contains(slot:)` to see whether it is owed now.
    public func adding(_ entry: PendingAlert) -> AlertOutbox {
        guard !self.contains(slot: entry.slot), self.entries.count < Self.limit else { return self }
        return AlertOutbox(entries: self.entries + [entry])
    }

    /// Removes exactly the entries with these keys.
    public func removing(slots: [String]) -> AlertOutbox {
        let delivered = Set(slots)
        return AlertOutbox(entries: self.entries.filter { !delivered.contains($0.slot) })
    }

    /// What one delivery attempt sends: every slot entry as one notification, then the notice.
    public var deliveries: [[PendingAlert]] {
        let problems = self.entries.filter { $0.slotProblem != nil }
        let notices = self.entries.filter { $0.slotProblem == nil }
        return (problems.isEmpty ? [] : [problems]) + notices.map { [$0] }
    }

    /// `covered` held before the oldest entry still owed, so an entry whose save failed is found again
    /// after a relaunch. Nil stays nil.
    public func capping(_ covered: Int?) -> Int? {
        guard let covered else { return nil }
        guard let oldest = self.entries.map(\.detectedAt).min() else { return covered }
        return min(covered, oldest - 1)
    }

    /// The storage problem to report: the last save failed while alerts are still waiting, or an alert
    /// was refused at the cap. Nil when everything waiting is on disk.
    public func issue(saved: Bool, refused: Bool) -> String? {
        refused || (!saved && !self.isEmpty) ? Self.unsavedIssue : nil
    }
}

public typealias AlertOutboxStore = PrivateJSONStore<AlertOutbox>

extension PrivateJSONStore where Value == AlertOutbox {
    public static var maxBytes: Int { 64 << 10 }
    public init(directory: URL) {
        self.init(directory: directory, name: "pending-alerts.json", limit: Self.maxBytes) { AlertOutbox() }
    }
}
