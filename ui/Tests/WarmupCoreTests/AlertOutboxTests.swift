import Foundation
import Testing

@testable import WarmupCore

/// 060-FIX5 items 1 and 2, 060-FIX7 item 1: owed alerts wait in a saved per-slot outbox until macOS
/// accepts them, independent of the alert cursor; only accepted slots are announced and released.
@Suite struct AlertOutboxBehavior {
    static let installation = AlertRestart.installation
    static let miss = AlertRestart.miss
    static let day = AlertRestart.day

    /// A slot entry recorded at `at`.
    static func entry(_ slot: String, at: Int = 1_000) -> PendingAlert {
        PendingAlert(SlotProblem(slot: slot, kind: .notAdmitted(cause: "no_tick_between"), at: at), zone: "Asia/Gaza")
    }

    /// Distinct, valid slot labels in order: from 1 November at 00:00, one every 15 minutes.
    static func slots(_ count: Int) -> [String] {
        (0..<count).map { String(format: "2026-11-%02dT%02d:%02d", 1 + $0 / 96, $0 % 96 / 4, $0 % 4 * 15) }
    }

    func status(edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    /// A private (0700) folder like the app's, removed afterwards by the caller.
    func privateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "warmup-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Adding a slot already owed is a no-op; at the cap a new slot is refused and nothing is dropped.
    @Test func addingIsPerSlotAndTheCapRefuses() {
        let empty = AlertOutbox()
        let one = empty.adding(Self.entry("2026-11-12T08:00"))
        #expect(empty.isEmpty)  // pure
        let again = one.adding(Self.entry("2026-11-12T08:00", at: 9_999))
        #expect(again == one)
        #expect(again.entries.first?.detectedAt == 1_000)
        let two = one.adding(Self.entry("2026-11-12T13:00"))
        #expect(two.entries.map(\.slot) == ["2026-11-12T08:00", "2026-11-12T13:00"])
        #expect(two.removing(slots: ["2026-11-12T08:00"]).entries.map(\.slot) == ["2026-11-12T13:00"])
        #expect(two.removing(slots: ["2026-11-12T18:00"]) == two)
        let limit = AlertOutbox.limit
        #expect(limit == 200)
        var full = AlertOutbox()
        for slot in Self.slots(limit + 5) { full = full.adding(Self.entry(slot)) }
        #expect(full.entries.count == limit)
        #expect(full.entries.map(\.slot) == Array(Self.slots(limit)))
        let next = Self.slots(limit + 1)[limit]
        #expect(!full.contains(slot: next))
        // Freeing one place takes the next new slot.
        let freed = full.removing(slots: [Self.slots(1)[0]]).adding(Self.entry(next))
        #expect(freed.contains(slot: next))
        #expect(freed.entries.count == limit)
    }

    /// Delivery groups every owed slot into one notification, then the notice on its own; the request
    /// identifier names the sorted slot labels joined by "+".
    @Test func deliveriesGroupOnlyWhenComposed() throws {
        let notice = PendingAlert.incompleteHistory(for: try self.status(), gapStart: 500)
        let outbox = AlertOutbox().adding(Self.entry("2026-11-12T13:00")).adding(notice)
            .adding(Self.entry("2026-11-12T08:00"))
        #expect(outbox.deliveries.map { $0.map(\.slot) } == [["2026-11-12T13:00", "2026-11-12T08:00"], [""]])
        let grouped = try #require(AlertComposer.content(for: outbox.deliveries[0], macZone: "Asia/Gaza"))
        #expect(grouped.slots == ["2026-11-12T08:00", "2026-11-12T13:00"])
        #expect(grouped.identifier == "warmup.slot.2026-11-12T08:00+2026-11-12T13:00")
        #expect(grouped.title == "2 warm-ups need a look")
        #expect(grouped.body.hasPrefix("Thu 12 Nov 08:00, Thu 12 Nov 13:00. "))
        let shown = try #require(AlertComposer.content(for: outbox.deliveries[1]))
        #expect(shown.identifier == AlertComposer.incompleteHistoryIdentifier)
        #expect(shown.slots == [PendingAlert.noticeKey])
        #expect(outbox.removing(slots: grouped.slots).removing(slots: shown.slots).isEmpty)
        #expect(AlertOutbox().deliveries.isEmpty)
        #expect(AlertComposer.content(for: []) == nil)
    }

    /// The outbox file never shipped: a file in an earlier shape loads empty; a malformed key is dropped.
    @Test func codableRoundTripAndOlderShapeLoadsEmpty() throws {
        let outbox = AlertOutbox().adding(Self.entry("2026-11-12T08:00"))
            .adding(PendingAlert.incompleteHistory(for: try self.status(), gapStart: 500))
        let data = try JSONEncoder().encode(outbox)
        #expect(try JSONDecoder().decode(AlertOutbox.self, from: data) == outbox)
        let directory = try self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AlertOutboxStore(directory: directory)
        #expect(store.save(outbox))
        #expect(store.load() == outbox)
        let older = #"{"entries":[{"title":"T","body":"B","slot":"2026-11-12T08:00","identifier":"x"}]}"#
        #expect(
            FileManager.default.createFile(
                atPath: store.file.path, contents: Data(older.utf8), attributes: [.posixPermissions: 0o600]))
        #expect(store.load().isEmpty)
        let malformed = AlertOutbox(entries: [Self.entry("not-a-slot"), Self.entry("2026-11-12T08:00")])
        let reloaded = try JSONDecoder().decode(AlertOutbox.self, from: try JSONEncoder().encode(malformed))
        #expect(reloaded.entries.map(\.slot) == ["2026-11-12T08:00"])
    }

