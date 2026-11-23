import Foundation
import Testing
@testable import WarmupCore

/// Decodes the fixtures the Node suite proves equal to real engine output
/// (test/ui-fixtures.test.mjs), so the app and engine contracts cannot drift silently.
enum Fixture {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("test/fixtures/ui", isDirectory: true)

    static func data(_ name: String) throws -> Data { try Data(contentsOf: self.directory.appendingPathComponent("\(name).json")) }

    static func output(_ name: String, exit: Int32 = 0, edit: ((inout [String: Any]) -> Void)? = nil) throws -> ProcessOutput {
        var data = try self.data(name)
        if let edit {
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            edit(&object)
            data = try JSONSerialization.data(withJSONObject: object)
        } else {
            data = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data))
        }
        return ProcessOutput(stdout: data + Data([0x0A]), stderr: Data(), exitCode: exit, stdoutOverflow: false, stderrOverflow: false, timedOut: false, terminatedBySignal: false)
    }
}

@Suite struct FixtureDecoding {
    @Test(arguments: ["status-enabled", "status-paused"]) func statusDecodes(_ name: String) throws {
        let output = try Fixture.output(name)
        let envelope = try ReplyValidator.envelope(from: output, command: .status, expectedInstallation: "install_ui_fixture_01").get()
        #expect(envelope.outcome == "ready")
        let status = try #require(ReplyValidator.payload(EngineStatus.self, from: output))
        #expect(status.capability?.version == 1)
        #expect(status.capability?.features.contains("slot_explanation") == true)
        #expect(status.engine?.scriptPath == "<repo>/warmup.mjs")
    }

    @Test func projectionDecodes() throws {
        let projection = try #require(ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        #expect(projection.days.count == 7)
        #expect(projection.days.allSatisfy { $0.admissions.map(\.admission) == ["08:00", "13:00", "18:00"] })
        #expect(projection.days[0].admissions.first?.next == true)
        let proposal = try JSONSerialization.jsonObject(with: try Fixture.data("projection-proposal-workweek")) as? [String: Any]
        let proposed = try JSONSerialization.data(withJSONObject: try #require(proposal?["proposal"]))
        let workweek = try JSONDecoder().decode(ScheduleProjection.self, from: proposed)
        #expect(workweek.days.map(\.exclusion) == [nil, nil, "weekday", "weekday", nil, nil, nil])
        #expect(workweek.weekdays == [1, 2, 3, 4, 5])
    }

    @Test func slotExplanationsDecode() throws {
        let admitted = try #require(ReplyValidator.payload(SlotExplanationResult.self, from: try Fixture.output("slot-admitted")))
        #expect(admitted.explanation.verdict == "admitted")
        #expect(admitted.explanation.accounts.allSatisfy { $0.dispatch == "confirmed" && $0.response == "confirmed" && $0.windowEffect == "unverified" })
        let uncertain = try #require(ReplyValidator.payload(SlotExplanationResult.self, from: try Fixture.output("slot-uncertain")))
        #expect(uncertain.explanation.accounts.allSatisfy { $0.dispatch == "unknown" && $0.reservationUnresolved })
        let unobserved = try #require(ReplyValidator.payload(SlotExplanationResult.self, from: try Fixture.output("slot-unobserved")))
        #expect(unobserved.explanation.verdict == "unobserved")
        #expect(unobserved.explanation.heartbeat.observedAfterAdmission == false)
        let missed = try #require(ReplyValidator.payload(SlotExplanationResult.self, from: try Fixture.output("slot-no-tick")))
        #expect(missed.explanation.notAdmitted?.cause == "no_tick_between")
    }

    @Test func listAndHistoryDecode() throws {
        let list = try #require(ReplyValidator.payload(AccountList.self, from: try Fixture.output("list")))
        #expect(list.rows.map(\.routerAccountId) == ["router_a", "router_b"])
        let history = try #require(ReplyValidator.payload(HistoryReport.self, from: try Fixture.output("history")))
        #expect(history.rows.contains { $0.status == "uncertain" && $0.slot == "2026-11-12T13:00" })
    }

    @Test func blockedReplyNeedsMatchingExit() throws {
        let conflict = try Fixture.output("revision-conflict", exit: 2)
        let envelope = try ReplyValidator.envelope(from: conflict, command: .scheduleEdit(.add(time: "20:30", today: false), expectedRevision: 0, expectedLocalDate: "2026-11-12"), expectedInstallation: "install_ui_fixture_01").get()
        #expect(envelope.reason == "schedule_revision_conflict")
        #expect(ReplyValidator.envelope(from: try Fixture.output("revision-conflict", exit: 0), command: .scheduleEnable(expectedRevision: 0), expectedInstallation: nil) == .failure(.exitOutcomeMismatch))
    }
}

@Suite struct ReplyValidation {
    func raw(_ text: String, exit: Int32 = 0, overflow: Bool = false, timedOut: Bool = false) -> ProcessOutput {
        ProcessOutput(stdout: Data(text.utf8), stderr: Data(), exitCode: exit, stdoutOverflow: overflow, stderrOverflow: false, timedOut: timedOut, terminatedBySignal: false)
    }

