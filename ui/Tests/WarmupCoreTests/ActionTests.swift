import Foundation
import Testing
@testable import WarmupCore

/// A6 operator actions: reports built from real engine replies (fixtures proven by the Node
/// suite), confirmation wording, and the reconcile gate after an unknown outcome.
@Suite struct ActionReports {
    func reply<P: Decodable>(_ name: String, _ type: P.Type, exit: Int32, command: EngineCommand) throws -> (Envelope, P) {
        let output = try Fixture.output(name, exit: exit)
        let envelope = try ReplyValidator.envelope(from: output, command: command, expectedInstallation: "install_ui_fixture_01").get()
        return (envelope, try #require(ReplyValidator.payload(type, from: output)))
    }

    @Test func manualRunReportSeparatesSentConfirmedAndWindowEffect() throws {
        let action = WarmupAction.runAll(allowSlotOverlap: false)
        let (envelope, run) = try self.reply("mutation-run-success", RunReply.self, exit: 0, command: action.command)
        let report = OperationReporter.run(action, envelope: envelope, reply: run)
        #expect(report.kind == .completed)
        #expect(report.headline == "All 2 accounts confirmed.")
        #expect(report.details.isEmpty, "accounts are listed only when one did not succeed")
        #expect(action.confirmLabel == "Warm Up")
        #expect(report.overlap == nil)
    }

    /// 0.6.3: a result names its own account (by enrollment ID), never its place in the reply, and a
    /// confirmation without a shown name never falls back to a raw ID.
    @Test func resultsAndConfirmationsUseOnScreenNames() throws {
        let action = WarmupAction.runAccount(enrollmentId: "enr_b", allowSlotOverlap: false)
        let (envelope, _) = try self.reply(
            "mutation-run-success", RunReply.self, exit: 0,
            command: WarmupAction.runAll(allowSlotOverlap: false).command)
        let uncertain = AccountResult(
            enrollmentId: "enr_b", outcome: "uncertain", reason: "timeout", dispatched: nil, at: nil)
        let reply = RunReply(selected: 1, attempted: 1, results: [uncertain], overlap: nil)
        let labels = ["enr_a": "Account 1", "enr_b": "Account 2"]
        let named = OperationReporter.run(action, envelope: envelope, reply: reply, labels: labels)
        #expect(named.details.first?.hasPrefix("Account 2: may have been sent") == true)
        let unnamed = OperationReporter.run(action, envelope: envelope, reply: reply)
        #expect(unnamed.details.first?.hasPrefix("An account: may have been sent") == true)
        let run = Confirmation.text(for: action, enabledAccounts: 2, pilots: 2)
        #expect(!run.contains("enr_b"))
        #expect(run.hasPrefix("Sends one warm-up request to this account."))
        let enroll = Confirmation.text(for: .enroll(routerAccountId: "router_secret"), enabledAccounts: 0, pilots: 0)
        #expect(!enroll.contains("router_secret"))
        #expect(enroll.hasPrefix("Adds this Router account to Warm-up."))
        #expect(
            Confirmation.text(for: .enroll(routerAccountId: "r"), enabledAccounts: 0, pilots: 0, account: "router_a")
                .hasPrefix("Adds Router account router_a to Warm-up."))
    }

