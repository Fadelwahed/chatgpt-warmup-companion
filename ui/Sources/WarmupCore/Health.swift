import Foundation

/// One plain-language health check for the Overview pane. A warning is something to look at; info
/// is context that never needs action (a choice, a missing wake that the Mac may not need).
public struct HealthRow: Sendable, Equatable, Identifiable {
    public enum Level: Sendable, Equatable { case ok, info, warning }

    public let title: String
    public let value: String
    public let level: Level
    public var id: String { self.title }

    public var symbolName: String {
        switch self.level {
        case .ok: "checkmark.circle"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        }
    }
}

public enum HealthCheck {
    /// Rows from one status reply, in the order an operator checks them.
    public static func rows(
        status: EngineStatus, observedAt: Int?, wake: WakeReadiness, nextLocalAdmission: String?, now: Date = Date()
    ) -> [HealthRow] {
        let zone = status.schedule.zone
        var rows: [HealthRow] = []
        if status.job == "loaded" {
            rows.append(HealthRow(title: "Background job", value: "running", level: .ok))
        } else {
            rows.append(
                status.scheduleEnabled
                    ? HealthRow(title: "Background job", value: "not running", level: .warning)
                    : HealthRow(title: "Background job", value: "stopped while paused", level: .info))
        }
        if let tick = status.lastTick {
            let stale = HeartbeatCheck.staleSince(status, observedAt: observedAt) != nil
            rows.append(
                HealthRow(
                    title: "Last check-in", value: FriendlyTime.instant(tick, now: now, zone: zone),
                    level: stale ? .warning : .ok))
        } else {
            rows.append(HealthRow(title: "Last check-in", value: "none yet", level: .info))
        }
        rows.append(
            status.compatibility == "ready"
                ? HealthRow(title: "Router", value: "compatible", level: .ok)
                : HealthRow(title: "Router", value: "needs a review", level: .warning))
        rows.append(
            status.enabled == 0
                ? HealthRow(title: "Accounts", value: "none turned on", level: .warning)
                : HealthRow(title: "Accounts", value: "\(status.enabled) of \(status.enrolled) on", level: .ok))
        if let lock = status.workLock, lock.state != "free" {
            let since = lock.since.map { " since \(FriendlyTime.instant($0, now: now, zone: zone))" } ?? ""
            switch lock.state {
            case "held": rows.append(HealthRow(title: "Engine", value: "working\(since)", level: .info))
            case "stale":
                rows.append(
                    HealthRow(
                        title: "Engine", value: "left busy by a stopped process\(since); clears by itself",
                        level: .warning))
            default: rows.append(HealthRow(title: "Engine", value: "busy\(since), owner unknown", level: .warning))
            }
        }
        if status.scheduleEnabled, status.next != nil {
            switch wake {
            case let .ready(wakeAt): rows.append(HealthRow(title: "Mac wake", value: "set for \(wakeAt)", level: .ok))
            case .notScheduled:
                let before = nextLocalAdmission.map { " before \($0)" } ?? ""
                rows.append(
                    HealthRow(title: "Mac wake", value: "none set\(before); the Mac must be awake", level: .info))
            case .unknown: break
            }
        }
        rows.append(
            HealthRow(
                title: "Time zone", value: status.timeZoneMode == "local" ? "\(zone), the Mac's" : "\(zone), fixed",
                level: .info))
        if status.recovery != "none" {
            rows.append(HealthRow(title: "Suggested", value: Wording.guidance(status.recovery), level: .warning))
        }
        return rows
    }

    /// True when no row needs a look; the section can then stay collapsed.
    public static func allFine(_ rows: [HealthRow]) -> Bool { !rows.contains { $0.level == .warning } }

    /// The collapsed Health row: "All checks pass", or the first check that needs a look.
    public static func collapsed(_ rows: [HealthRow]) -> String {
        guard let first = rows.first(where: { $0.level == .warning }) else { return "All checks pass" }
        return "\(first.title): \(first.value)"
    }

    /// "All checks pass" or "2 checks need a look".
    public static func summary(_ rows: [HealthRow]) -> String {
        let warnings = rows.filter { $0.level == .warning }.count
        return warnings == 0
            ? "All checks pass" : warnings == 1 ? "1 check needs a look" : "\(warnings) checks need a look"
    }
}

/// The one-time "Finish setting up" card: shown until the operator has answered both questions.
public enum SetupCard {
    /// A switch that is on counts as answered, even with no stored answer.
    public static func needed(alertsAnswered: Bool, loginAnswered: Bool, alertsOn: Bool, loginOn: Bool) -> Bool {
        !((alertsAnswered || alertsOn) && (loginAnswered || loginOn))
    }
}
