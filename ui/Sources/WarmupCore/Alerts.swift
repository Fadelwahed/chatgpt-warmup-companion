import Foundation

// A3 opt-in problem alerts and the stale-heartbeat indicator (backlog item 5). Everything here is
// derived from one validated status reply. Nothing is written back, no request is sent, and
// silence is never turned into a cause such as sleep.

/// The engine tick heartbeat, judged against the engine's own observation time in the same reply.
public enum HeartbeatCheck {
    /// The LaunchAgent ticks every 30 seconds; four missed ticks mark the heartbeat as stale.
    public static let staleAfterMilliseconds = 120_000

    /// The last tick time when the heartbeat is stale while scheduling is enabled and the job is
    /// loaded; nil otherwise. A missing tick or an unreadable observation time is unknown, not stale.
    public static func staleSince(_ status: EngineStatus, observedAt: Int?) -> Int? {
        guard status.scheduleEnabled, status.job == "loaded", let tick = status.lastTick, let observedAt else { return nil }
        return observedAt - tick > self.staleAfterMilliseconds ? tick : nil
    }

    /// Milliseconds since 1970 for the envelope's ISO 8601 `observedAt`, or nil if it is not one.
    public static func milliseconds(iso8601 text: String) -> Int? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: text) ?? plain.date(from: text) else { return nil }
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// "No check-in since 21:50", or "since 21:00 yesterday" when the tick is from an earlier day.
    public static func headline(tick: Int, observedAt: Int, zone: String) -> String {
        let timeZone = TimeZone(identifier: zone) ?? .current
        let label = FriendlyTime.formatter("yyyy-MM-dd'T'HH:mm", zone: timeZone)
            .string(from: Date(timeIntervalSince1970: Double(tick) / 1000))
        let today = FriendlyTime.formatter("yyyy-MM-dd", zone: timeZone)
            .string(from: Date(timeIntervalSince1970: Double(observedAt) / 1000))
        let sameDay = label.hasPrefix(today)
        return "No check-in since \(sameDay ? String(label.suffix(5)) : FriendlyTime.slotShort(label, today: today))"
    }
}

