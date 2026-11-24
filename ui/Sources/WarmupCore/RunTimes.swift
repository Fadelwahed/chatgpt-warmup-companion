import Foundation

/// The minute each slot ran or runs, keyed by slot label ("2026-11-24T13:00" → "13:10"), so a time
/// moved with `--today` reads the same on Overview, in Needs attention, in the CLI and in alerts
/// (app 0.6.9). The slot label stays the key for every lookup, click and acknowledgement; only the
/// words people read change.
public struct RunTimes: Sendable, Equatable {
    /// Resolved minutes, only where they differ from the label's own time.
    let byLabel: [String: String]

    init(byLabel: [String: String]) { self.byLabel = byLabel }

    public static let none = RunTimes(byLabel: [:])

    /// Sources, later ones winning:
    ///   1. projection admissions (any listed day; only when ProjectionCheck.sameSchedule(projection, status));
    ///   2. status.slotLedger rows' `admission` (the engine's record of a time that passed unsent).
    /// Only values that pass TodayMark.isClock (plain HH:mm) are kept. A value equal to the label's
    /// own time is not stored.
    public static func make(status: EngineStatus?, projection: ScheduleProjection?) -> RunTimes {
        guard let status else { return .none }
        let projected =
            projection.flatMap { ProjectionCheck.sameSchedule(projection: $0, status: status) ? $0 : nil }?
            .days.flatMap(\.admissions).map { (slot: $0.slot, time: $0.admission) } ?? []
        let recorded = status.slotLedger.map { (slot: $0.slot, time: $0.admission) }
        return Self.resolve(projected: projected, recorded: recorded)
    }

    /// The shared rule: the first projected minute per label, then every recorded minute over it. The
    /// equal-to-own-time filter runs last, so a recorded "13:00" still hides a projected "13:10".
    static func resolve(projected: [(slot: String, time: String)], recorded: [(slot: String, time: String)])
        -> RunTimes
    {
        var times: [String: String] = [:]
        for entry in projected where times[entry.slot] == nil && TodayMark.isClock(entry.time) {
            times[entry.slot] = entry.time
        }
        for entry in recorded where TodayMark.isClock(entry.time) { times[entry.slot] = entry.time }
        return RunTimes(byLabel: times.filter { FriendlyTime.split($0.key)?.1 != $0.value })
    }

    /// The time to show for `slot`: the resolved minute, else the label's own "HH:mm"; nil when the
    /// label is not a slot label.
    public func time(of slot: String) -> String? {
        guard let (_, own) = FriendlyTime.split(slot) else { return nil }
        return self.byLabel[slot] ?? own
    }
}