    @Test func overlapRefusalOffersAnExplicitOverrideAndSendsNothing() throws {
        let action = WarmupAction.runAll(allowSlotOverlap: false)
        let (envelope, run) = try self.reply("mutation-run-overlap", RunReply.self, exit: 3, command: action.command)
        let report = OperationReporter.run(action, envelope: envelope, reply: run)
        #expect(report.kind == .overlap)
        #expect(run.attempted == 0)
        #expect(report.overlap?.slot == "2026-11-13T08:00")
        #expect(report.details.contains("Running now could overlap that warm-up. Nothing was sent."))
        // An override without an admission instant is refused: it is never sent unscoped.
        #expect(throws: CommandError.self) {
            try WarmupAction.runAll(allowSlotOverlap: true).command.arguments(installationId: "install_ui_fixture_01")
        }
    }

    @Test func overrideIsOnlyExpressibleWithAnInstant() throws {
        let id = "install_ui_fixture_01"
        let at = 1_763_013_600_000
        for bare in [
            WarmupAction.runAll(allowSlotOverlap: true), .runAccount(enrollmentId: "enr_01", allowSlotOverlap: true),
        ] {
            #expect(throws: CommandError.self) { try bare.command.arguments(installationId: id) }
        }
        let scoped = try WarmupAction.runAccount(enrollmentId: "enr_01", allowSlotOverlap: true, overlapAt: at)
            .command.arguments(installationId: id)
        #expect(scoped.contains("--allow-slot-overlap"))
        #expect(scoped.contains("--overlap-at"))
    }

    @Test func scheduleChangesConflictsAndEnrollment() throws {
        let proposal = try #require(ReplyValidator.payload(ProposalReply.self, from: try Fixture.output("proposal-workweek-saved-shape"))).proposal
        #expect(proposal.weekdays == [1, 2, 3, 4, 5])
        let save = WarmupAction.saveEdit(.weekdays([1, 2, 3, 4, 5]), expectedRevision: proposal.expectedRevision, expectedLocalDate: proposal.localDate)
        #expect(try save.command.arguments(installationId: "install_ui_fixture_01") == [
            "schedule", "weekdays", "1,2,3,4,5", "--expected-revision", "3", "--expected-local-date", "2026-11-12", "--expected-installation-id", "install_ui_fixture_01"])
        let (saved, change) = try self.reply("mutation-edit-saved", ScheduleChangeReply.self, exit: 0, command: save.command)
        let savedReport = OperationReporter.change(save, envelope: saved, reply: change)
        #expect(savedReport.kind == .completed)
        #expect(savedReport.headline == "Schedule saved.")
        #expect(savedReport.details == ["It starts tomorrow; today's times stay as they were."])
        let saveText = Confirmation.text(for: save, enabledAccounts: 1, pilots: 1)
        #expect(saveText.hasPrefix("Runs on Mon, Tue, Wed, Thu, Fri, from tomorrow."))
        let add = ScheduleEdit.add(time: "21:05", today: false)
        #expect(add.summary == "Adds 21:05 every day, from tomorrow.")
        let move = ScheduleEdit.move(from: "13:00", to: "14:00", today: true)
        #expect(move.summary == "Moves 13:00 to 14:00 today only.")
        let (stale, staleChange) = try self.reply("mutation-edit-date-changed", ScheduleChangeReply.self, exit: 2, command: save.command)
        let staleReport = OperationReporter.change(save, envelope: stale, reply: staleChange)
        #expect(staleReport.kind == .conflict)
        #expect(staleReport.details == ["Nothing was saved. Refresh and preview again before confirming."])
        let enroll = WarmupAction.enroll(routerAccountId: "router_a")
        let (enrolled, enrollReply) = try self.reply("mutation-enroll-already", EnrollReply.self, exit: 0, command: enroll.command)
        #expect(OperationReporter.change(enroll, envelope: enrolled, reply: nil, enrolled: enrollReply).details == ["This account was already enrolled."])
        for (name, action) in [("mutation-pause", WarmupAction.pause(expectedRevision: 4)), ("mutation-resume", .resume(expectedRevision: 2))] {
            let (envelope, reply) = try self.reply(name, ScheduleChangeReply.self, exit: 0, command: action.command)
            #expect(OperationReporter.change(action, envelope: envelope, reply: reply).kind == .completed)
        }
    }

    @Test func confirmationsStateUsageAndNoCatchUp() {
        #expect(Confirmation.text(for: .runAll(allowSlotOverlap: false), enabledAccounts: 2, pilots: 2).contains("counts toward that account's usage"))
        #expect(Confirmation.text(for: .runAll(allowSlotOverlap: false), enabledAccounts: 2, pilots: 2).contains("(2 at the last check)"))
        #expect(!Confirmation.text(for: .runAll(allowSlotOverlap: false), enabledAccounts: 2, pilots: 2).contains("overrides"))
        #expect(Confirmation.text(for: .runAll(allowSlotOverlap: true), enabledAccounts: 2, pilots: 2).contains("scheduled warm-up that is due may be skipped"))
        #expect(Confirmation.text(for: .runAccount(enrollmentId: "enr_01", allowSlotOverlap: true), enabledAccounts: 2, pilots: 2, account: "router_a")
            .hasPrefix("Sends one warm-up request to router_a."))
        #expect(Confirmation.text(for: .resume(expectedRevision: 1), enabledAccounts: 2, pilots: 1).contains("without catching up"))
        #expect(Confirmation.text(for: .enroll(routerAccountId: "r"), enabledAccounts: 0, pilots: 0).contains("Nothing is sent"))
        #expect(WarmupAction.runAccount(enrollmentId: "enr_01", allowSlotOverlap: false).sendsRequests)
        #expect(!WarmupAction.pause(expectedRevision: 1).sendsRequests)
    }
}

