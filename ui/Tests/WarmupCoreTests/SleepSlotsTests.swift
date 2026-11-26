import Foundation
import Testing

@testable import WarmupCore

/// Work order 137 Part C: the week's "recorded asleep" slots, moved out of the app shell.
@Suite struct SleepSlotsRule {
    /// 13:00 on 11 Nov 2026 in Asia/Gaza (UTC+2).
    static let at1300 = 1_794_394_800_000

    static func row(_ slot: String, admission: String, cause: String = "no_tick_between") -> LedgerRow {
        LedgerRow(slot: slot, admission: admission, cause: cause, zone: "Asia/Gaza", at: Self.at1300)
    }

    /// Asleep from 12:00 to 14:00 on 11 Nov in Asia/Gaza.
    static func asleep(from: Int, to: Int) -> Bool {
        from >= Self.at1300 - 3_600_000 && to <= Self.at1300 + 3_600_000
    }

    @Test func aRowCoveredBySleepIsInTheSet() {
        let rows = [Self.row("2026-11-11T13:00", admission: "13:00")]
        #expect(SleepSlots.make(ledger: rows, asleep: Self.asleep) == ["2026-11-11T13:00"])
    }

    @Test func anUncoveredRowIsNotInTheSet() {
        let rows = [Self.row("2026-11-11T18:00", admission: "18:00")]
        #expect(SleepSlots.make(ledger: rows, asleep: Self.asleep).isEmpty)
    }

    @Test func aRowWithAnotherCauseIsNotInTheSet() {
        let rows = [Self.row("2026-11-11T13:00", admission: "13:00", cause: "compatibility_blocked")]
        #expect(SleepSlots.make(ledger: rows, asleep: Self.asleep).isEmpty)
    }

    @Test func aRowWithoutAUsableTimeIsNotInTheSet() {
        let rows = [
            Self.row("2026-11-11T13:00", admission: "1x:00"),
            LedgerRow(
                slot: "2026-11-11T13:00", admission: "13:00", cause: "no_tick_between", zone: "Not/AZone",
                at: Self.at1300),
        ]
        // Asleep at every minute: only the missing time keeps a row out.
        #expect(SleepSlots.make(ledger: rows, asleep: { _, _ in true }).isEmpty)
    }
}
