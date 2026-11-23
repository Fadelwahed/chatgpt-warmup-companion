import Foundation

/// SF Symbols for the status menu's action items. macOS 26 menus show a leading icon for common
/// actions; the state lines above them already carry their own symbols.
public enum MenuIcons {
    public static let warmUp = "flame"
    public static let pause = "pause.circle"
    public static let resume = "play.circle"
    public static let open = "macwindow"
    public static let settings = "gearshape"
    public static let quit = "power"

    /// The pause item's title and symbol for the schedule's current state.
    public static func pauseItem(scheduleEnabled: Bool?) -> (title: String, symbol: String) {
        scheduleEnabled == false ? ("Resume Scheduling…", Self.resume) : ("Pause Scheduling…", Self.pause)
    }

    /// Every symbol the menu uses, so a test can check that each one exists.
    public static let all = [warmUp, pause, resume, open, settings, quit]
}

/// Words and a symbol for a pane with nothing to show (shown with `ContentUnavailableView`).
public struct EmptyState: Equatable, Sendable {
    public let title: String
    public let symbol: String
    public let description: String?
    /// A Terminal command the operator copies and completes; Warm-up never runs it.
    public let command: String?

    public init(title: String, symbol: String, description: String? = nil, command: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.description = description
        self.command = command
    }

    /// Schedule's detail column before a time is chosen.
    public static let noSlotSelected = EmptyState(
        title: "No time selected", symbol: "calendar.badge.clock",
        description: "Select a time to see what happened for each account.")

    /// The Accounts table while it has no rows.
    public static func accounts(isBound: Bool, loaded: Bool, failed: Bool) -> EmptyState {
        if !isBound {
            return EmptyState(
                title: "Setup required", symbol: "link.badge.plus",
                description: "Warm-up has no verified engine connection yet.")
        }
        if !loaded {
            return failed
                ? EmptyState(
                    title: "Accounts unavailable", symbol: "exclamationmark.triangle",
                    description: "The account list could not be read. Refresh to try again.")
                : EmptyState(title: "Loading accounts…", symbol: "person.2")
        }
        return EmptyState(
            title: "No accounts", symbol: "person.2.slash", description: "The engine reports no Router accounts.")
    }

    /// Schedule details while no engine connection exists: the reason instead of a spinner.
    public static func detailsUnavailable(_ issue: BindingIssue?) -> EmptyState {
        EmptyState(
            title: "Details unavailable", symbol: "link.badge.plus",
            description: issue.map { "\($0.description)." } ?? "Warm-up has no verified engine connection.")
    }

    /// First run, or a binding Warm-up refuses: what is wrong and the one-time step that fixes it, with
    /// the provisioning command for this app's own executable (`executable`, quoted for the shell) and
    /// the three values the operator fills in. An engine that changed under a good binding has its own
    /// reconnect card instead (`ReconnectCard`), which fills the values in from status.
    public static func setup(_ issue: BindingIssue, executable: String) -> EmptyState? {
        let command = [
            ReconnectCard.quote(executable), "--provision-binding", "--node", "'NODE'", "--script", "'SCRIPT'",
            "--expect-build", "'sha256:DIGEST'",
        ].joined(separator: " ")
        let steps =
            "Quit Warm-up, run this in Terminal with NODE, SCRIPT and DIGEST replaced, inside the quotes, by the engine's "
            + "node path, script path and build digest (README, Install), then open Warm-up again."
        switch issue {
        case .engineMismatch:
            return nil
        case .missing:
            return EmptyState(
                title: "Connect Warm-up to the engine", symbol: "link.badge.plus",
                description: "Warm-up reads the engine only through a connection you review once. \(steps) "
                    + "Warm-up never connects itself.",
                command: command)
        case .corrupt, .unsafeFile, .pathNotCanonical:
            return EmptyState(
                title: "Engine connection refused", symbol: "lock.trianglebadge.exclamationmark",
                description: "\(issue.description). Nothing is read until a fresh connection is written. \(steps)",
                command: command)
        }
    }
}