/// One recorded problem with a scheduled slot. Only recorded evidence counts: a not-admitted
/// ledger row, or a finished batch whose outcome is neither `success` nor `idle` (`idle` means
/// no account was enabled). An unobserved minute is not a problem until the engine records it.
/// Slots skipped by the operator's own choice (a pause or a recovery boundary) are not problems.
public struct SlotProblem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, Codable {
        case notAdmitted(cause: String)
        case batch(outcome: String, sent: Int, confirmed: Int, unknown: Int)
        /// The engine stopped the batch and its account rows were not kept, so sends are unknown.
        case stopped
    }

    public let slot: String
    public let kind: Kind
    /// When the engine recorded it, in engine wall-clock milliseconds.
    public let at: Int

    public static let operatorChosenCauses: Set<String> = [
        "schedule_disabled", "recovery_skip_through", "no_scheduled_accounts",
    ]
    public static let quietBatchOutcomes: Set<String> = ["success", "idle"]

    /// A real calendar minute in the engine's `yyyy-MM-ddTHH:mm` form, not just its shape.
    /// Checked in UTC so a local DST gap or repeat does not reject an engine slot label.
    public static func isSlot(_ slot: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.isLenient = false
        guard let date = formatter.date(from: slot) else { return false }
        return formatter.string(from: date) == slot
    }

    /// At most one problem per logical slot, oldest first. The latest finished batch outranks a
    /// batch rebuilt from `history`, which outranks a ledger row for the same slot, so the result
    /// never depends on sort stability.
    ///
    /// Status keeps only the latest batch outcome. `history` rows (read when that outcome moved
    /// on) add the scheduled batches that finished before it and after `historyAfter`; rows for
    /// a slot at or after the latest outcome belong to it or to a batch still running.
    public static func from(
        _ status: EngineStatus, history: [HistoryEntry] = [], historyAfter: Int? = nil
    ) -> [SlotProblem] {
        var bySlot: [String: SlotProblem] = [:]
        for row in status.slotLedger where !self.operatorChosenCauses.contains(row.cause) {
            bySlot[row.slot] = bySlot[row.slot] ?? SlotProblem(slot: row.slot, kind: .notAdmitted(cause: row.cause), at: row.at)
        }
        if let latest = status.lastSlotOutcome?.slot {
            for problem in self.fromHistory(history) where problem.slot < latest {
                if let historyAfter, problem.at <= historyAfter { continue }
                bySlot[problem.slot] = problem
            }
            // Stopped batches whose rows may never have been saved (engine 1.2).
            for blocked in status.blockedSlots ?? [] where blocked.slot < latest && bySlot[blocked.slot] == nil {
                if let historyAfter, blocked.at <= historyAfter { continue }
                bySlot[blocked.slot] = SlotProblem(slot: blocked.slot, kind: .stopped, at: blocked.at)
            }
        }
        // A batch the engine stopped ("blocked") is always reported, even if its rows are cap skips.
        if let last = status.lastSlotOutcome, !self.quietBatchOutcomes.contains(last.outcome ?? "unknown"),
            last.outcome == "blocked" || !self.onlyChosenSkips(last.results ?? [])
        {
            let results = last.results ?? []
            bySlot[last.slot] = SlotProblem(slot: last.slot, kind: .batch(
                outcome: last.outcome ?? "unknown",
                sent: results.filter { $0.dispatched == true }.count,
                confirmed: results.filter { $0.outcome == "success" }.count,
                unknown: results.filter { $0.outcome == "uncertain" }.count), at: last.at)
        }
        return bySlot.values.filter { self.isSlot($0.slot) }.sorted { $0.slot < $1.slot }
    }

    /// Skip reasons that follow from the operator's own settings, not from a failure.
    static let chosenSkipReasons: Set<String> = ["daily_cap_reached"]

    /// True when every account that did not succeed was skipped for an operator-chosen reason.
    static func onlyChosenSkips(_ results: [AccountResult]) -> Bool {
        let other = results.filter { $0.outcome != "success" }
        return !other.isEmpty && other.allSatisfy { self.chosenSkipReasons.contains($0.reason) }
    }

    /// Scheduled batches rebuilt from `history` rows: a slot is a problem unless every one of its
    /// rows is a confirmed success, matching how the engine marks a finished batch `partial`.
    static func fromHistory(_ rows: [HistoryEntry]) -> [SlotProblem] {
        var bySlot: [String: [HistoryEntry]] = [:]
        for row in rows where row.mode == "scheduled" {
            guard let slot = row.slot else { continue }
            bySlot[slot, default: []].append(row)
        }
        return bySlot.compactMap { slot, rows in
            // A daily cap the operator set is a choice, not a failure (Increment B4), unless the
            // engine stopped the batch.
            let blocked = rows.contains { $0.batchOutcome == "blocked" }
            let failing = rows.filter { $0.status != "success" && !Self.chosenSkipReasons.contains($0.reason ?? "") }
            guard blocked || !failing.isEmpty
            else { return nil }
            guard let at = rows.compactMap(\.at).max() else { return nil }
            let kind = Kind.batch(
                outcome: blocked ? "blocked" : "partial",
                sent: rows.filter { $0.dispatched == true }.count,
                confirmed: rows.filter { $0.status == "success" }.count,
                unknown: rows.filter { $0.status == "uncertain" }.count
            )
            return SlotProblem(slot: slot, kind: kind, at: at)
        }
    }
}

/// A catch-up `history` reply and when it was requested (Mac wall clock, engine milliseconds).
public struct HistoryReply: Sendable, Equatable {
    public let rows: [HistoryEntry]
    public let truncated: Bool
    public let requestedAt: Int

    public init(rows: [HistoryEntry], truncated: Bool, requestedAt: Int) {
        self.rows = rows
        self.truncated = truncated
        self.requestedAt = requestedAt
    }

    /// The engine answers with the newest 50 rows from the 30 days before the request.
    static let windowMilliseconds = 30 * 86_400_000
    /// How much later than `requestedAt` the engine may take its own time for the cutoff.
    static let cutoffMarginMilliseconds = 120_000

