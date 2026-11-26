import Foundation
import Testing
@testable import WarmupCore

/// App 0.5: confirmation tiers and grouped "Needs attention" rows.
@Suite struct Polish {
    @Test func onlySendsEnrollmentPauseResumeAndTimeChangesAsk() {
        let asks: [WarmupAction] = [
            .runAll(allowSlotOverlap: false), .runAccount(enrollmentId: "e", allowSlotOverlap: false),
            .enroll(routerAccountId: "r"), .pause(expectedRevision: 1), .resume(expectedRevision: 1),
            .saveEdit(.add(time: "21:00", today: false), expectedRevision: 1, expectedLocalDate: "2026-11-22"),
            .setting(.undo, expectedRevision: 1, expectedLocalDate: nil),
        ]
        let settings: [ScheduleSetting] = [
            .exclude(start: "2026-12-01", end: "2026-12-05"), .include(start: "2026-12-01", end: "2026-12-05"),
            .accounts(nil), .accounts(["e"]), .addAccount("e"), .removeAccount("e"),
            .cap(enrollmentId: "e", count: 2), .cap(enrollmentId: "e", count: nil),
        ]
        let allAsk = asks.allSatisfy(\.needsConfirmation)
        #expect(allAsk)
        let quiet = settings.map { WarmupAction.setting($0, expectedRevision: 1, expectedLocalDate: nil) }
        let noneAsk = quiet.allSatisfy { !$0.needsConfirmation }
        #expect(noneAsk)
        // Every action that sends a request still asks.
        let senders = asks.filter(\.sendsRequests).count
        #expect(senders == 2)
    }

    @Test func scheduledCheckboxSendsTheChosenValueAndIsReversible() {
        let enabled = ["a", "b", "c"]
        // The value clicked, not a flip of what was last read: already in that state means no change.
        #expect(ScheduledAccounts.change("a", scheduled: true, current: nil, enabled: enabled) == nil)
        #expect(ScheduledAccounts.change("a", scheduled: false, current: ["b", "c"], enabled: enabled) == nil)
        #expect(ScheduledAccounts.change("a", scheduled: false, current: nil, enabled: enabled) == .removeAccount("a"))
        // Re-adding the last missing enabled account restores "all"; otherwise one is added.
        #expect(
            ScheduledAccounts.change("a", scheduled: true, current: ["b", "c"], enabled: enabled) == .accounts(nil))
        #expect(ScheduledAccounts.change("a", scheduled: true, current: ["b"], enabled: enabled) == .addAccount("a"))
        // Without a known enabled list, nothing widens to "all".
        #expect(ScheduledAccounts.change("a", scheduled: true, current: ["b"], enabled: []) == .addAccount("a"))
    }

    @Test func allEnabledComesFromTheSameStatusReplyOnly() throws {
        let all = try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled")))
        #expect(all.enabled == all.accounts.count)
        #expect(ScheduledAccounts.allEnabled(all) == all.accounts.map(\.enrollmentId))
        let oneDisabled = try #require(
            ReplyValidator.payload(
                EngineStatus.self, from: try Fixture.output("status-enabled") { $0["enabled"] = all.accounts.count - 1 }
            ))
        #expect(ScheduledAccounts.allEnabled(oneDisabled).isEmpty)
    }

    @Test func unresolvedRowsGroupBySlotNewestFirstWithManualLast() {
        let rows = [
            UnresolvedReservation(enrollmentId: "a", slot: nil, at: 1),
            UnresolvedReservation(enrollmentId: "a", slot: "2026-11-15T13:00", at: 2),
            UnresolvedReservation(enrollmentId: "b", slot: "2026-11-15T13:00", at: 2),
            UnresolvedReservation(enrollmentId: "a", slot: "2026-11-19T08:00", at: 3),
            UnresolvedReservation(enrollmentId: "b", slot: nil, at: 4),
        ]
        let groups = UnresolvedGroup.make(rows, today: "2026-11-21")
        #expect(groups.map(\.slot) == ["2026-11-19T08:00", "2026-11-15T13:00", nil])
        #expect(groups[0].text.hasSuffix(": 1 account, no result recorded"))
        #expect(groups[1].text.hasSuffix(": 2 accounts, no result recorded"))
        #expect(groups[2].text == "2 manual warm-ups, no result recorded")
        #expect(!groups.map(\.text).joined().contains("T13:00"))
        #expect(UnresolvedGroup.make([rows[0]], today: nil).map(\.text) == ["1 manual warm-up, no result recorded"])
        #expect(UnresolvedGroup.make([], today: nil).isEmpty)
    }

    @Test func pickedDayReadsLikeTheRestOfTheApp() throws {
        let gaza = try #require(TimeZone(identifier: "Asia/Gaza"))
        // 2026-11-26 22:30 UTC is already Fri 27 Nov in Gaza: the words follow the picker's zone.
        let late = Date(timeIntervalSince1970: 1_795_732_200)
        #expect(FriendlyTime.picked(late, zone: gaza) == "Fri 27 Nov")
        #expect(FriendlyTime.picked(late, zone: ClockTime.utc) == "Thu 26 Nov")
    }
}