    @Test func rejectsMalformedAndMismatchedReplies() throws {
        let ok = #"{"protocolVersion":1,"command":"status","outcome":"ready","reason":"status","installationId":"install_ui_fixture_01","observedAt":"x"}"#
        #expect((try? ReplyValidator.envelope(from: self.raw(ok), command: .status, expectedInstallation: "install_ui_fixture_01").get()) != nil)
        #expect(ReplyValidator.envelope(from: self.raw(""), command: .status, expectedInstallation: nil) == .failure(.malformedOutput))
        #expect(ReplyValidator.envelope(from: self.raw("[1]"), command: .status, expectedInstallation: nil) == .failure(.malformedOutput))
        #expect(ReplyValidator.envelope(from: self.raw(ok + "\n" + ok), command: .status, expectedInstallation: nil) == .failure(.malformedOutput))
        #expect(ReplyValidator.envelope(from: self.raw("not json"), command: .status, expectedInstallation: nil) == .failure(.malformedOutput))
        #expect(ReplyValidator.envelope(from: self.raw(ok.replacingOccurrences(of: "\"protocolVersion\":1", with: "\"protocolVersion\":2")), command: .status, expectedInstallation: nil) == .failure(.protocolMismatch))
        #expect(ReplyValidator.envelope(from: self.raw(ok), command: .list, expectedInstallation: nil) == .failure(.commandMismatch))
        #expect(ReplyValidator.envelope(from: self.raw(ok, exit: 2), command: .status, expectedInstallation: nil) == .failure(.exitOutcomeMismatch))
        #expect(ReplyValidator.envelope(from: self.raw(ok, exit: 9), command: .status, expectedInstallation: nil) == .failure(.exitOutcomeMismatch))
        #expect(ReplyValidator.envelope(from: self.raw(ok), command: .status, expectedInstallation: "install_other_000001") == .failure(.installationMismatch))
        #expect(ReplyValidator.envelope(from: self.raw(ok, overflow: true), command: .status, expectedInstallation: nil) == .failure(.outputTooLarge))
        #expect(ReplyValidator.envelope(from: self.raw(ok, timedOut: true), command: .status, expectedInstallation: nil) == .failure(.timedOut))
    }
}

@Suite struct CommandAllowlist {
    let id = "install_ui_fixture_01"

    @Test func readOnlyArgumentsCarryNoGuards() throws {
        #expect(try EngineCommand.status.arguments(installationId: nil) == ["status"])
        #expect(try EngineCommand.scheduleInspectSlot("2026-11-12T08:00").arguments(installationId: nil) == ["schedule", "inspect", "--slot", "2026-11-12T08:00"])
        #expect(try EngineCommand.scheduleInspectProposal(.weekdays([5, 1, 3])).arguments(installationId: nil) == ["schedule", "inspect", "weekdays", "1,3,5"])
        #expect(try EngineCommand.history(account: "enr_01", since: "2026-11-12T00:00:00Z").arguments(installationId: nil) == ["history", "--account", "enr_01", "--since", "2026-11-12T00:00:00Z"])
    }

    @Test func mutationsAlwaysCarryInstallationAndRevisionGuards() throws {
        #expect(try EngineCommand.runAll(allowSlotOverlap: false).arguments(installationId: self.id) == ["run", "--expected-installation-id", self.id])
        #expect(try EngineCommand.scheduleDisable(expectedRevision: 4).arguments(installationId: self.id) == ["schedule", "disable", "--expected-revision", "4", "--expected-installation-id", self.id])
        #expect(try EngineCommand.scheduleEdit(.move(from: "08:00", to: "09:15", today: true), expectedRevision: 2, expectedLocalDate: "2026-11-12").arguments(installationId: self.id)
            == ["schedule", "move", "08:00", "09:15", "--today", "--expected-revision", "2", "--expected-local-date", "2026-11-12", "--expected-installation-id", self.id])
        #expect(throws: CommandError.self) { try EngineCommand.runAll(allowSlotOverlap: false).arguments(installationId: nil) }
    }

