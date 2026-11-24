import Foundation
import Testing

@testable import WarmupCore

/// App 0.6.9: one resolver names every slot at the minute it ran or runs, on Overview, in the CLI and in
/// alerts, while the slot label stays the key.
@Suite struct RunTimesResolver {
    /// 14:00 on 12 Nov in Asia/Gaza, after the moved 13:00 time was missed.
    static let afternoon = 1_794_463_200_000 + 6 * 3_600_000
    static let moved = "2026-11-12T13:00"

    func status(edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    /// projection-default with `times` (logical time → admission) changed on day `day`, and `edit` after.
    func projection(
        day: Int = 0, _ times: [String: String] = ["13:00": "13:10"], edit: ((inout [String: Any]) -> Void)? = nil
    ) throws -> ScheduleProjection {
        try #require(
            ReplyValidator.payload(
                ScheduleProjection.self,
                from: try Fixture.output("projection-default") { object in
                    guard var days = object["days"] as? [[String: Any]],
                        var admissions = days[day]["admissions"] as? [[String: Any]]
                    else { return }
                    for index in admissions.indices {
                        guard let logical = admissions[index]["logicalTime"] as? String, let runs = times[logical]
                        else { continue }
                        admissions[index]["admission"] = runs
                    }
                    days[day]["admissions"] = admissions
                    object["days"] = days
                    edit?(&object)
                }))
    }

    static func ledger(_ slot: String, admission: String) -> [String: Any] {
        [
            "slot": slot, "admission": admission, "verdict": "not_admitted", "cause": "no_tick_between",
            "zone": "Asia/Gaza", "at": Self.afternoon - 3_000_000,
        ]
    }

    /// The round-3 case: 13:00 moved to 13:10 for today and missed, recorded at 13:10.
    func missedMoved() throws -> EngineStatus {
        try self.status { $0["slotLedger"] = [Self.ledger(Self.moved, admission: "13:10")] }
    }

    @Test func projectionAdmissionResolvesItsSlot() throws {
        let tomorrow = try self.projection(day: 1, ["18:00": "18:05"])
        let runs = RunTimes.make(status: try self.status(), projection: tomorrow)
        #expect(runs.time(of: "2026-11-13T18:00") == "18:05")
        #expect(runs.time(of: "2026-11-12T18:00") == "18:00")
        let today = RunTimes.make(status: try self.status(), projection: try self.projection())
        #expect(today.time(of: Self.moved) == "13:10")
        #expect(today.time(of: "2026-11-12T08:00") == "08:00")
        // An unmoved projection resolves nothing.
        let plain = RunTimes.make(status: try self.status(), projection: try self.projection([:]))
        #expect(plain == .none)
    }

    @Test func ledgerRowWinsOverTheProjection() throws {
        let projection = try self.projection()
        let recorded = try self.status { $0["slotLedger"] = [Self.ledger(Self.moved, admission: "13:05")] }
        #expect(RunTimes.make(status: recorded, projection: projection).time(of: Self.moved) == "13:05")
        // A row recorded at the configured minute keeps it, even when the projection moved it since.
        let kept = try self.status { $0["slotLedger"] = [Self.ledger(Self.moved, admission: "13:00")] }
        #expect(RunTimes.make(status: kept, projection: projection).time(of: Self.moved) == "13:00")
    }

    @Test func nonClockValuesAreIgnored() throws {
        for odd in ["13:10:00", "1310", "25:00", "١٣:١٠", "13:10 sk-live"] {
            let projected = RunTimes.make(status: try self.status(), projection: try self.projection(["13:00": odd]))
            #expect(projected.time(of: Self.moved) == "13:00")
            let recorded = try self.status { $0["slotLedger"] = [Self.ledger(Self.moved, admission: odd)] }
            #expect(RunTimes.make(status: recorded, projection: nil).time(of: Self.moved) == "13:00")
        }
    }

    @Test func projectionFromAnotherRevisionOrZoneIsIgnored() throws {
        let revised = try self.projection { $0["scheduleRevision"] = 2 }
        #expect(RunTimes.make(status: try self.status(), projection: revised) == .none)
        let elsewhere = try self.projection { $0["zone"] = "Europe/Berlin" }
        #expect(RunTimes.make(status: try self.status(), projection: elsewhere) == .none)
    }

    @Test func missingStatusOrProjectionResolvesNothing() throws {
        #expect(RunTimes.make(status: nil, projection: try self.projection()) == .none)
        #expect(RunTimes.make(status: nil, projection: nil) == .none)
        #expect(RunTimes.make(status: try self.status(), projection: nil) == .none)
    }

    @Test func timeOfFallsBackToTheLabel() {
        #expect(RunTimes.none.time(of: Self.moved) == "13:00")
        #expect(RunTimes.none.time(of: "garbage") == nil)
        #expect(RunTimes.none.time(of: "2026-11-12") == nil)
        #expect(FriendlyTime.slot("garbage", today: nil, runs: .none) == "garbage")
    }

