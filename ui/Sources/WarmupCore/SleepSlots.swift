import Foundation

// Work order 137 Part C: the week's "recorded asleep" slots, moved out of the app shell.

public enum SleepSlots {
    /// Labels of "nothing ran" ledger rows whose recorded minute the app saw the Mac asleep through.
    /// `asleep(from, to)` answers whether the sleep journal covers that span (engine milliseconds). A
    /// row with another cause, or without a usable time, is never in the set.
    public static func make(ledger: [LedgerRow], asleep: (Int, Int) -> Bool) -> Set<String> {
        Set(
            ledger.compactMap { row in
                guard row.cause == WeekReport.noTickCause, let at = LedgerInstant.admissionAt(row),
                    asleep(at, at + 60_000)
                else { return nil }
                return row.slot
            })
    }
}
