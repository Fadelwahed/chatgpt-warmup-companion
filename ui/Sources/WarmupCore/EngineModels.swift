import Foundation

// Decodable views of the engine's versioned JSON (protocolVersion 1). Only fields the app
// displays are decoded; unknown fields are ignored so additive engine changes stay compatible.
// The engine remains the only owner of these values; nothing here is written back.

public struct Envelope: Decodable, Sendable, Equatable {
    public let protocolVersion: Int
    public let engineVersion: String?
    public let command: String
    public let outcome: String
    public let reason: String
    public let installationId: String?
    public let observedAt: String
}

public struct Capability: Decodable, Sendable, Equatable {
    public let version: Int
    public let features: [String]
}

public struct EnginePaths: Decodable, Sendable, Equatable {
    public let nodePath: String
    public let scriptPath: String
}

public struct ScheduleInfo: Decodable, Sendable, Equatable {
    public let zone: String
    public let times: [String]
    public let weekdays: [Int]?
    /// Engine 1.2: saved vacation ranges (inclusive local dates).
    public let vacations: [VacationRange]?
}

public struct VacationRange: Decodable, Sendable, Equatable, Hashable {
    public let start: String
    public let end: String
}

public struct NextSlot: Decodable, Sendable, Equatable {
    public let slot: String
    public let admission: String
    public let date: String
    public let at: Int?
}

public struct AccountResult: Decodable, Sendable, Equatable {
    public let enrollmentId: String
    public let outcome: String
    public let reason: String
    public let dispatched: Bool?
    public let at: Int?
    /// Engine 1.1: true when the account was skipped before any send (cooldown, pilot, cap…).
    public let skipped: Bool?

    public init(
        enrollmentId: String, outcome: String, reason: String, dispatched: Bool?, at: Int?, skipped: Bool? = nil
    ) {
        self.enrollmentId = enrollmentId
        self.outcome = outcome
        self.reason = reason
        self.dispatched = dispatched
        self.at = at
        self.skipped = skipped
    }
}

public struct SlotOutcome: Decodable, Sendable, Equatable {
    public let slot: String
    public let zone: String?
    public let outcome: String?
    public let at: Int
    public let results: [AccountResult]?
}

public struct LedgerRow: Decodable, Sendable, Equatable {
    public let slot: String
    public let admission: String
    public let cause: String
    public let zone: String
    public let at: Int
}

public struct ActiveBatch: Decodable, Sendable, Equatable {
    public let slot: String
    public let enrollmentIds: [String]
    public let state: String
}

public struct ClockHold: Decodable, Sendable, Equatable {
    public let lastWall: Int
    public let highWater: String?
}

public struct AccountState: Decodable, Sendable, Equatable {
    public let enrollmentId: String
    public let block: String?
    public let cooldownUntil: Int?
    /// Engine 1.1: the latest usage-window evidence observed at send time (feature `usage_windows`).
    public let usage: AccountUsage?
}

/// One usage window as the backend reported it when a warm-up was sent.
public struct UsageWindow: Decodable, Sendable, Equatable {
    public let usedPercent: Double?
    public let windowMinutes: Int?
    public let resetsAt: Int?
}

public struct AccountUsage: Decodable, Sendable, Equatable {
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let observedAt: Int
}

/// Engine 1.1: who holds the work lock (feature `work_lock_status`). `since` is epoch milliseconds.
public struct WorkLock: Decodable, Sendable, Equatable {
    public let state: String
    public let since: Int?
}

public struct RecentOutcome: Decodable, Sendable, Equatable {
    public let enrollmentId: String
    public let outcome: String
    public let reason: String
    public let at: Int?
}

public struct UnresolvedReservation: Decodable, Sendable, Equatable {
    public let enrollmentId: String
    public let slot: String?
    public let at: Int
}

public struct EngineStatus: Decodable, Sendable, Equatable {
    public let schedule: ScheduleInfo
    public let scheduleEnabled: Bool
    public let scheduleRevision: Int
    public let job: String
    public let compatibility: String
    public let lastTick: Int?
    public let lastTickZone: String?
    public let timeZoneMode: String
    public let slotLedger: [LedgerRow]
    public let next: NextSlot?
    public let accounts: [AccountState]
    public let activeBatch: ActiveBatch?
    public let workLock: WorkLock?
    /// Engine 1.1: some accounts' usage was left out to keep the reply within its size limit.
    public let usageTruncated: Bool?
    /// Engine 1.2: nil schedules every enabled account; a list schedules only those.
    public let scheduledAccounts: [String]?
    public let caps: [String: Int]?
    public let undoAvailable: Bool?
    public let clockHold: ClockHold?
    public let lastSlotOutcome: SlotOutcome?
    /// Engine 1.2: recent scheduled batches the engine stopped (`blocked`), newest first.
    public var blockedSlots: [BlockedSlot]? = nil
    public let enrolled: Int
    public let enabled: Int
    public let pilots: Int
    public let recent: [RecentOutcome]
    public let unresolved: [UnresolvedReservation]
    /// The engine listed only the newest unresolved sends (or `recent` rows); nil reads as false.
    public var unresolvedTruncated: Bool? = nil
    public var historyTruncated: Bool? = nil
    public let recovery: String
    public let capability: Capability?
    public let engine: EnginePaths?
    public let engineBuild: String?
}

public struct ProjectedAdmission: Decodable, Sendable, Equatable, Identifiable {
    public let slot: String
    public let logicalTime: String
    public let admission: String
    public let at: Int?
    public let state: String
    public let cause: String?
    public let repeatedLocalTime: Int?
    public let next: Bool?
    public var id: String { "\(self.slot)#\(self.repeatedLocalTime ?? 0)" }
}