    /// Rows safe to judge batches by, and whether batches finished after `start` may be missing.
    ///
    /// The read started at `since`. Rows before a later boundary may be missing: before the
    /// oldest returned row when the reply was capped, or before the engine's 30-day cutoff when
    /// that is later than `since`. The cutoff is estimated two minutes late, because the engine
    /// measures it after the app took `requestedAt`. Any scheduled batch whose first returned row
    /// is within one batch length of the boundary may have lost rows, so it is left out instead
    /// of being reported with partial counts. This holds even if the wall clock stepped and rows
    /// from different runs interleave in time order.
    func coverage(after start: Int, since: Int, batchLength: Int) -> (rows: [HistoryEntry], incomplete: Bool) {
        let cutoff = self.requestedAt + Self.cutoffMarginMilliseconds - Self.windowMilliseconds
        var gaps: [Int] = []
        if cutoff > since { gaps.append(cutoff) }
        if self.truncated, let oldestAt = self.rows.compactMap(\.at).min() { gaps.append(oldestAt) }
        guard let boundary = gaps.max() else { return (self.rows, false) }
        var rows = self.rows
        var incomplete = boundary > start
        var batches: [String: [HistoryEntry]] = [:]
        for row in self.rows where row.mode == "scheduled" {
            guard let slot = row.slot else { continue }
            batches[slot, default: []].append(row)
        }
        for (slot, batch) in batches {
            let first = batch.compactMap(\.at).min() ?? Int.min
            guard first < boundary + batchLength else { continue }
            rows.removeAll { $0.slot == slot && $0.mode == "scheduled" }
            if (batch.compactMap(\.at).max() ?? Int.min) > start { incomplete = true }
        }
        return (rows, incomplete)
    }
}

/// Remembers which problems were already present or announced during this app run.
///
/// `arm(at:)` marks when alerts started (launch or switch-on). The first observation for an
/// armed tracker treats problems recorded at or before that time as the baseline and announces
/// those recorded later, so a skipped or failed baseline read loses nothing. A different
/// installation is baselined whole. Afterwards each installation and logical slot is announced
/// at most once.
///
/// Status shows only the latest finished batch, so when it is newer than what earlier reads
/// covered, `historyNeeded` names where to read `history` from and the batches that finished in
/// between are announced too. If that read fails, the next read retries from the same point.
/// Problems that could not be shown are kept and returned by the next observation. A slot counts as
/// announced only once macOS accepted a notification naming it (`delivered(slots:)`, 060-FIX7 item 1).
public struct AlertTracker: Sendable {
    private var installation: String?
    private var armedAt: Int?
    private var seen: Set<String> = []
    /// Batches that finished at or before this engine time are covered by earlier reads.
    private var cursor: Int?
    private var undelivered: [String: SlotProblem] = [:]
    private var incompleteNotice = false
    /// Where the earliest incomplete history read started, while its notice has not been
    /// delivered: `coveredThrough` stays at or before it, so a relaunch reads the gap again and
    /// raises the notice again (060-FIX3 item 4).
    public private(set) var incompleteGapStart: Int?
    /// The latest recorded problem time already seen (baselined or announced).
    private var seenThrough: Int?
    /// Slot labels announced by an earlier run (`arm(at:announced:)`) or delivered in this one:
    /// never fresh again.
    private var preloaded: Set<String> = []
    /// Slot labels macOS accepted, in this run or preloaded, sorted, newest `announcedLimit`.
    private var announcedSlots: [String] = []

    public static let announcedLimit = 30

    public init() {}

    public var hasBaseline: Bool { self.installation != nil }

    /// The engine time this tracker has covered after its observations, for the next launch to arm
    /// from (`AlertResume.start`): the cursor or the latest problem already seen, whichever is later,
    /// but never past a problem still waiting to be shown, nor past the start of a history gap whose
    /// notice is still pending. Nil before any observation.
    public var coveredThrough: Int? {
        guard self.installation != nil else { return nil }
        let covered = [self.cursor, self.seenThrough].compactMap { $0 }.max()
        guard let covered else { return nil }
        let oldestKept = self.undelivered.values.map(\.at).min().map { $0 - 1 }
        return ([covered, oldestKept, self.incompleteGapStart].compactMap { $0 }).min()
    }

    /// Slot labels macOS accepted (`delivered(slots:)`) or preloaded, newest `announcedLimit`, for the
    /// next launch to preload. The cursor alone can stay behind an announced slot when a catch-up read
    /// fails (060-FIX1 item 4). A slot merely seen is never in it, so a relaunch can announce it.
    public var announced: [String] { self.announcedSlots }

    public mutating func arm(at milliseconds: Int?, announced: [String] = []) {
        let preloaded = Array(Set(announced).sorted().suffix(Self.announcedLimit))
        self.preloaded = Set(preloaded)
        self.announcedSlots = preloaded
        self.installation = nil
        self.armedAt = milliseconds
        self.seen = []
        self.cursor = nil
        self.undelivered = [:]
        self.incompleteNotice = false
        self.incompleteGapStart = nil
        self.seenThrough = nil
    }

