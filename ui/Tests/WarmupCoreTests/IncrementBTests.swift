import Foundation
import Testing

@testable import WarmupCore

/// Increment B (engine 1.2): vacations, scheduled accounts, one undo and daily caps.
@Suite struct IncrementB {
    let id = "install_ui_fixture_01"

    @Test func settingsBuildExactEngineArguments() throws {
        func args(_ setting: ScheduleSetting, date: String? = nil) throws -> [String] {
            try EngineCommand.scheduleSetting(setting, expectedRevision: 7, expectedLocalDate: date).arguments(
                installationId: self.id)
        }
        let tail = ["--expected-revision", "7"]
        let guardId = ["--expected-installation-id", self.id]
        #expect(
            try args(.exclude(start: "2026-11-20", end: "2026-11-22"), date: "2026-11-12")
                == ["schedule", "exclude", "2026-11-20", "2026-11-22"] + tail + ["--expected-local-date", "2026-11-12"]
                + guardId)
        #expect(
            try args(.include(start: "2026-11-20", end: "2026-11-22")) == [
                "schedule", "include", "2026-11-20", "2026-11-22",
            ] + tail + guardId)
        #expect(try args(.accounts(nil)) == ["schedule", "accounts", "all"] + tail + guardId)
        #expect(
            try args(.accounts(["enr_b", "enr_a"])) == ["schedule", "accounts", "--only", "enr_a", "enr_b"] + tail
                + guardId)
        #expect(try args(.accounts([])) == ["schedule", "accounts", "--only"] + tail + guardId)
        #expect(
            try args(.undo, date: "2026-11-12") == ["schedule", "undo"] + tail + [
                "--expected-local-date", "2026-11-12",
            ] + guardId)
        #expect(try args(.cap(enrollmentId: "enr_a", count: 3)) == ["schedule", "cap", "enr_a", "3"] + tail + guardId)
        #expect(
            try args(.cap(enrollmentId: "enr_a", count: nil)) == ["schedule", "cap", "enr_a", "off"] + tail + guardId)
    }

    @Test func settingsRefuseLooseInputLocally() {
        for (setting, date) in [
            (ScheduleSetting.exclude(start: "2026-11-22", end: "2026-11-20"), nil as String?),
            (.exclude(start: "20-11-2026", end: "2026-11-22"), nil),
            (.accounts(["enr_a", "enr_a"]), nil),
            (.accounts(["--now"]), nil),
            (.cap(enrollmentId: "enr_a", count: 0), nil),
            (.cap(enrollmentId: "enr_a", count: 49), nil),
            (.cap(enrollmentId: "enr_a", count: 2), "2026-11-12"),  // caps carry no date guard
        ] {
            #expect(throws: CommandError.self) {
                try EngineCommand.scheduleSetting(setting, expectedRevision: 1, expectedLocalDate: date)
                    .arguments(installationId: self.id)
            }
        }
    }

    @Test func settingsNeedTheirEngineFeature() {
        let vacation = EngineCommand.scheduleSetting(
            .exclude(start: "2026-11-20", end: "2026-11-20"), expectedRevision: 1, expectedLocalDate: "2026-11-12")
        #expect(vacation.requiredFeatures.contains("schedule_vacations"))
        #expect(vacation.requiredFeatures.contains("expected_local_date"))
        #expect(
            EngineCommand.scheduleSetting(.accounts(nil), expectedRevision: 1, expectedLocalDate: nil).requiredFeatures
                .contains("scheduled_accounts"))
        #expect(
            EngineCommand.scheduleSetting(.undo, expectedRevision: 1, expectedLocalDate: "2026-11-12").requiredFeatures
                .contains("schedule_undo"))
        #expect(
            EngineCommand.scheduleSetting(
                .cap(enrollmentId: "enr_a", count: 1), expectedRevision: 1, expectedLocalDate: nil
            ).requiredFeatures.contains("daily_caps"))
        #expect(WarmupAction.setting(.undo, expectedRevision: 1, expectedLocalDate: nil).sendsRequests == false)
    }

    @Test func confirmationsSayWhatChangesAndWhatDoesNot() {
        func text(_ setting: ScheduleSetting, account: String? = nil) -> String {
            Confirmation.text(
                for: .setting(setting, expectedRevision: 1, expectedLocalDate: nil), enabledAccounts: 2, pilots: 2,
                account: account)
        }
        #expect(text(.exclude(start: "2026-11-20", end: "2026-11-22")).contains("both days included"))
        #expect(text(.accounts([])).contains("Manual warm-ups still reach every enabled account"))
        #expect(
            text(.cap(enrollmentId: "enr_a", count: 1), account: "router_0").contains(
                "At most 1 scheduled warm-up a day for router_0"))
        #expect(text(.undo).contains("refused if an affected time has passed"))
        #expect(
            WarmupAction.setting(.include(start: "a", end: "b"), expectedRevision: 1, expectedLocalDate: nil).title
                == "Remove time off")
    }

    @Test func engineOneTwoStatusDecodes() throws {
        let status = try #require(
            ReplyValidator.payload(
                EngineStatus.self,
                from: try Fixture.output("status-enabled") {
                    $0["scheduledAccounts"] = ["enr_a"]
                    $0["caps"] = ["enr_a": 2]
                    $0["undoAvailable"] = true
                    var schedule = $0["schedule"] as? [String: Any] ?? [:]
                    schedule["vacations"] = [["start": "2026-11-20", "end": "2026-11-22"]]
                    $0["schedule"] = schedule
                }))
        #expect(status.scheduledAccounts == ["enr_a"])
        #expect(status.caps == ["enr_a": 2])
        #expect(status.undoAvailable == true)
        #expect(status.schedule.vacations == [VacationRange(start: "2026-11-20", end: "2026-11-22")])
        let plain = try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled")))
        #expect(plain.scheduledAccounts == nil)
        #expect(plain.caps == [:])
        #expect(plain.undoAvailable == false)
    }

    @Test func accountChangesAreAppliedByTheEngine() throws {
        func args(_ setting: ScheduleSetting) throws -> [String] {
            try EngineCommand.scheduleSetting(setting, expectedRevision: 7, expectedLocalDate: nil).arguments(
                installationId: self.id)
        }
        #expect(try args(.addAccount("enr_a")).prefix(4) == ["schedule", "accounts", "--add", "enr_a"])
        #expect(try args(.removeAccount("enr_a")).prefix(4) == ["schedule", "accounts", "--remove", "enr_a"])
        #expect(throws: CommandError.self) { try args(.removeAccount("--now")) }
    }

    @Test func aDailyCapSkipIsNotAProblem() throws {
        func status(_ results: [[String: Any]], outcome: String) throws -> EngineStatus {
            try #require(
                ReplyValidator.payload(
                    EngineStatus.self,
                    from: try Fixture.output("status-enabled") {
                        $0["lastSlotOutcome"] = [
                            "slot": "2026-11-12T13:00", "zone": "Asia/Gaza", "outcome": outcome,
                            "at": 1_794_481_200_000,
                            "results": results,
                        ]
                        $0["slotLedger"] = []
                        $0["activeBatch"] = NSNull()
                    }))
        }
        let capped: [String: Any] = [
            "enrollmentId": "enr_a", "outcome": "blocked", "reason": "daily_cap_reached", "dispatched": false,
            "skipped": true,
        ]
        let failed: [String: Any] = [
            "enrollmentId": "enr_b", "outcome": "blocked", "reason": "protocol_failure", "dispatched": true,
        ]
        #expect(SlotProblem.from(try status([capped], outcome: "partial")).isEmpty)
        #expect(SlotProblem.from(try status([capped, failed], outcome: "partial")).count == 1)
        // A batch the engine stopped is reported even when its only rows are cap skips.
        #expect(SlotProblem.from(try status([capped], outcome: "blocked")).count == 1)
        let rows = [
            HistoryEntry(
                enrollmentId: "enr_a", status: "skipped", reason: "daily_cap_reached", mode: "scheduled",
                slot: "2026-11-12T08:00", at: 1, dispatched: false)
        ]
        #expect(SlotProblem.fromHistory(rows).isEmpty)
        let week = WeekSummary.make(
            today: "2026-11-12", status: try status([capped], outcome: "partial"), history: rows)
        #expect(week.last?.slots.allSatisfy { $0.mark == .skipped } == true)
        // Engine 1.2 history carries the batch outcome: a stopped batch stays a problem in catch-up.
        var stopped = rows
        stopped[0].batchOutcome = "blocked"
        #expect(SlotProblem.fromHistory(stopped).count == 1)
        #expect(WeekSummary.mark(stopped) == .problem)
        let decoded = try JSONDecoder().decode(
            HistoryEntry.self, from: Data(#"{"status":"skipped","batchOutcome":"blocked"}"#.utf8))
        #expect(decoded.batchOutcome == "blocked")
        #expect(SlotProblem.operatorChosenCauses.contains("no_scheduled_accounts"))
    }

    @Test func aStoppedBatchWithNoSavedRowsStaysVisible() throws {
        let status = try #require(
            ReplyValidator.payload(
                EngineStatus.self,
                from: try Fixture.output("status-enabled") {
                    $0["lastSlotOutcome"] = [
                        "slot": "2026-11-12T13:00", "zone": "Asia/Gaza", "outcome": "success",
                        "at": 1_794_481_200_000, "results": [],
                    ]
                    $0["slotLedger"] = []
                    $0["activeBatch"] = NSNull()
                    $0["blockedSlots"] = [["slot": "2026-11-12T08:00", "at": 1_794_463_210_000]]
                }))
        let problems = SlotProblem.from(status)
        #expect(problems.map(\.slot) == ["2026-11-12T08:00"])
        #expect(problems.first?.kind == .stopped)
        let alert = try #require(AlertComposer.content(for: problems, zone: "Asia/Gaza"))
        #expect(alert.body.contains("unknown"))
        #expect(!alert.body.contains("0 sent"))
        let week = WeekSummary.make(today: "2026-11-12", status: status, history: [])
        #expect(week.last?.slots.first { $0.time == "08:00" }?.mark == .problem)
    }
}
