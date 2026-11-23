import Foundation
import Testing

@testable import WarmupCore

/// App 0.6 F3 (nicknames), F4 (reconnect command) and F8 (reviewed possible sends).
@Suite struct Naming {
    func status(edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    @Test func lookupAndHiddenMode() {
        let names = AccountNames(names: ["a": "Work"])
        #expect(names.nickname(for: "a") == "Work")
        #expect(names.nickname(for: "b") == nil)
        #expect(
            AccountNaming.labels(order: ["a", "b"], names: names, hidden: false) == ["a": "Work", "b": "Account 2"])
        #expect(
            AccountNaming.labels(order: ["a", "b"], names: names, hidden: true) == ["a": "Account 1", "b": "Account 2"])
    }

    @Test func cleaning() {
        #expect(AccountNames.clean("  Wo\u{07}rk\n ") == "Work")
        #expect(AccountNames.clean("Line\none") == "Lineone")
        #expect(AccountNames.clean(String(repeating: "x", count: 41)).count == 40)
        #expect(AccountNames.clean("   ").isEmpty)
        let named = AccountNames().setting(" Work ", for: "a")
        #expect(named.names == ["a": "Work"])
        #expect(named.setting("  ", for: "a").names.isEmpty)
        #expect(AccountNames(names: ["a": "\n"]).names.isEmpty)
    }

    @Test func orderAppendsExtrasFromList() {
        let order = AccountNaming.order(status: ["a", "b"], list: ["c", "a", "d", "c"])
        #expect(order == ["a", "b", "c", "d"])
        let labels = AccountNaming.labels(order: order, names: AccountNames(names: ["d": "Spare"]), hidden: false)
        #expect(labels == ["a": "Account 1", "b": "Account 2", "c": "Account 3", "d": "Spare"])
    }

    @Test func copiedTextsAreUnchangedByNicknames() {
        let eight = 1_794_463_200_000
        let log = UsageLog(rows: [
            UsageObservation(
                account: "a", observedAt: eight, windowMinutes: 300, resetsAt: eight + 18_000_000, usedPercent: 1)
        ])
        let summary = EffectReport.summary(log, order: ["a"], now: eight)
        let named = AccountNaming.labels(order: ["a"], names: AccountNames(names: ["a": "Work"]), hidden: false)
        let plain = EffectReport.rows(
            log: log, order: ["a"], labels: [:], countFrom: nil, now: eight, zone: "Asia/Gaza")
        let nick = EffectReport.rows(
            log: log, order: ["a"], labels: named, countFrom: nil, now: eight, zone: "Asia/Gaza")
        #expect(EffectReport.text(summary, rows: nick) == EffectReport.text(summary, rows: plain))
        #expect(!EffectReport.text(summary, rows: nick).contains("Work"))
        let confirmation = Confirmation.text(for: .runAll(allowSlotOverlap: false), enabledAccounts: 1, pilots: 1)
        #expect(!confirmation.contains("Work"))
    }

    @Test func namesStoreRoundTripsPrivately() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = AccountNamesStore(directory: folder)
        #expect(names.load() == AccountNames())
        #expect(names.save(AccountNames(names: ["a": "Work"])))
        #expect(names.load().nickname(for: "a") == "Work")
        let reviewed = ReviewedSendsStore(directory: folder)
        #expect(reviewed.save(ReviewedSends(times: [3, 1])))
        #expect(reviewed.load().times == [1, 3])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["account-names.json", "reviewed-sends.json"])
    }

    // MARK: - F4

    @Test func reconnectCommandIsExact() throws {
        let status = try self.status { $0["engineBuild"] = "sha256:abc" }
        let command = ReconnectCard.command(
            executable: "/Applications/Warm-up.app/Contents/MacOS/WarmupMenu", status: status)
        #expect(
            command
                == "'/Applications/Warm-up.app/Contents/MacOS/WarmupMenu' --provision-binding --node "
                + "'/opt/homebrew/opt/node@22/bin/node' --script '<repo>/warmup.mjs' --expect-build 'sha256:abc'")
        let quoted = ReconnectCard.command(executable: "/tmp/My App's/WarmupMenu", status: status)
        #expect(quoted?.hasPrefix("'/tmp/My App'\\''s/WarmupMenu' --provision-binding") == true)
    }

    @Test func reconnectCommandNeedsPathsAndBuild() throws {
        #expect(ReconnectCard.command(executable: "/x", status: try self.status()) == nil)
        let noEngine = try self.status {
            $0["engineBuild"] = "sha256:abc"
            $0["engine"] = NSNull()
        }
        #expect(ReconnectCard.command(executable: "/x", status: noEngine) == nil)
    }

    @Test func reconnectCardShownOnlyForMismatch() {
        #expect(!ReconnectCard.shown(issue: nil))
        #expect(!ReconnectCard.shown(issue: .missing))
        #expect(!ReconnectCard.shown(issue: .corrupt))
        #expect(!ReconnectCard.shown(issue: .unsafeFile("binding file")))
        #expect(ReconnectCard.shown(issue: .engineMismatch("engine build")))
    }

    // MARK: - F8

    static func unresolved(_ at: Int) -> UnresolvedReservation {
        UnresolvedReservation(enrollmentId: "enr_01", slot: "2026-11-12T13:00", at: at)
    }

    @Test func reviewedRowsAreHiddenAndNewerOnesShow() {
        let old = [Self.unresolved(1), Self.unresolved(2)]
        let reviewed = ReviewedSends().marking(old)
        let rows = old + [Self.unresolved(3)]
        #expect(reviewed.visible(rows).map(\.at) == [3])
        #expect(reviewed.reviewed(rows).map(\.at) == [1, 2])
    }

    @Test func markingIsPureAndCapped() {
        let empty = ReviewedSends()
        let marked = empty.marking([Self.unresolved(5)])
        #expect(empty.times.isEmpty)
        #expect(marked.times == [5])
        let many = empty.marking((0..<2_100).map { Self.unresolved($0) })
        #expect(many.times.count == 2_000)
        #expect(many.times.first == 100)
    }
}