    public mutating func reset() { self.arm(at: nil) }

    /// Where catch-up starts: the arm time before the first observation, then the latest batch
    /// time already covered. Nil for a different installation, which is baselined whole.
    private func start(for installation: String) -> Int? {
        if self.installation == nil { return self.armedAt }
        return self.installation == installation ? self.cursor : nil
    }

    /// The engine time to read `history` from, or nil when status alone is complete. It reaches
    /// back one batch length, so a batch already running at the start point is read whole; only
    /// batches that finished after the start point count.
    public func historyNeeded(installation: String, status: EngineStatus) -> Int? {
        guard let latest = status.lastSlotOutcome?.at, let start = self.start(for: installation), latest > start else {
            return nil
        }
        return max(0, start - Self.batchLookback(enrolled: status.enrolled))
    }

    /// The engine's longest scheduled batch (45 seconds per account plus 30) and a minute more.
    static func batchLookback(enrolled: Int) -> Int { max(enrolled, 1) * 45_000 + 90_000 }

    /// The `--since` argument for engine milliseconds, in the engine's ISO 8601 UTC form.
    public static func historySince(_ milliseconds: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// Keeps problems that could not be shown; the next observation returns them again.
    public mutating func retain(_ problems: [SlotProblem]) {
        for problem in problems { self.undelivered[problem.slot] = problem }
    }

    /// Keeps the "some earlier slots could not be checked" notice for the next observation. The gap
    /// start stays recorded, so `coveredThrough` keeps before it.
    public mutating func retainIncompleteNotice() { self.incompleteNotice = true }

    /// macOS accepted a notification naming these outbox keys (060-FIX7 item 1): exactly these slots
    /// are announced and released, and `PendingAlert.noticeKey` lets `coveredThrough` pass its gap.
    public mutating func delivered(slots: [String]) {
        let accepted = slots.filter { $0 != PendingAlert.noticeKey }
        for slot in accepted { self.undelivered[slot] = nil }
        if slots.contains(PendingAlert.noticeKey) { self.incompleteGapStart = nil }
        self.seen.formUnion(accepted)
        self.preloaded.formUnion(accepted)
        self.announcedSlots = Array(Set(self.announcedSlots + accepted).sorted().suffix(Self.announcedLimit))
    }

    /// Whether the incomplete-coverage notice is due; asking clears it.
    public mutating func takeIncompleteNotice() -> Bool {
        defer { self.incompleteNotice = false }
        return self.incompleteNotice
    }

    /// Problems to announce now, oldest first: new ones and any kept from a failed delivery.
    /// `history` is the reply for `historyNeeded`, or nil when it was not needed or not read.
    /// A reply that may have missed batches makes `takeIncompleteNotice` true.
    public mutating func observe(
        installation: String, status: EngineStatus, history: HistoryReply? = nil
    ) -> [SlotProblem] {
        let start = self.start(for: installation)
        let needed = self.historyNeeded(installation: installation, status: status) != nil
        let previousCursor = self.installation == installation ? self.cursor : nil
        var rows: [HistoryEntry] = []
        if needed, let history, let start {
            let lookback = Self.batchLookback(enrolled: status.enrolled)
            let coverage = history.coverage(after: start, since: max(0, start - lookback), batchLength: lookback)
            rows = coverage.rows
            if coverage.incomplete {
                self.incompleteNotice = true
                self.incompleteGapStart = min(self.incompleteGapStart ?? start, start)
            }
        }
        let problems = SlotProblem.from(status, history: rows, historyAfter: start)
        if self.installation != installation {
            let armedAt = self.installation == nil ? self.armedAt : nil
            if self.installation != nil {
                self.undelivered = [:]
                self.incompleteGapStart = nil
            }
            self.installation = installation
            self.seen = Set(problems.filter { problem in armedAt.map { problem.at <= $0 } ?? true }.map(\.slot))
                .union(self.preloaded)
        }
        let fresh = problems.filter { !self.seen.contains($0.slot) && !self.preloaded.contains($0.slot) }
        self.seen.formUnion(fresh.map(\.slot))
        if needed && history == nil {
            self.cursor = start  // the catch-up read failed: retry from the same point
        } else {
            self.cursor = [status.lastSlotOutcome?.at, previousCursor, start].compactMap { $0 }.max()
            self.seenThrough = ([self.seenThrough] + problems.map(\.at)).compactMap { $0 }.max()
        }
        let kept = self.undelivered.values.filter { kept in !fresh.contains { $0.slot == kept.slot } }
        self.undelivered = [:]
        return (fresh + kept).sorted { $0.slot < $1.slot }
    }
}

/// Notification text. It names slots, local times, reason codes and counts only: no installation,
/// enrollment, reservation or account identifiers. Composed only for delivery, from the
/// `AlertOutbox` entries being delivered.
public struct AlertContent: Sendable, Equatable {
    public let title: String
    public let body: String
    /// The slot the notification opens in the Schedule pane (the newest one); empty opens Overview.
    public let slot: String
    /// Identifies the delivered notification; repeated content replaces rather than stacks.
    public let identifier: String
    /// The outbox keys it delivers: every slot label it names, oldest first, or
    /// `[PendingAlert.noticeKey]` for the incomplete-history notice.
    public let slots: [String]