    @Test func glanceNamesTheMinuteItRan() throws {
        let ran = try self.status {
            $0["lastSlotOutcome"] = ["slot": Self.moved, "outcome": "success", "at": 1, "results": []]
        }
        let runs = RunTimes.make(status: ran, projection: try self.projection())
        let moved = GlanceBuilder.make(status: ran, today: "2026-11-12", macZone: "Asia/Gaza", runs: runs)
        #expect(moved.lastOutcome?.hasPrefix("13:10 today") == true)
        #expect(moved.lastOutcomeSlot == Self.moved)
        let plain = GlanceBuilder.make(status: ran, today: "2026-11-12", macZone: "Asia/Gaza")
        #expect(plain.lastOutcome?.hasPrefix("13:00 today") == true)
    }

    @Test func warmingUpNamesTheMinuteItRuns() throws {
        let running = try self.status {
            $0["activeBatch"] = [
                "slot": Self.moved, "enrollmentIds": ["enr_a"], "zone": "Asia/Gaza", "state": "running",
            ]
        }
        let runs = RunTimes.make(status: running, projection: try self.projection())
        let glance = GlanceBuilder.make(status: running, today: "2026-11-12", macZone: "Asia/Gaza", runs: runs)
        #expect(glance.headline == "Warming up: 13:10")
        let plain = GlanceBuilder.make(status: running, today: "2026-11-12", macZone: "Asia/Gaza")
        #expect(plain.headline == "Warming up: 13:00")
    }

    @Test func needsALookNamesTheMinuteItWasDue() throws {
        let missed = try self.missedMoved()
        let runs = RunTimes.make(status: missed, projection: try self.projection())
        let glance = GlanceBuilder.make(status: missed, today: "2026-11-12", macZone: "Asia/Gaza", runs: runs)
        #expect(glance.headline == "Needs a look: 13:10 today")
        #expect(glance.lastOutcome == "13:10 today: missed (nothing ran at that minute)")
        // The label stays the key for the click and the acknowledgement.
        #expect(glance.unseenProblemSlot == Self.moved)
        let seen = GlanceBuilder.make(
            status: missed, today: "2026-11-12", macZone: "Asia/Gaza", acknowledgedSlot: Self.moved, runs: runs)
        #expect(seen.unseenProblemSlot == nil)
        let plain = GlanceBuilder.make(status: missed, today: "2026-11-12", macZone: "Asia/Gaza")
        #expect(plain.headline == "Needs a look: 13:00 today")
    }

    @Test func unresolvedGroupsNameTheMinute() throws {
        let rows = [UnresolvedReservation(enrollmentId: "enr_a", slot: Self.moved, at: 1)]
        let runs = RunTimes.make(status: try self.status(), projection: try self.projection())
        let groups = UnresolvedGroup.make(rows, today: "2026-11-12", runs: runs)
        #expect(groups.map(\.text) == ["Today 13:10: 1 account, no result recorded"])
        #expect(groups.map(\.slot) == [Self.moved])
        let plain = UnresolvedGroup.make(rows, today: "2026-11-12")
        #expect(plain.map(\.text) == ["Today 13:00: 1 account, no result recorded"])
    }

    @Test func cliVerdictAndTodayAgreeForAMovedMissedTime() throws {
        let snapshot = StatusCLI.Snapshot(
            status: try self.missedMoved(), observedAt: Self.afternoon, projection: try self.projection())
        let now = Date(timeIntervalSince1970: Double(Self.afternoon) / 1000)
        let text = StatusCLI.render(snapshot, json: false, now: now)
        let lines = String(decoding: text.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.first == "Needs a look: 13:10 today")
        let today = try #require(lines.first { $0.hasPrefix("Today: ") })
        #expect(today.contains("13:10"))
        #expect(!today.contains("13:00"))
        let json = StatusCLI.render(snapshot, json: true, now: now)
        let report = try JSONDecoder().decode(StatusCLI.Report.self, from: json.stdout)
        #expect(report.verdict == "Needs a look: 13:10 today")
        #expect(report.today.map(\.time).contains("13:10"))
        #expect(!report.today.map(\.time).contains("13:00"))
    }

    @Test func alertsNameTheMinuteItWasDue() throws {
        let problem = SlotProblem(slot: Self.moved, kind: .notAdmitted(cause: "no_tick_between"), at: 1)
        let runs = RunTimes.make(status: try self.missedMoved(), projection: try self.projection())
        let moved = try #require(
            AlertComposer.content(for: [problem], zone: "Asia/Gaza", macZone: "Asia/Gaza", runs: runs))
        #expect(moved.title == "The 13:10 warm-up was missed")
        #expect(moved.body.hasPrefix("Thu 12 Nov 13:10."))
        #expect(moved.slots == [Self.moved])
        #expect(moved.identifier == "warmup.slot.\(Self.moved)")
        let plain = try #require(AlertComposer.content(for: [problem], zone: "Asia/Gaza", macZone: "Asia/Gaza"))
        #expect(plain.title == "The 13:00 warm-up was missed")
        let pending = [PendingAlert(problem, zone: "Asia/Gaza")]
        let delivered = try #require(AlertComposer.content(for: pending, macZone: "Asia/Gaza", runs: runs))
        #expect(delivered.title == "The 13:10 warm-up was missed")
        #expect(delivered.slots == [Self.moved])
        #expect(AlertComposer.content(for: pending, macZone: "Asia/Gaza")?.title == "The 13:00 warm-up was missed")
    }
}
