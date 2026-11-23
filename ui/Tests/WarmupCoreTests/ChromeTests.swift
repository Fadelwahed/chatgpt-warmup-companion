import AppKit
import Testing

@testable import WarmupCore

/// Menu icons and empty states (2026-11-23 UI pass).
@Suite struct ChromeTexts {
    @Test func everyMenuAndEmptyStateSymbolExists() {
        let empties: [EmptyState] =
            [
                .noSlotSelected,
                .accounts(isBound: false, loaded: false, failed: false),
                .accounts(isBound: true, loaded: false, failed: false),
                .accounts(isBound: true, loaded: false, failed: true),
                .accounts(isBound: true, loaded: true, failed: false),
            ]
            + [BindingIssue.missing, .corrupt, .unsafeFile("file")].compactMap {
                EmptyState.setup($0, executable: "/x")
            }
            + [.detailsUnavailable(nil)]
        for symbol in MenuIcons.all + empties.map(\.symbol) {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "missing \(symbol)")
        }
    }

    @Test func pauseItemFollowsTheSchedule() {
        #expect(MenuIcons.pauseItem(scheduleEnabled: true) == ("Pause Scheduling…", MenuIcons.pause))
        #expect(MenuIcons.pauseItem(scheduleEnabled: false) == ("Resume Scheduling…", MenuIcons.resume))
        // Unknown (no status yet) offers Pause, which stays disabled until a read succeeds.
        #expect(MenuIcons.pauseItem(scheduleEnabled: nil).title == "Pause Scheduling…")
    }

    @Test func accountsEmptyStateOrder() {
        #expect(EmptyState.accounts(isBound: false, loaded: true, failed: true).title == "Setup required")
        #expect(EmptyState.accounts(isBound: true, loaded: false, failed: false).title == "Loading accounts…")
        #expect(EmptyState.accounts(isBound: true, loaded: false, failed: true).title == "Accounts unavailable")
        #expect(EmptyState.accounts(isBound: true, loaded: true, failed: false).title == "No accounts")
    }

    @Test func setupStateExplainsTheOneTimeStep() throws {
        let exe = "/Users/me/Apps/Warm-up's.app/Contents/MacOS/WarmupMenu"
        let missing = try #require(EmptyState.setup(.missing, executable: exe))
        #expect(missing.description?.contains("never connects itself") == true)
        // The app reads its binding only at launch, so both cards say to quit and reopen.
        #expect(missing.description?.contains("Quit Warm-up") == true)
        #expect(missing.description?.contains("open Warm-up again") == true)
        // The real executable, shell-quoted, with all three required flags.
        #expect(
            missing.command
                == "'/Users/me/Apps/Warm-up'\\''s.app/Contents/MacOS/WarmupMenu' --provision-binding --node 'NODE' "
                + "--script 'SCRIPT' --expect-build 'sha256:DIGEST'")
        let refused = try #require(EmptyState.setup(.pathNotCanonical("node"), executable: exe))
        #expect(refused.description?.hasPrefix(BindingIssue.pathNotCanonical("node").description) == true)
        #expect(refused.description?.contains("open Warm-up again") == true)
        #expect(refused.command == missing.command)
        // A changed engine keeps its reconnect card, which already fills in the command.
        #expect(EmptyState.setup(.engineMismatch("build"), executable: exe) == nil)
    }

    @Test func detailsUnavailableNamesTheReason() {
        #expect(EmptyState.detailsUnavailable(.missing).description == "\(BindingIssue.missing.description).")
        #expect(EmptyState.detailsUnavailable(nil).description == "Warm-up has no verified engine connection.")
    }
}