    public init(title: String, body: String, slot: String, identifier: String, slots: [String] = []) {
        self.title = title
        self.body = body
        self.slot = slot
        self.identifier = identifier
        self.slots = slots
    }
}

/// Where alerts arm at launch or switch-on (F6): the stored `coveredThrough`, at most 7 days back,
/// so a slot missed while the app was closed is announced once. A missing or future value arms now.
public enum AlertResume {
    public static let maxLookbackMilliseconds = 7 * 86_400_000

    public static func start(stored: Int?, now: Int) -> Int {
        guard let stored, stored <= now else { return now }
        return max(stored, now - self.maxLookbackMilliseconds)
    }

    /// The value to store when arming: the arm time when nothing is stored yet, so a quit before
    /// the first observation resumes from it; nil when a stored value already covers it.
    public static func initialStore(stored: Int?, armedAt: Int) -> Int? {
        stored == nil ? armedAt : nil
    }
}

public enum AlertComposer {
    /// The alert controller's timer interval. From app 0.6 it checks notification permission only and
    /// starts no read; alerts ride on the model's status reads.
    public static let pollIntervalSeconds: TimeInterval = 300

    /// Engine text reaches a notification only through fixed wording: codes are mapped, never
    /// echoed, and slots and the zone are used only when they have their validated shape.
    /// macOS already shows the app's name, so titles say what happened. Dates are absolute
    /// ("Thu 12 Nov 18:00", 060-FIX6 item 3), so an alert delivered on a later day stays true, and
    /// the zone is named only when it is not the Mac's. Each slot is named at the minute it ran (`runs`,
    /// app 0.6.9); the identifier and outbox keys keep the slot labels.
    public static func content(
        for problems: [SlotProblem], zone: String, macZone: String? = TimeZone.current.identifier,
        runs: RunTimes = .none
    ) -> AlertContent? {
        let problems = problems.filter { SlotProblem.isSlot($0.slot) }.sorted { $0.slot < $1.slot }
        guard let newest = problems.last else { return nil }
        let slots = problems.map(\.slot)
        let identifier = self.identifier(slots: slots)
        let suffix = self.zoneSuffix(zone, macZone: macZone)
        guard problems.count == 1 else {
            let names = slots.map { FriendlyTime.slot($0, today: nil, runs: runs) }
            return AlertContent(
                title: "\(problems.count) warm-ups need a look",
                body: "\(names.joined(separator: ", "))\(suffix). Open Warm-up to see what happened.",
                slot: newest.slot, identifier: identifier, slots: slots)
        }
        let when = FriendlyTime.slot(newest.slot, today: nil, runs: runs) + suffix
        let time = runs.time(of: newest.slot) ?? String(newest.slot.suffix(5))
        switch newest.kind {
        case let .notAdmitted(cause):
            return AlertContent(
                title: "The \(time) warm-up was missed", body: "\(when). \(self.cause(cause))", slot: newest.slot,
                identifier: identifier, slots: slots)
        case .stopped:
            return AlertContent(
                title: "The \(time) warm-up did not complete",
                body: "\(when). The engine stopped this batch before its results were saved. "
                    + "Whether anything was sent is unknown; uncertain sends are not resent.",
                slot: newest.slot, identifier: identifier, slots: slots)
        case let .batch(outcome, sent, confirmed, unknown):
            var body = "\(when). \(sent) sent, \(confirmed) confirmed"
            if unknown > 0 { body += ", \(unknown) unknown. Uncertain sends are not resent." } else { body += "." }
            let title = "The \(time) warm-up \(self.batchVerb(outcome))"
            return AlertContent(title: title, body: body, slot: newest.slot, identifier: identifier, slots: slots)
        }
    }