@Suite(.serialized) struct ReconcileGate {
    @Test func unknownOutcomeBlocksFurtherChangesUntilAFreshStatus() async throws {
        let engine = try FakeEngine()
        let client = await engine.client()
        engine.mode("lostmutation")
        #expect(await client.mutate(.runAll(allowSlotOverlap: false), as: RunReply.self).failureIssue == .mutationOutcomeUnknown)
        #expect(await client.reconcileRequired)
        engine.mode("slowmutation")
        let before = engine.calls.count
        #expect(await client.mutate(.runAll(allowSlotOverlap: false), as: RunReply.self).failureIssue == .reconcileRequired)
        #expect(engine.calls.count == before, "refused without starting the engine")
        engine.mode("otherinstall")
        _ = await client.read(.status, as: EngineStatus.self)
        #expect(await client.reconcileRequired, "an invalid status does not reconcile")
        engine.mode("status")
        #expect(await client.read(.status, as: EngineStatus.self).failureIssue == nil)
        #expect(await !client.reconcileRequired)
        engine.mode("slowmutation")
        let run = try await client.mutate(.runAll(allowSlotOverlap: false), as: RunReply.self).get()
        #expect(run.payload?.attempted == 1)
    }

    @Test(arguments: ["runnofields", "enrollnofields", "schednofields"]) func acceptedEnvelopeWithoutResultFieldsIsUnknown(_ mode: String) async throws {
        let engine = try FakeEngine()
        let client = await engine.client()
        engine.mode(mode)
        let issue: ClientIssue? = switch mode {
        case "runnofields": await client.mutate(.runAll(allowSlotOverlap: false), as: RunReply.self).failureIssue
        case "enrollnofields": await client.mutate(.enroll(routerAccountId: "router_a"), as: EnrollReply.self).failureIssue
        default: await client.mutate(.scheduleEnable(expectedRevision: 1), as: ScheduleChangeReply.self).failureIssue
        }
        #expect(issue == .mutationOutcomeUnknown)
        #expect(await client.reconcileRequired)
    }

    @Test func refusalWithoutResultFieldsIsAReportNotAnUnknown() async throws {
        let engine = try FakeEngine()
        let client = await engine.client()
        engine.mode("schedrefused")
        let reply = try await client.mutate(.scheduleEnable(expectedRevision: 1), as: ScheduleChangeReply.self).get()
        #expect(reply.envelope.reason == "schedule_revision_conflict")
        #expect(await !client.reconcileRequired)
    }

    @Test func statusReadStartedBeforeAnUnknownOutcomeDoesNotReconcileIt() async throws {
        let engine = try FakeEngine()
        let client = await engine.client()
        engine.mode("slowstatus")
        async let early = client.read(.status, as: EngineStatus.self) // sleeps 1 s inside the child
        try await Task.sleep(for: .milliseconds(300))
        engine.mode("lostmutation")
        #expect(await client.mutate(.runAll(allowSlotOverlap: false), as: RunReply.self).failureIssue == .mutationOutcomeUnknown)
        #expect((await early).failureIssue == nil, "the early read itself is valid")
        #expect(await client.reconcileRequired, "but it began before the unknown outcome, so it cannot reconcile it")
        engine.mode("status")
        _ = await client.read(.status, as: EngineStatus.self)
        #expect(await !client.reconcileRequired)
    }
}