public struct ProjectedDay: Decodable, Sendable, Equatable, Identifiable {
    public let date: String
    public let weekday: Int
    public let source: String
    public let exclusion: String?
    public let admissions: [ProjectedAdmission]
    public let attemptsPerAccount: Int
    public let configuredAttempts: Int
    public var id: String { self.date }
}

public struct ZoneNotice: Decodable, Sendable, Equatable {
    public let previousZone: String
    public let zone: String
}

public struct ScheduleProjection: Decodable, Sendable, Equatable {
    public let scheduleEnabled: Bool
    public let scheduleRevision: Int
    public let timeZoneMode: String
    public let weekdays: [Int]
    public let times: [String]
    public let zoneNotice: ZoneNotice?
    public let localDate: String
    public let zone: String
    public let accounts: [String]
    public let days: [ProjectedDay]
    public let next: NextSlot?
}

public struct SlotAccount: Decodable, Sendable, Equatable, Identifiable {
    public let enrollmentId: String
    public let known: Bool
    public let outcome: String?
    public let reason: String?
    public let at: Int?
    public let skipped: Bool
    public let possibleSend: Bool
    public let reservationUnresolved: Bool
    public let dispatch: String
    public let response: String
    public let windowEffect: String
    public let guidance: String
    public var id: String { self.enrollmentId }
}

public struct NotAdmitted: Decodable, Sendable, Equatable {
    public let cause: String
    public let zone: String
    public let at: Int
    public let guidance: String
}

public struct Heartbeat: Decodable, Sendable, Equatable {
    public let lastTick: Int?
    public let lastTickZone: String?
    public let observedAfterAdmission: Bool?
}

public struct SlotExplanation: Decodable, Sendable, Equatable {
    public let slot: String
    public let date: String
    public let logicalTime: String
    public let verdict: String
    public let configured: Bool?
    public let exclusion: String?
    public let admission: String?
    public let admissionAt: Int?
    public let notAdmitted: NotAdmitted?
    public let activeBatch: Bool
    public let batchOutcome: String?
    public let accounts: [SlotAccount]
    public let heartbeat: Heartbeat
    public let windowEffect: String
    public let retentionDays: Int
}

public struct SlotExplanationResult: Decodable, Sendable, Equatable {
    public let zone: String
    public let explanation: SlotExplanation
}

public struct AccountRow: Decodable, Sendable, Equatable, Identifiable {
    public let routerAccountId: String
    public let enrollmentId: String?
    public let registryReason: String
    public let enrollmentState: String
    public let eligible: Bool
    public let enabled: Bool
    public let pilot: Bool
    public let lastOutcome: String?
    public let lastReason: String?
    public let lastAt: Int?
    public var id: String { self.routerAccountId }
}

public struct AccountList: Decodable, Sendable, Equatable {
    public let rows: [AccountRow]
}

public struct HistoryEntry: Decodable, Sendable, Equatable {
    public let enrollmentId: String?
    public let status: String?
    public let reason: String?
    public let mode: String?
    public let slot: String?
    public let at: Int?
    public let dispatched: Bool?
    /// Engine 1.2: the final outcome of the scheduled batch this row belongs to.
    public var batchOutcome: String? = nil
}

public struct BlockedSlot: Decodable, Sendable, Equatable {
    public let slot: String
    public let at: Int
    public init(slot: String, at: Int) {
        self.slot = slot
        self.at = at
    }
}

public struct HistoryReport: Decodable, Sendable, Equatable {
    public let rows: [HistoryEntry]
    public let truncated: Bool?
}

// MARK: - Mutation replies (A6)

/// A mutation reply type that can say whether an accepted change reported its result.
public protocol MutationPayload: Decodable, Sendable {
    var isComplete: Bool { get }
}

extension Envelope: MutationPayload {
    public var isComplete: Bool { true }
}

public struct OverlapSlot: Decodable, Sendable, Equatable {
    public let slot: String
    public let admission: String
    public let date: String
    /// Engine 1.1: the admission instant the refusal was about, used to scope Run Anyway.
    public let at: Int?

    public init(slot: String, admission: String, date: String, at: Int? = nil) {
        self.slot = slot
        self.admission = admission
        self.date = date
        self.at = at
    }
}

/// `run` reply. `attempted` counts dispatched requests, not allowance consumed.
public struct RunReply: MutationPayload, Equatable {
    public var isComplete: Bool { true } // decoding already requires selected, attempted and results
    public let selected: Int
    public let attempted: Int
    public let results: [AccountResult]
    public let overlap: OverlapSlot?
}

/// `schedule enable|disable|add|remove|move|weekdays` reply.
public struct ScheduleChangeReply: MutationPayload, Equatable {
    public var isComplete: Bool { self.scheduleRevision != nil }
    public let scheduleEnabled: Bool?
    public let scheduleRevision: Int?
    public let job: String?
    public let localDate: String?
}

public struct EnrollReply: MutationPayload, Equatable {
    public var isComplete: Bool { self.enrollmentId != nil }
    public let enrollmentId: String?
}

/// A proposed projection from `schedule inspect <edit>`. Its revision and local date are the
/// guards the save must carry.
public struct ProposedProjection: Decodable, Sendable, Equatable {
    public let localDate: String
    public let expectedRevision: Int
    public let weekdays: [Int]
    public let times: [String]
    public let zone: String
    public let days: [ProjectedDay]
}

public struct ProposalReply: Decodable, Sendable, Equatable {
    public let proposal: ProposedProjection
    /// The current projection the engine compared the proposal with, from the same reply.
    public let days: [ProjectedDay]?
}