    /// One notification for outbox entries delivered together (060-FIX7 item 1): their slot problems
    /// grouped, or the incomplete-history notice. Nil when there is nothing. Each slot is named in its
    /// own entry's zone, so a group spanning a zone change labels every slot correctly (060-FIX8 item 3).
    public static func content(
        for pending: [PendingAlert], macZone: String? = TimeZone.current.identifier, runs: RunTimes = .none
    ) -> AlertContent? {
        let problems = pending.filter { $0.slotProblem != nil }.sorted { $0.slot < $1.slot }
        if let newest = problems.last {
            let content = self.content(
                for: problems.compactMap(\.slotProblem), zone: newest.zone, macZone: macZone, runs: runs)
            let named = problems.filter { SlotProblem.isSlot($0.slot) }
            guard let content, Set(named.map(\.zone)).count > 1 else { return content }
            let names = named.map {
                FriendlyTime.slot($0.slot, today: nil, runs: runs) + self.zoneSuffix($0.zone, macZone: macZone)
            }
            return AlertContent(
                title: content.title, body: "\(names.joined(separator: ", ")). Open Warm-up to see what happened.",
                slot: content.slot, identifier: content.identifier, slots: content.slots)
        }
        guard case let .incompleteHistory(latestSlot)? = pending.first?.problem else { return nil }
        // Without a valid latest slot it opens Overview, so it is never held back (060-FIX5 item 2).
        return self.incompleteHistory(latestSlot: latestSlot) ?? self.incompleteNotice(slot: "")
    }

    /// The notification identifier for an alert naming `slots` (oldest first): "warmup.slot." and the
    /// sorted slot labels joined by "+", so two alerts share an identifier only when they name the same
    /// slots.
    public static func identifier(slots: [String]) -> String { "warmup.slot.\(slots.joined(separator: "+"))" }

    public static let incompleteHistoryIdentifier = "warmup.history.incomplete"

    /// "" for the Mac's own zone, " (Zone/Name)" for another known zone, " (local time)" otherwise.
    static func zoneSuffix(_ zone: String, macZone: String?) -> String {
        !self.isZone(zone) ? " (local time)" : zone == macZone ? "" : " (\(zone))"
    }

    /// A time zone the system knows by this exact identifier, not just a zone-shaped string.
    static func isZone(_ zone: String) -> Bool {
        TimeZone.knownTimeZoneIdentifiers.contains(zone) || zone == "UTC"
    }

    /// Fixed text for a catch-up `history` read that could not cover every batch (the reply was
    /// capped, or the gap is older than the engine's 30-day history). It opens the latest slot.
    public static func incompleteHistory(latestSlot: String) -> AlertContent? {
        guard SlotProblem.isSlot(latestSlot) else { return nil }
        return self.incompleteNotice(slot: latestSlot)
    }

    private static func incompleteNotice(slot: String) -> AlertContent {
        AlertContent(
            title: "Some earlier warm-ups could not be checked",
            body: "Warm-up could not read every scheduled batch since its last check. Open Warm-up to review recent results.",
            slot: slot, identifier: self.incompleteHistoryIdentifier, slots: [PendingAlert.noticeKey])
    }

    /// Batch outcomes in plain words; an unrecognized outcome gets generic wording.
    public static func batchVerb(_ outcome: String) -> String {
        switch outcome {
        case "partial": "had problems"
        case "blocked": "was blocked"
        case "busy": "could not start because the engine was busy"
        default: "did not complete"
        }
    }

    /// Ledger causes in plain words. None of them states why the Mac or job was silent. An
    /// unrecognized cause gets generic wording.
    public static func cause(_ code: String) -> String {
        switch code {
        case "no_tick_between": "Nothing ran at that minute; the reason was not recorded."
        case "schedule_spacing": "It was too close to the previous warm-up, so it was skipped."
        case "no_scheduled_accounts": "No account was chosen for scheduled warm-ups, so it was skipped."
        case "zone_changed": "The Mac's time zone changed, so it was skipped."
        case "manual_run_overlap": "A manual warm-up was running, so it was skipped."
        case "clock_hold": "The clock moved backward, so scheduling was held."
        case "compatibility_blocked": "Router needs a review, so it was skipped."
        default: "It did not run. Open Warm-up to see the recorded reason."
        }
    }
}
