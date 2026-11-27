import Foundation
import Testing

@testable import WarmupCore

/// App 0.6 F5: the read plan (P1), the menu-open rule (P3) and Low Power Mode (P4).
@Suite struct ReadPlanning {
    static let now = Date(timeIntervalSince1970: 1_794_463_200)

    func status(edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    /// A context where the list and wake checks are fresh, so only real changes trigger reads.
    static func context(_ edit: (inout ReadContext) -> Void = { _ in }) -> ReadContext {
        var context = ReadContext(
            visibleTab: .overview, lastList: Self.now.addingTimeInterval(-60),
            lastWake: Self.now.addingTimeInterval(-60),
            now: Self.now)
        edit(&context)
        return context
    }

    func reads(_ edit: @escaping (inout [String: Any]) -> Void, context: ReadContext = Self.context()) throws -> Set<
        ReadKind
    > {
        ReadPlan.reads(previous: try self.status(), current: try self.status(edit: edit), context: context)
    }

    @Test func nothingChangedReadsOnlyStatus() throws {
        let status = try self.status()
        #expect(ReadPlan.reads(previous: status, current: status, context: Self.context()).isEmpty)
    }

    @Test func firstReadAndForce() throws {
        let status = try self.status()
        #expect(
            ReadPlan.reads(previous: nil, current: status, context: Self.context()) == [
                .inspect, .history, .list, .wake,
            ])
        let forced = ReadPlan.reads(previous: status, current: status, context: Self.context { $0.force = true })
        #expect(forced == Set(ReadKind.allCases))
    }

    @Test func statusChangesTriggerTheirReads() throws {
        let revision = try self.reads { $0["scheduleRevision"] = 99 }
        #expect(revision == [.inspect])
        let next: [String: Any] = ["slot": "2026-11-12T13:00", "admission": "13:00", "date": "2026-11-12", "at": 1]
        let moved = try self.reads { $0["next"] = next }
        #expect(moved == [.inspect, .wake])
        let outcome: [String: Any] = ["slot": "2026-11-12T08:00", "outcome": "success", "at": 5, "results": []]
        let finished = try self.reads { $0["lastSlotOutcome"] = outcome }
        #expect(finished == [.inspect, .history])
        let batch: [String: Any] = ["slot": "2026-11-12T08:00", "enrollmentIds": ["enr_01"], "state": "running"]
        let running = try self.reads { $0["activeBatch"] = batch }
        #expect(running == [.inspect])
        let recent: [[String: Any]] = [["enrollmentId": "enr_01", "outcome": "success", "reason": "marker_confirmed"]]
        let history = try self.reads { $0["recent"] = recent }
        #expect(history == [.history])
    }

    /// Work order 144: opening Schedule reads the wake marks even when the last wake read is 1 minute old.
    @Test func scheduleOpeningReadsTheWakeMarks() throws {
        let status = try self.status()
        for visible in [true, false] {
            let context = Self.context {
                $0.lastWake = Self.now.addingTimeInterval(-60)
                $0.scheduleBecameVisible = visible
            }
            let reads = ReadPlan.reads(previous: status, current: status, context: context)
            #expect(reads.contains(.wake) == visible)
        }
    }

    @Test func contextTriggersTheirReads() throws {
        let status = try self.status()
        func plan(_ edit: (inout ReadContext) -> Void) -> Set<ReadKind> {
            ReadPlan.reads(previous: status, current: status, context: Self.context(edit))
        }
        #expect(plan { $0.scheduleBecameVisible = true } == [.inspect, .wake])
        #expect(plan { $0.afterChange = true } == [.inspect, .list])
        #expect(plan { $0.localDateChanged = true } == [.inspect, .history])
        #expect(plan { $0.accountsBecameVisible = true } == [.list])
        #expect(plan { $0.lastList = Self.now.addingTimeInterval(-299) }.isEmpty)
        #expect(plan { $0.lastList = Self.now.addingTimeInterval(-300) } == [.list])
        #expect(plan { $0.lastWake = Self.now.addingTimeInterval(-599) }.isEmpty)
        #expect(plan { $0.lastWake = Self.now.addingTimeInterval(-600) } == [.wake])
        #expect(plan { $0.selectedSlotInProgress = true } == [.slotDetail])
    }

    static var ledgerRow: [String: Any] {
        ["slot": "2026-11-12T08:00", "admission": "08:00", "cause": "missed", "zone": "Europe/Amsterdam", "at": 7]
    }

    /// 060-FIX1 item 5: a miss recorded only in the ledger or the blocked list refreshes history and inspect.
    @Test func ledgerOnlyMissReadsHistoryAndInspect() throws {
        let ledger = try self.reads { $0["slotLedger"] = [Self.ledgerRow] }
        #expect(ledger == [.inspect, .history])
        let blocked = try self.reads { $0["blockedSlots"] = [["slot": "2026-11-12T08:00", "at": 7]] }
        #expect(blocked == [.inspect, .history])
    }

    /// 060-FIX1 item 6: the selected time's detail refreshes on evidence changes and after a failed read.
    @Test func selectedDetailRefreshesOnEvidenceAndFailure() throws {
        let selected = Self.context { $0.hasSelectedSlot = true }
        let ledger = try self.reads({ $0["slotLedger"] = [Self.ledgerRow] }, context: selected)
        #expect(ledger.contains(.slotDetail))
        let blockedRow: [String: Any] = ["slot": "2026-11-12T08:00", "at": 7]
        let blocked = try self.reads({ $0["blockedSlots"] = [blockedRow] }, context: selected)
        #expect(blocked.contains(.slotDetail))
        let outcome: [String: Any] = ["slot": "2026-11-12T08:00", "outcome": "success", "at": 5, "results": []]
        let finished = try self.reads({ $0["lastSlotOutcome"] = outcome }, context: selected)
        #expect(finished.contains(.slotDetail))
        let unselected = try self.reads { $0["slotLedger"] = [Self.ledgerRow] }
        #expect(!unselected.contains(.slotDetail))
        let status = try self.status()
        let failed = ReadPlan.reads(
            previous: status, current: status,
            context: Self.context {
                $0.hasSelectedSlot = true
                $0.selectedDetailFailed = true
            })
        #expect(failed == [.slotDetail])
        let quiet = ReadPlan.reads(previous: status, current: status, context: selected)
        #expect(quiet.isEmpty)
    }

    @Test func menuOpenSkipsAFreshRead() {
        #expect(ReadPlan.menuOpenNeedsRead(lastGoodRead: nil, now: Self.now))
        #expect(!ReadPlan.menuOpenNeedsRead(lastGoodRead: Self.now.addingTimeInterval(-9), now: Self.now))
        #expect(ReadPlan.menuOpenNeedsRead(lastGoodRead: Self.now.addingTimeInterval(-10), now: Self.now))
    }

    @Test func lowPowerDoublesTheRegularInterval() throws {
        let idle = try self.status { $0["next"] = NSNull() }
        #expect(RefreshPlan.delay(nowMilliseconds: 0, status: idle) == 15 * 60)
        #expect(RefreshPlan.delay(nowMilliseconds: 0, status: idle, lowPower: true) == 30 * 60)
        #expect(RefreshPlan.delay(nowMilliseconds: 0, status: nil, lowPower: true) == RefreshPlan.retry)
    }
}
