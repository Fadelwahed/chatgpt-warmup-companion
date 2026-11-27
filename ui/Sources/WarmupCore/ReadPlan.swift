import Foundation

// App 0.6 (F5, plan P1 and P3): which reads a refresh needs after `status`, so the window's 30-second
// timer starts the engine only when something it shows can have changed. Pure; nothing is read here.

/// A read the app may run after `status` (which is always read).
public enum ReadKind: String, Sendable, Hashable, CaseIterable {
    /// `schedule inspect`
    case inspect
    case history
    case list
    /// `pmset -g sched`
    case wake
    /// `schedule inspect --slot` for the selected time
    case slotDetail
}

/// The window tab on screen, or none when the window is closed.
public enum VisibleTab: String, Sendable, Equatable {
    case overview, schedule, accounts, settings, none
}

public struct ReadContext: Sendable, Equatable {
    public var visibleTab: VisibleTab
    public var scheduleBecameVisible: Bool
    public var accountsBecameVisible: Bool
    /// A mutation just finished.
    public var afterChange: Bool
    /// The operator pressed Refresh.
    public var force: Bool
    public var lastList: Date?
    public var lastWake: Date?
    public var now: Date
    public var localDateChanged: Bool
    public var selectedSlotInProgress: Bool
    /// A time is selected in the Schedule tab.
    public var hasSelectedSlot: Bool
    /// The last detail read for the current selection failed.
    public var selectedDetailFailed: Bool

    public init(
        visibleTab: VisibleTab = .none, scheduleBecameVisible: Bool = false, accountsBecameVisible: Bool = false,
        afterChange: Bool = false, force: Bool = false, lastList: Date? = nil, lastWake: Date? = nil, now: Date,
        localDateChanged: Bool = false, selectedSlotInProgress: Bool = false, hasSelectedSlot: Bool = false,
        selectedDetailFailed: Bool = false
    ) {
        self.visibleTab = visibleTab
        self.scheduleBecameVisible = scheduleBecameVisible
        self.accountsBecameVisible = accountsBecameVisible
        self.afterChange = afterChange
        self.force = force
        self.lastList = lastList
        self.lastWake = lastWake
        self.now = now
        self.localDateChanged = localDateChanged
        self.selectedSlotInProgress = selectedSlotInProgress
        self.hasSelectedSlot = hasSelectedSlot
        self.selectedDetailFailed = selectedDetailFailed
    }
}

public enum ReadPlan {
    public static let listInterval: TimeInterval = 5 * 60
    public static let wakeInterval: TimeInterval = 10 * 60
    public static let menuOpenFreshness: TimeInterval = 10

    /// The reads to run after `status`. `previous` is the status before this one (nil at launch).
    public static func reads(previous: EngineStatus?, current: EngineStatus, context: ReadContext) -> Set<ReadKind> {
        var reads: Set<ReadKind> = []
        let first = previous == nil
        let explicit = context.force
        let outcomeMoved = previous?.lastSlotOutcome?.at != current.lastSlotOutcome?.at
        // A miss can land only in the ledger or the blocked list (060-FIX1 items 5 and 6).
        let evidenceMoved =
            previous.map { $0.slotLedger != current.slotLedger || $0.blockedSlots != current.blockedSlots } ?? false
        if first || explicit || context.afterChange || context.scheduleBecameVisible || context.localDateChanged
            || outcomeMoved || evidenceMoved || previous?.scheduleRevision != current.scheduleRevision
            || previous?.next?.slot != current.next?.slot || previous?.activeBatch != current.activeBatch
        {
            reads.insert(.inspect)
        }
        if first || explicit || outcomeMoved || evidenceMoved || context.localDateChanged
            || previous?.recent != current.recent
        {
            reads.insert(.history)
        }
        if first || explicit || context.afterChange || context.accountsBecameVisible
            || Self.due(context.lastList, every: Self.listInterval, now: context.now)
        {
            reads.insert(.list)
        }
        if first || explicit || previous?.next != current.next || context.scheduleBecameVisible
            || Self.due(context.lastWake, every: Self.wakeInterval, now: context.now)
        {
            reads.insert(.wake)
        }
        let selectionStale =
            context.hasSelectedSlot
            && (evidenceMoved || previous?.lastSlotOutcome != current.lastSlotOutcome || context.selectedDetailFailed)
        if explicit || context.selectedSlotInProgress || selectionStale { reads.insert(.slotDetail) }
        return reads
    }

    /// P3: opening the menu reads status only when the last good read is 10 seconds old or more.
    public static func menuOpenNeedsRead(lastGoodRead: Date?, now: Date) -> Bool {
        guard let lastGoodRead else { return true }
        let age = now.timeIntervalSince(lastGoodRead)
        return age < 0 || age >= Self.menuOpenFreshness
    }

    /// Never read, read longer ago than `interval`, or a clock that moved backward.
    static func due(_ last: Date?, every interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age >= interval
    }
}