    @Test func storedEntriesCarryNoIdentifiers() throws {
        let missed = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger("2026-11-12T18:00")] }
        let problems = SlotProblem.from(missed)
        let outbox = AlertOutbox().adding(PendingAlert(try #require(problems.first), zone: missed.schedule.zone))
            .adding(PendingAlert.incompleteHistory(for: missed, gapStart: 500))
        let text = String(decoding: try JSONEncoder().encode(outbox), as: UTF8.self)
        #expect(!text.contains(Self.installation))
        #expect(!text.contains("install_"))
        #expect(!text.contains("enr_"))
        for account in missed.accounts { #expect(!text.contains(account.enrollmentId)) }
    }

    /// The owed slot outlives a quit and a relaunch whose cursor is clamped past the problem;
    /// a successful delivery removes it; switching alerts off clears the file.
    @Test func pendingSlotSurvivesAClampedRearm() throws {
        let directory = try self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AlertOutboxStore(directory: directory)
        #expect(store.file.lastPathComponent == "pending-alerts.json")
        #expect(store.limit == 256 << 10)
        let missed = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger("2026-11-12T18:00")] }
        var tracker = AlertTracker()
        tracker.arm(at: Self.miss - 3_600_000)
        let fresh = tracker.observe(installation: Self.installation, status: missed)
        let entry = PendingAlert(try #require(fresh.first), zone: missed.schedule.zone)
        // Saved before delivery is tried; the submission then fails and the app quits.
        #expect(store.save(store.load().adding(entry)))
        tracker.retain(fresh)
        let stored = try #require(store.load().capping(tracker.coveredThrough))
        #expect(stored < Self.miss)
        // Eight days later the cursor is clamped to 7 days: the tracker no longer announces it.
        var relaunch = AlertTracker()
        relaunch.arm(at: AlertResume.start(stored: stored, now: Self.miss + 8 * Self.day))
        #expect(relaunch.observe(installation: Self.installation, status: missed).isEmpty)
        // The outbox still owes it, independent of the cursor.
        let pending = store.load()
        #expect(pending.entries == [entry])
        // Delivered: removed and saved.
        #expect(store.save(pending.removing(slots: [entry.slot])))
        #expect(store.load().isEmpty)
        // Switching off clears the file.
        #expect(store.save(AlertOutbox().adding(entry)))
        #expect(store.remove())
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        #expect(store.load().isEmpty)
        #expect(store.remove())  // already gone
    }

    /// 060-FIX5 item 2: without a last slot outcome (or with a malformed one) the notice opens Overview.
    /// It is owed under its fixed key, holds the cursor before its gap and leaves only when delivered.
    @Test func incompleteNoticeIsOwedUntilDelivered() throws {
        let none = try self.status { $0.removeValue(forKey: "lastSlotOutcome") }
        #expect(none.lastSlotOutcome == nil)
        let notice = try #require(AlertComposer.content(for: [PendingAlert.incompleteHistory(for: none, gapStart: 1)]))
        #expect(notice.slot == "")
        #expect(notice.identifier == AlertComposer.incompleteHistoryIdentifier)
        #expect(notice.title == "Some earlier warm-ups could not be checked")
        let latest = try self.status {
            $0["lastSlotOutcome"] = ProblemAlerts.outcome("2026-11-12T13:00", at: 3_000_000)
        }
        let opened = AlertComposer.content(for: [PendingAlert.incompleteHistory(for: latest, gapStart: 1)])
        #expect(opened?.slot == "2026-11-12T13:00")
        // A malformed slot, if the validator lets one through, also falls back to Overview.
        let output = try Fixture.output("status-enabled") {
            $0["lastSlotOutcome"] = ProblemAlerts.outcome("not-a-slot", at: 3_000_000)
        }
        if let malformed = ReplyValidator.payload(EngineStatus.self, from: output) {
            let fallback = AlertComposer.content(for: [PendingAlert.incompleteHistory(for: malformed, gapStart: 1)])
            #expect(fallback?.slot == "")
        }
        // A gap is found: the notice is owed from the gap start, once.
        var tracker = AlertTracker()
        let first = try self.status { $0["lastSlotOutcome"] = ProblemAlerts.outcome("2026-11-12T03:00", at: 1_000_000) }
        _ = tracker.observe(installation: Self.installation, status: first)
        let late = ProblemAlerts.reply([], requestedAt: 1_000_000 + 31 * Self.day)
        _ = tracker.observe(installation: Self.installation, status: latest, history: late)
        let due = tracker.takeIncompleteNotice()
        #expect(due)
        let gapStart = try #require(tracker.incompleteGapStart)
        let entry = PendingAlert.incompleteHistory(for: latest, gapStart: gapStart)
        let owed = AlertOutbox().adding(entry)
        #expect(owed.adding(PendingAlert.incompleteHistory(for: latest, gapStart: gapStart + 5)) == owed)
        #expect(try #require(owed.capping(tracker.coveredThrough)) < gapStart)
        // Delivered: the entry leaves and the tracker may pass the gap.
        let content = try #require(AlertComposer.content(for: owed.deliveries[0]))
        tracker.delivered(slots: content.slots)
        #expect(owed.removing(slots: content.slots).isEmpty)
        #expect(tracker.incompleteGapStart == nil)
        #expect(tracker.coveredThrough == 3_000_000)
        #expect(tracker.announced.isEmpty)  // the notice is not a slot
    }

    @Test func storageIssue() {
        let waiting = AlertOutbox().adding(Self.entry("2026-11-12T08:00"))
        #expect(waiting.issue(saved: false, refused: false) == "Alerts could not be saved; they will be retried.")
        #expect(waiting.issue(saved: true, refused: false) == nil)
        #expect(waiting.issue(saved: true, refused: true) == AlertOutbox.unsavedIssue)
        #expect(AlertOutbox().issue(saved: false, refused: false) == nil)  // nothing waits
    }

    @Test func cappingHoldsTheCursorBeforeTheOldestOwedEntry() {
        let outbox = AlertOutbox().adding(Self.entry("2026-11-12T13:00", at: 5_000))
            .adding(Self.entry("2026-11-12T08:00", at: 2_000))
        #expect(outbox.capping(9_000) == 1_999)
        #expect(outbox.capping(1_000) == 1_000)
        #expect(outbox.capping(nil) == nil)
        #expect(AlertOutbox().capping(9_000) == 9_000)
    }

    /// Item 1: when both the save and the submission fail, the stored cursor stays before the alert,
    /// so a relaunch (with no outbox file) announces the problem again.
    @Test func unsavedUndeliveredAlertIsFoundAgain() throws {
        let missed = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger("2026-11-12T18:00")] }
        var tracker = AlertTracker()
        tracker.arm(at: Self.miss - 3_600_000)
        let fresh = tracker.observe(installation: Self.installation, status: missed)
        // No private folder: the save fails; the submission fails too, so the entry stays in memory.
        let store = AlertOutboxStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("warmup-missing-\(UUID())"))
        let outbox = AlertOutbox().adding(PendingAlert(try #require(fresh.first), zone: missed.schedule.zone))
        #expect(!store.save(outbox))
        #expect(outbox.issue(saved: false, refused: false) == AlertOutbox.unsavedIssue)
        tracker.retain(fresh)
        let stored = try #require(outbox.capping(tracker.coveredThrough))
        #expect(stored < fresh[0].at)
        #expect(tracker.announced.isEmpty)
        var relaunch = AlertTracker()
        relaunch.arm(at: AlertResume.start(stored: stored, now: Self.miss + Self.day), announced: tracker.announced)
        #expect(store.load().isEmpty)
        #expect(relaunch.observe(installation: Self.installation, status: missed).map(\.slot) == ["2026-11-12T18:00"])
    }

    // MARK: - 060-FIX7 item 1

    /// The older owed slots are delivered while the newer one, refused at the full outbox, is not: only
    /// the accepted slots are announced, and a re-arm raises the newer one.
    @Test func onlyAcceptedSlotsAreAnnounced() throws {
        let older = "2026-11-12T08:00"
        let newer = "2026-11-12T13:00"
        var tracker = AlertTracker()
        tracker.arm(at: Self.miss - 3_600_000)
        let first = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger(older)] }
        let found = tracker.observe(installation: Self.installation, status: first)
        #expect(found.map(\.slot) == [older])
        // Slots owed from an earlier run fill the outbox with the older one.
        var outbox = AlertOutbox()
        for slot in Self.slots(AlertOutbox.limit - 1) { outbox = outbox.adding(Self.entry(slot, at: Self.miss)) }
        outbox = outbox.adding(PendingAlert(found[0], zone: first.schedule.zone))
        tracker.retain(found)
        // The first delivery fails; the next observation also finds the newer slot.
        let second = try self.status {
            $0["slotLedger"] = [ProblemAlerts.ledger(older), ProblemAlerts.ledger(newer)]
        }
        let problems = tracker.observe(installation: Self.installation, status: second)
        #expect(problems.map(\.slot) == [older, newer])
        let taken = problems.map { problem -> Bool in
            outbox = outbox.adding(PendingAlert(problem, zone: second.schedule.zone))
            return outbox.contains(slot: problem.slot)
        }
        #expect(taken == [true, false])  // the older is already owed; the newer is refused at the cap
        tracker.retain(problems)
        // The delivery is accepted: exactly its slots leave the outbox and are announced.
        let content = try #require(AlertComposer.content(for: outbox.deliveries[0]))
        #expect(!content.slots.contains(newer))
        outbox = outbox.removing(slots: content.slots)
        tracker.delivered(slots: content.slots)
        #expect(outbox.isEmpty)
        #expect(tracker.announced.contains(older))
        #expect(!tracker.announced.contains(newer))
        let stored = try #require(outbox.capping(tracker.coveredThrough))
        #expect(stored < Self.miss)
        // Relaunch: the older is not repeated, the newer is raised.
        var relaunch = AlertTracker()
        relaunch.arm(at: AlertResume.start(stored: stored, now: Self.miss + Self.day), announced: tracker.announced)
        #expect(relaunch.observe(installation: Self.installation, status: second).map(\.slot) == [newer])
    }

    /// A timer retry that succeeds releases the slot from the tracker: the next observation returns only
    /// the new slot, and the next notification names only it.
    @Test func timerRetryReleasesTheSlot() throws {
        let earlier = "2026-11-12T18:00"
        let later = "2026-11-12T19:00"
        var tracker = AlertTracker()
        tracker.arm(at: Self.miss - 3_600_000)
        let first = try self.status { $0["slotLedger"] = [ProblemAlerts.ledger(earlier)] }
        let found = tracker.observe(installation: Self.installation, status: first)
        var outbox = AlertOutbox().adding(PendingAlert(try #require(found.first), zone: first.schedule.zone))
        tracker.retain(found)  // the observation's delivery failed
        // The timer retries and macOS accepts it.
        let retried = try #require(AlertComposer.content(for: outbox.deliveries[0]))
        #expect(retried.slots == [earlier])
        outbox = outbox.removing(slots: retried.slots)
        tracker.delivered(slots: retried.slots)
        #expect(tracker.announced == [earlier])
        let second = try self.status {
            $0["slotLedger"] = [ProblemAlerts.ledger(earlier), ProblemAlerts.ledger(later)]
        }
        let next = tracker.observe(installation: Self.installation, status: second)
        #expect(next.map(\.slot) == [later])
        for problem in next { outbox = outbox.adding(PendingAlert(problem, zone: second.schedule.zone)) }
        let content = try #require(AlertComposer.content(for: outbox.deliveries[0]))
        #expect(content.slots == [later])
        #expect(tracker.observe(installation: Self.installation, status: second).isEmpty)
    }
}

/// 060-FIX8 items 1 to 3: the outbox holds everything the 7-day window can produce, accepted slots
/// leave it on load, and a group names each slot in its own zone.
extension AlertOutboxBehavior {
    /// The longest zone identifier the system knows.
    static var longestZone: String {
        TimeZone.knownTimeZoneIdentifiers.max { $0.utf8.count < $1.utf8.count } ?? "UTC"
    }

    /// A full outbox of the largest entries encodes within the byte cap and round-trips through the store.
    @Test func fullOutboxOfMaximalEntriesRoundTrips() throws {
        let directory = try self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AlertOutboxStore(directory: directory)
        let outcome = String(repeating: "x", count: 32)
        let kind = SlotProblem.Kind.batch(outcome: outcome, sent: .max, confirmed: .max, unknown: .max)
        let entries = Self.slots(AlertOutbox.limit).map {
            PendingAlert(slot: $0, problem: .slot(kind), zone: Self.longestZone, detectedAt: .max)
        }
        let full = AlertOutbox(entries: entries)
        #expect(full.entries.count == 200)
        #expect(try JSONEncoder().encode(full).count <= AlertOutboxStore.maxBytes)
        #expect(store.save(full))
        #expect(store.load() == full)
    }

    /// Slots macOS already accepted (the stored announced list) are dropped from a loaded outbox, so a
    /// restart never sends them again; the rest, and the notice, stay owed.
    @Test func acceptedSlotsLeaveTheLoadedOutbox() throws {
        let notice = PendingAlert.incompleteHistory(for: try self.status(), gapStart: 500)
        let stored = AlertOutbox().adding(Self.entry("2026-11-12T08:00")).adding(Self.entry("2026-11-12T13:00"))
            .adding(notice)
        // Saves failed while macOS accepted 08:00 and a slot that never reached the disk.
        let accepted = ["2026-11-12T08:00", "2026-11-11T18:00"]
        let loaded = stored.removing(slots: accepted)
        #expect(loaded.entries.map(\.slot) == ["2026-11-12T13:00", PendingAlert.noticeKey])
        #expect(loaded.removing(slots: []) == loaded)
        #expect(AlertOutbox().removing(slots: accepted).isEmpty)
    }

    /// A group spanning a zone change names each slot in its own stored zone.
    @Test func groupedSlotsKeepTheirOwnZones() throws {
        let gaza = PendingAlert(
            SlotProblem(slot: "2026-11-12T08:00", kind: .notAdmitted(cause: "no_tick_between"), at: 1_000),
            zone: "Asia/Gaza")
        let london = PendingAlert(
            SlotProblem(slot: "2026-11-12T13:00", kind: .notAdmitted(cause: "no_tick_between"), at: 2_000),
            zone: "Europe/London")
        let mixed = try #require(AlertComposer.content(for: [london, gaza], macZone: "Asia/Gaza"))
        #expect(mixed.title == "2 warm-ups need a look")
        #expect(mixed.body == "Thu 12 Nov 08:00, Thu 12 Nov 13:00 (Europe/London). Open Warm-up to see what happened.")
        #expect(mixed.slots == ["2026-11-12T08:00", "2026-11-12T13:00"])
        let elsewhere = try #require(AlertComposer.content(for: [gaza, london], macZone: "UTC"))
        #expect(elsewhere.body.hasPrefix("Thu 12 Nov 08:00 (Asia/Gaza), Thu 12 Nov 13:00 (Europe/London). "))
        // One zone throughout keeps the single trailing suffix.
        let same = try #require(AlertComposer.content(for: [gaza, Self.entry("2026-11-12T13:00")], macZone: "UTC"))
        #expect(same.body.hasPrefix("Thu 12 Nov 08:00, Thu 12 Nov 13:00 (Asia/Gaza). "))
    }
}
