import Foundation
import Testing
@testable import WarmupCore

/// Week strip slot identity: a time repeats across days, so a slot's id must carry its date (0.6.1).
@Suite struct Identity {
    static func ledgerRow(_ slot: String) -> [String: Any] {
        [
            "slot": slot, "admission": String(slot.suffix(5)), "verdict": "not_admitted",
            "cause": "no_tick_between", "zone": "Asia/Gaza", "at": 1_795_850_000_000,
            "evidence": [
                "previousTick": 1_795_800_000_000, "tick": 1_795_850_000_000, "previousZone": "Asia/Gaza",
            ],
        ]
    }

    /// 21 Nov 08:00 and 18:00 ran and succeeded; every 22 Nov time was missed.
    func week() throws -> [WeekDay] {
        let status = try #require(
            ReplyValidator.payload(
                EngineStatus.self,
                from: try Fixture.output("status-enabled") {
                    $0["slotLedger"] = [
                        Self.ledgerRow("2026-11-21T13:00"), Self.ledgerRow("2026-11-22T08:00"),
                        Self.ledgerRow("2026-11-22T13:00"), Self.ledgerRow("2026-11-22T18:00"),
                    ]
                    $0["lastSlotOutcome"] = [
                        "slot": "2026-11-21T18:00", "outcome": "success", "at": 1_795_795_224_000, "results": [],
                    ]
                }))
        let history = [
            Insights.row("2026-11-21T08:00", "success", at: 1_795_759_226_000),
            Insights.row("2026-11-21T08:00", "success", at: 1_795_759_229_000),
            Insights.row("2026-11-21T18:00", "success", at: 1_795_795_224_000),
            Insights.row("2026-11-21T18:00", "success", at: 1_795_795_227_000),
        ]
        return WeekSummary.make(today: "2026-11-23", status: status, history: history)
    }

    @Test func slotIdsAreUniqueAcrossDaysAndCarryTheirDay() throws {
        let week = try self.week()
        let slots = week.flatMap(\.slots)
        #expect(slots.count == 6)
        #expect(Set(slots.map(\.id)).count == slots.count)
        for day in week {
            for slot in day.slots {
                #expect(slot.date == day.date)
                #expect(slot.id == "\(day.date)T\(slot.time)")
            }
        }
    }

    @Test func eachDayKeepsItsOwnMarkAtTheSameTime() throws {
        let week = try self.week()
        let saturday = try #require(week.first { $0.date == "2026-11-21" })
        let sunday = try #require(week.first { $0.date == "2026-11-22" })
        #expect(
            saturday.slots == [
                WeekDay.Slot(date: "2026-11-21", time: "08:00", mark: .confirmed),
                WeekDay.Slot(date: "2026-11-21", time: "13:00", mark: .missed),
                WeekDay.Slot(date: "2026-11-21", time: "18:00", mark: .confirmed),
            ])
        #expect(
            sunday.slots == [
                WeekDay.Slot(date: "2026-11-22", time: "08:00", mark: .missed),
                WeekDay.Slot(date: "2026-11-22", time: "13:00", mark: .missed),
                WeekDay.Slot(date: "2026-11-22", time: "18:00", mark: .missed),
            ])
    }
}