    @Test(arguments: [
        EngineCommand.runAccount(enrollmentId: "enr_01; rm -rf /", allowSlotOverlap: false),
        .runAccount(enrollmentId: "--now", allowSlotOverlap: false),
        .enroll(routerAccountId: ""),
        .history(account: "../x", since: nil),
        .history(account: nil, since: "yesterday"),
        .scheduleInspectSlot("2026-11-12T24:00"),
        .scheduleInspectProposal(.add(time: "8:00", today: false)),
        .scheduleInspectProposal(.weekdays([])),
        .scheduleInspectProposal(.weekdays([0, 1])),
        .scheduleInspectProposal(.weekdays([1, 1])),
        .scheduleEdit(.add(time: "09:00", today: false), expectedRevision: -1, expectedLocalDate: "2026-11-12"),
        .scheduleEdit(.add(time: "09:00", today: false), expectedRevision: 1, expectedLocalDate: "12/11/2026"),
    ]) func adversarialArgumentsFailWithoutSpawning(_ command: EngineCommand) {
        #expect(throws: CommandError.self) { try command.arguments(installationId: "install_ui_fixture_01") }
    }

    @Test func featuresGateCommands() {
        #expect(EngineCommand.status.requiredFeatures.isEmpty)
        #expect(EngineCommand.scheduleInspectProposal(.weekdays([1])).requiredFeatures.contains("schedule_weekdays"))
        #expect(EngineCommand.scheduleEdit(.add(time: "09:00", today: false), expectedRevision: 1, expectedLocalDate: "2026-11-12").requiredFeatures.contains("expected_local_date"))
    }
}

@Suite struct GlanceAndDiagnostics {
    func status(_ name: String, edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output(name, edit: edit)))
    }

    @Test func scheduledAndPausedStates() throws {
        let base = try self.status("status-enabled")
        let enabled = GlanceBuilder.make(status: base, today: "2026-11-12", macZone: "Asia/Gaza")
        #expect(enabled.state == .scheduled)
        #expect(enabled.headline == "All good · next 08:00")
        // The zone is named only when it is not the Mac's own.
        let away = GlanceBuilder.make(status: base, today: "2026-11-12", macZone: "Europe/London")
        #expect(away.headline == "All good · next 08:00 (Asia/Gaza)")
        let eve = GlanceBuilder.make(status: base, today: "2026-11-11", macZone: "Asia/Gaza")
        #expect(eve.headline == "All good · next 08:00 tomorrow")
        #expect(enabled.lastOutcome == nil)
        let paused = GlanceBuilder.make(status: try self.status("status-paused"), today: "2026-11-12")
        #expect(paused.state == .paused)
        #expect(paused.lastOutcome == "18:00 today: missed (nothing ran at that minute)")
        // 0.5.1 (X1): possible sends live in Needs attention and the menu, never in the hero notes.
        #expect(!paused.notes.contains { $0.contains("possible send") })
        let single = try self.status("status-paused") {
            $0["unresolved"] = [($0["unresolved"] as? [Any])?.first].compactMap { $0 }
        }
        let one = GlanceBuilder.make(status: single, today: "2026-11-12")
        #expect(!one.notes.contains { $0.contains("possible send") })
        #expect(!paused.notes.contains { $0.contains("send(s)") })
    }

    @Test func blockedHeldUnloadedAndNoUpcomingStates() throws {
        #expect(GlanceBuilder.make(status: try self.status("status-enabled") { $0["compatibility"] = "blocked" }, today: nil).state == .blocked)
        #expect(GlanceBuilder.make(status: try self.status("status-enabled") { $0["clockHold"] = ["lastWall": 1, "highWater": NSNull()] }, today: nil).state == .attention)
        #expect(GlanceBuilder.make(status: try self.status("status-enabled") { $0["job"] = "absent" }, today: nil).state == .attention)
        let none = GlanceBuilder.make(status: try self.status("status-enabled") { $0["next"] = NSNull() }, today: nil)
        #expect(none.state == .noUpcoming)
        #expect(Set([GlanceState.blocked, .attention, .paused, .running, .noUpcoming, .scheduled, .setupRequired, .checking, .unavailable].map(\.symbolName)).count == 9)
        #expect(GlanceBuilder.notChecked().state == .checking)
        #expect(GlanceBuilder.notChecked().headline == "Checking…")
    }

    @Test func diagnosticIsRedacted() throws {
        let result = try #require(ReplyValidator.payload(SlotExplanationResult.self, from: try Fixture.output("slot-uncertain")))
        let text = SlotDiagnostic.text(result, engineVersion: "1.0.0-offline")
        #expect(text.contains("dispatch=unknown response=uncertain"))
        #expect(text.contains("Usage window effect: unverified"))
        #expect(!text.contains("install_"))
        #expect(!text.contains("enr_"))
        #expect(!text.contains("res_"))
        #expect(!text.lowercased().contains("sleep"))
    }
}
