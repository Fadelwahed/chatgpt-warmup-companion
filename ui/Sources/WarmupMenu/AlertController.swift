import AppKit
import Foundation
import UserNotifications
import WarmupCore

/// A3 opt-in problem alerts. Off by default. While on, the app checks notification permission
/// every five minutes (permission only, P2) and observes each status the model reads anyway; it
/// starts no reads of its own except the switch-on baseline. Each read only observes recorded
/// evidence, sends no warm-up request and changes nothing. Alerts arm from the engine time covered
/// last run (`alertsCoveredThrough`, F6, at most 7 days back), so a problem recorded while the app
/// was closed is announced once; problems before that form the baseline. Each installation and
/// logical slot is announced at most once per app run. Every owed slot waits in a saved outbox
/// (`pending-alerts.json`, one entry per slot) until macOS accepts a notification naming it, so a quit
/// or failed submission never loses one. Only accepted slots are announced, stored and released from
/// the tracker (060-FIX7 item 1). A slot not yet delivered keeps the stored cursor before it, so one
/// whose save failed is found again after a relaunch; the save failure is reported as the alert issue.
/// That saved state belongs to one engine installation (`alertsInstallation`, a fingerprint): a rebind
/// to another installation clears it (`AlertScope`).
@MainActor
final class AlertController: NSObject, ObservableObject {
    static let preferenceKey = "alertsEnabled"
    /// The tracker's `coveredThrough` (engine milliseconds) after each observation; no IDs.
    static let coveredThroughKey = "alertsCoveredThrough"
    /// Slot labels macOS accepted (`2026-11-22T13:00`), stored after each successful delivery; no IDs.
    static let announcedKey = "alertsAnnouncedSlots"
    /// `AlertScope.fingerprint` of the installation the saved alert state belongs to; never the raw ID.
    static let installationKey = "alertsInstallation"
    /// `PauseRecord` JSON (F12): when scheduling was first seen paused and the last reminder; no IDs.
    static let pauseReminderKey = "pauseReminder"
    /// The fixed notification identifier, so a new reminder replaces the last one.
    static let pauseReminderIdentifier = "pause-reminder"
    /// `CompatibilityRecord` JSON: the current blocking episode and whether it was announced; no IDs.
    static let compatibilityAlertKey = "compatibilityAlert"
    /// The fixed notification identifier, so a new episode's alert replaces the last one.
    static let compatibilityAlertIdentifier = "compatibility-blocked"
    static let notAllowed =
        "Alerts are on, but notifications are not allowed for Warm-up. You can allow them in System Settings > Notifications."
    static let notAsked =
        "Alerts are on, but Warm-up has not been allowed to notify yet. Switch alerts off and on to be asked."

    @Published private(set) var enabled: Bool {
        didSet { self.model.setAlertsOn(self.enabled) }
    }
    @Published private(set) var allowed = false
    @Published private(set) var pending = false
    /// Announced through the model when it changes to a new problem, whichever pane is loaded.
    @Published private(set) var issue: String? {
        didSet { if let issue = self.issue, issue != oldValue { self.model.announce(issue) } }
    }
    /// Opens the Schedule pane at the slot a notification names, or Overview for an empty slot.
    var openSlot: ((String) -> Void)?

    private let model: AppModel
    private let defaults: UserDefaults
    private var tracker = AlertTracker()
    /// Slots owed and not yet delivered (060-FIX7 item 1), mirrored to `outboxStore`.
    private var outbox = AlertOutbox()
    /// Nil when there is no private app folder: the outbox then lives in memory only.
    private let outboxStore: AlertOutboxStore?
    /// `AlertOutbox.unsavedIssue` while an alert waiting is not on disk or was refused (060-FIX6 item 1).
    private var storageIssue: String?
    /// The last observation had to refuse an owed slot at the outbox cap; it stays retained.
    private var refused = false
    private var timer: Timer?
    /// Bumped by every switch change, so a late permission answer cannot undo a newer choice.
    private var generation = 0
    /// The latest status observation; each one waits for the previous to finish.
    private var observation: Task<Void, Never>?
    /// Fingerprint of the bound installation at launch; nil when the binding cannot be read.
    private let boundInstallation: String?
    /// The installation the saved state is scoped to; nil until known.
    private var armedInstallation: String?
    /// The binding was unreadable at arm: the stored outbox waits for the first observation.
    private var holdDelivery = false

    /// Notifications need the installed app bundle; a bare executable has no notification identity.
    let available = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

    init(
        model: AppModel, defaults: UserDefaults = .standard,
        outboxStore: AlertOutboxStore? = BindingStore.defaultStore().map { AlertOutboxStore(directory: $0.directory) }
    ) {
        self.model = model
        self.defaults = defaults
        self.outboxStore = outboxStore
        self.boundInstallation = (try? BindingStore.defaultStore()?.load()).map {
            AlertScope.fingerprint(installation: $0.installationId)
        }
        self.enabled = defaults.bool(forKey: Self.preferenceKey)
        super.init()
        model.setAlertsOn(self.enabled)
        model.statusObserver = { [weak self] installation, status in
            self?.observe(installation: installation, status: status)
        }
    }

    private static func now() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// Called once at launch. With alerts on, permission is only checked, never asked for: the
    /// switch-on action is the one place that asks. The model's launch read is the only read; if it
    /// finished before permission was confirmed, its status is observed again without a read.
    func start() {
        guard self.available else {
            self.issue = self.enabled ? "Alerts need the installed Warm-up app." : nil
            return
        }
        UNUserNotificationCenter.current().delegate = self
        guard self.enabled else { return }
        self.arm()
        self.startTimer()
        Task {
            await self.checkPermission()
            guard self.allowed else { return }
            self.model.replayStatus()
            if !self.holdDelivery { self.enqueueFlush() }  // delivers the stored outbox even before a status arrives
        }
    }

    /// Arms from the stored covered time (`AlertResume.start`), or now when there is none, and the
    /// slots already announced, so a cursor left behind by a failed catch-up does not repeat them.
    /// With nothing stored, the arm time is stored at once, so a quit before the first observation
    /// still resumes from it. The stored outbox is loaded and delivered with the first observation
    /// (or once permission is confirmed), independent of the cursor. State saved for another
    /// installation is cleared first, so alerts arm from now.
    private func arm() {
        let saved = self.outboxStore?.load() ?? AlertOutbox()
        let decision = AlertScope.decide(
            current: self.boundInstallation, stored: self.defaults.string(forKey: Self.installationKey),
            outbox: saved.installation)
        self.holdDelivery = decision == .unbound
        self.armedInstallation = self.holdDelivery ? nil : self.boundInstallation
        let reset = self.applyScope(decision)
        let stored = self.defaults.object(forKey: Self.coveredThroughKey) as? Int
        let announced = self.defaults.stringArray(forKey: Self.announcedKey) ?? []
        let armedAt = AlertResume.start(stored: stored, now: Self.now())
        self.tracker.arm(at: armedAt, announced: announced)
        // A slot macOS already accepted while saves failed is dropped, so it is never sent again.
        let loaded = reset ? AlertOutbox() : saved
        self.outbox = loaded.removing(slots: announced).scoped(to: self.armedInstallation ?? loaded.installation)
        if self.outbox != loaded { self.saveOutbox() }
        if let initial = AlertResume.initialStore(stored: stored, armedAt: armedAt) {
            self.defaults.set(initial, forKey: Self.coveredThroughKey)
        }
    }

    /// Applies a scope decision to the saved state; true when it was cleared. A reset clears the
    /// cursor, announced slots and outbox (as switching off does) while alerts stay on.
    private func applyScope(_ decision: AlertScope.Decision) -> Bool {
        switch decision {
        case .keep, .unbound:
            return false
        case let .adopt(fingerprint):
            self.armedInstallation = fingerprint
            self.defaults.set(fingerprint, forKey: Self.installationKey)
            return false
        case let .reset(fingerprint):
            self.armedInstallation = fingerprint
            self.defaults.set(fingerprint, forKey: Self.installationKey)
            self.defaults.removeObject(forKey: Self.coveredThroughKey)
            self.defaults.removeObject(forKey: Self.announcedKey)
            self.defaults.removeObject(forKey: Self.pauseReminderKey)
            self.defaults.removeObject(forKey: Self.compatibilityAlertKey)
            self.outbox = AlertOutbox(installation: fingerprint)
            self.outboxStore?.remove()
            self.refused = false
            self.storageIssue = nil
            self.showStorageIssue()
            return true
        }
    }

    /// Before observing another installation than the armed one: keep or clear the saved state. After
    /// a reset the tracker baselines the new installation whole.
    private func scope(to installation: String) {
        let fingerprint = AlertScope.fingerprint(installation: installation)
        self.holdDelivery = false
        guard fingerprint != self.armedInstallation else { return }
        let decision = AlertScope.decide(
            current: fingerprint, stored: self.defaults.string(forKey: Self.installationKey),
            outbox: self.outbox.installation)
        if self.applyScope(decision) {
            self.tracker.reset()
        } else {
            self.armedInstallation = fingerprint
            self.outbox = self.outbox.scoped(to: fingerprint)
        }
    }

    func setEnabled(_ on: Bool) {
        guard on else {
            self.model.answerAlerts()  // a change that took effect answers the setup card's question
            self.generation &+= 1  // a pending permission answer can no longer switch alerts on
            self.pending = false
            self.enabled = false
            self.defaults.set(false, forKey: Self.preferenceKey)
            self.stopTimer()
            self.tracker.reset()
            self.defaults.removeObject(forKey: Self.coveredThroughKey)
            self.defaults.removeObject(forKey: Self.announcedKey)
            self.defaults.removeObject(forKey: Self.pauseReminderKey)
            self.defaults.removeObject(forKey: Self.compatibilityAlertKey)
            self.outbox = AlertOutbox()
            self.outboxStore?.remove()
            self.refused = false
            self.storageIssue = nil
            self.allowed = false
            self.issue = nil
            return
        }
        guard !self.enabled, !self.pending else { return }
        guard self.available else {
            self.issue = "Alerts need the installed Warm-up app."
            return
        }
        self.generation &+= 1
        let generation = self.generation
        self.pending = true
        Task {
            // Asking is the only system interaction. A refusal is reported; no setting is changed.
            let granted =
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
            guard generation == self.generation else { return }  // switched off meanwhile
            self.pending = false
            guard granted else {
                self.issue =
                    "Notifications are not allowed for Warm-up. You can allow them in System Settings > Notifications."
                return
            }
            self.enabled = true
            self.model.answerAlerts()
            self.defaults.set(true, forKey: Self.preferenceKey)
            self.allowed = true
            self.issue = nil
            self.arm()
            self.startTimer()
            await self.model.refreshAll()  // the baseline read
        }
    }

    /// Rechecks permission. Revoking it stops reads and announcements without losing problems:
    /// the tracker keeps its baseline, so slots recorded meanwhile are announced once it returns.
    /// Never asks: a permission that was reset to undecided is reported, and switching alerts
    /// off and on asks again.
    private func checkPermission() async {
        let generation = self.generation
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard generation == self.generation, self.enabled else { return }
        self.allowed = status == .authorized || status == .provisional
        self.issue = self.allowed ? self.storageIssue : status == .notDetermined ? Self.notAsked : Self.notAllowed
        if self.allowed && !self.outbox.isEmpty && !self.holdDelivery { self.enqueueFlush() }
    }

    private func startTimer() {
        self.stopTimer()
        let timer = Timer(timeInterval: AlertComposer.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkPermission() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        self.timer?.invalidate()
        self.timer = nil
    }

    /// Observations and outbox deliveries apply one at a time, in arrival order, because one may
    /// first read history.
    private func enqueue(_ work: @escaping @MainActor (Int) async -> Void) {
        let generation = self.generation
        let previous = self.observation
        self.observation = Task {
            await previous?.value
            // A newer baseline owns these slots; a revoked permission stops reads until it returns.
            guard generation == self.generation, self.enabled, self.allowed else { return }
            await work(generation)
        }
    }

    private func enqueueFlush() {
        self.enqueue { generation in await self.flush(generation: generation) }
    }

    private func observe(installation: String, status: EngineStatus) {
        guard self.enabled, self.allowed else { return }
        self.enqueue { generation in
            self.scope(to: installation)
            var history: HistoryReply?
            if let since = self.tracker.historyNeeded(installation: installation, status: status) {
                let requestedAt = Self.now()
                if let report = await self.model.readHistory(since: since) {
                    let truncated = report.truncated == true
                    history = HistoryReply(rows: report.rows, truncated: truncated, requestedAt: requestedAt)
                }
                guard generation == self.generation, self.enabled else { return }
            }
            let problems = self.tracker.observe(installation: installation, status: status, history: history)
            let entries = problems.map { PendingAlert($0, zone: status.schedule.zone) }
            self.refused = entries.map { self.add($0) }.contains(false)
            // The notice is due only while its gap start is recorded.
            if self.tracker.takeIncompleteNotice(), let gapStart = self.tracker.incompleteGapStart,
                !self.add(PendingAlert.incompleteHistory(for: status, gapStart: gapStart))
            {
                self.refused = true
                self.tracker.retainIncompleteNotice()  // refused at the cap: raised again next time
            }
            self.saveOutbox()
            // Everything returned stays retained (and the cursor before it) until macOS accepts it:
            // `deliver` releases exactly the accepted slots. A refused slot comes back next time.
            self.tracker.retain(problems)
            await self.flush(generation: generation)
            guard generation == self.generation, self.enabled else { return }
            self.showStorageIssue()
            self.storeCoveredThrough()
            await self.remindIfPaused(installation: installation, status: status, generation: generation)
            await self.alertIfBlocked(installation: installation, status: status, generation: generation)
        }
    }

    /// F12: while scheduling stays paused for a day or more, one reminder, then at most one a day.
    /// It never enters the outbox; a failed delivery is retried at the next observation.
    private func remindIfPaused(installation: String, status: EngineStatus, generation: Int) async {
        let now = Self.now()
        let stored = self.defaults.data(forKey: Self.pauseReminderKey)
            .flatMap { try? JSONDecoder().decode(PauseRecord.self, from: $0) }
        guard
            var record = PauseReminder.update(
                stored, installation: AlertScope.fingerprint(installation: installation),
                scheduleEnabled: status.scheduleEnabled, revision: status.scheduleRevision, now: now)
        else {
            self.defaults.removeObject(forKey: Self.pauseReminderKey)
            return
        }
        self.savePauseRecord(record)
        guard PauseReminder.due(record, now: now), !self.holdDelivery, self.enabled, self.allowed else { return }
        // This observation may have waited behind history and outbox work, and `deliver` awaits macOS:
        // a newer read that shows scheduling resumed (or edited) wins over this snapshot, checked again
        // just before the notification is submitted.
        let pending = record
        let stillPaused = { [weak self] () -> Bool in
            guard let model = self?.model else { return false }
            return PauseReminder.stillApplies(
                pending, latestVerified: model.statusVerified, latestEnabled: model.status?.scheduleEnabled,
                latestRevision: model.status?.scheduleRevision)
        }
        guard stillPaused() else { return }
        let text = PauseReminder.content(since: record.since, zone: .current)
        let content = AlertContent(
            title: text.title, body: text.body, slot: "", identifier: Self.pauseReminderIdentifier)
        guard await self.deliver(content, generation: generation, unless: stillPaused) else { return }
        // The next day counts from when macOS accepted this one, not from before the awaits.
        record.lastReminded = Self.now()
        self.savePauseRecord(record)
    }

    private func savePauseRecord(_ record: PauseRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        self.defaults.set(data, forKey: Self.pauseReminderKey)
    }

    /// Work order 125: while compatibility blocks Warm-up, one alert per blocking episode, straight
    /// away. An ongoing condition like the pause reminder: no baseline suppression and no outbox; a
    /// failed delivery is retried at the next observation.
    private func alertIfBlocked(installation: String, status: EngineStatus, generation: Int) async {
        // `remindIfPaused` may have awaited macOS: alerts switched off or a scope reset since then
        // cleared the key, and it must not be written back.
        guard generation == self.generation, self.enabled else { return }
        let stored = self.defaults.data(forKey: Self.compatibilityAlertKey)
            .flatMap { try? JSONDecoder().decode(CompatibilityRecord.self, from: $0) }
        guard
            var record = CompatibilityAlert.update(
                stored, installation: AlertScope.fingerprint(installation: installation),
                compatibility: status.compatibility, blockedSince: status.compatibilityBlockedSince)
        else {
            self.defaults.removeObject(forKey: Self.compatibilityAlertKey)
            return
        }
        self.saveCompatibilityRecord(record)
        guard CompatibilityAlert.due(record), !self.holdDelivery, self.enabled, self.allowed else { return }
        // A newer read that shows compatibility ready, or another episode, wins over this snapshot,
        // checked again just before the notification is submitted.
        let pending = record
        let stillBlocked = { [weak self] () -> Bool in
            guard let model = self?.model else { return false }
            return CompatibilityAlert.stillApplies(
                pending, latestVerified: model.statusVerified, latestCompatibility: model.status?.compatibility,
                latestBlockedSince: model.status?.compatibilityBlockedSince)
        }
        guard stillBlocked() else { return }
        let text = CompatibilityAlert.content()
        let content = AlertContent(
            title: text.title, body: text.body, slot: "", identifier: Self.compatibilityAlertIdentifier)
        guard await self.deliver(content, generation: generation, unless: stillBlocked) else { return }
        // Switched off or rescoped while macOS answered: the cleared key stays cleared.
        guard generation == self.generation, self.enabled,
            AlertScope.fingerprint(installation: installation) == self.armedInstallation
        else { return }
        record.announced = true
        self.saveCompatibilityRecord(record)
    }

    private func saveCompatibilityRecord(_ record: CompatibilityRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        self.defaults.set(data, forKey: Self.compatibilityAlertKey)
    }

    /// Adds an owed entry to the outbox (a slot already there is a no-op). False when the full outbox
    /// refused it; the caller then saves once and reports the refusal (`refused`).
    private func add(_ entry: PendingAlert) -> Bool {
        self.outbox = self.outbox.adding(entry)
        return self.outbox.contains(slot: entry.slot)
    }

    /// Saves the outbox and reports a storage problem (060-FIX6 item 1), clearing its own report once
    /// everything waiting is on disk again. With no private folder nothing can be saved.
    private func saveOutbox() {
        let saved = self.outboxStore?.save(self.outbox) ?? false
        self.storageIssue = self.outbox.issue(saved: saved, refused: self.refused)
        self.showStorageIssue()
    }

    /// Shows the storage problem, which outranks other alert issues; clears only its own report.
    private func showStorageIssue() {
        if let problem = self.storageIssue {
            self.issue = problem
        } else if self.issue == AlertOutbox.unsavedIssue {
            self.issue = nil
        }
    }

    /// Delivers what the outbox owes: the slots as one notification, then the notice, stopping at the
    /// first that cannot be shown.
    private func flush(generation: Int) async {
        for pending in self.outbox.deliveries {
            guard generation == self.generation, self.enabled, self.allowed else { return }
            let runs = RunTimes.make(status: self.model.status, projection: self.model.projection)
            guard let content = AlertComposer.content(for: pending, runs: runs) else { continue }
            guard await self.deliver(content, generation: generation) else { return }
        }
    }

    /// Persists how far this run has covered, for the next launch (F6): never past a slot still owed in
    /// the outbox or retained in the tracker. Never an ID.
    private func storeCoveredThrough() {
        guard let covered = self.outbox.capping(self.tracker.coveredThrough) else { return }
        self.defaults.set(covered, forKey: Self.coveredThroughKey)
    }

    /// Permission can be revoked between checks, or refused by `add` itself; `add` can also fail for
    /// other reasons. Whatever could not be shown stays in the outbox for the next observation or
    /// launch; only switching alerts off drops it. True after a successful `add`, which removes exactly
    /// the delivered entries, announces and releases exactly their slots, and stores the accepted list.
    /// `unless`, when given, is checked after the last await and just before submitting; false skips it.
    private func deliver(_ content: AlertContent, generation: Int, unless stillValid: (() -> Bool)? = nil) async
        -> Bool
    {
        let center = UNUserNotificationCenter.current()
        let authorization = await center.notificationSettings().authorizationStatus
        // A newer baseline owns these slots.
        guard generation == self.generation, self.enabled else { return false }
        guard authorization == .authorized || authorization == .provisional else {
            self.notAllowedNow()
            return false
        }
        if let stillValid, !stillValid() { return false }
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.userInfo = ["slot": content.slot]
        do {
            try await center.add(
                UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil))
            guard generation == self.generation, self.enabled else { return false }
            self.outbox = self.outbox.removing(slots: content.slots)
            self.saveOutbox()
            self.tracker.delivered(slots: content.slots)
            self.defaults.set(self.tracker.announced, forKey: Self.announcedKey)
            self.storeCoveredThrough()
            return true
        } catch {
            guard generation == self.generation, self.enabled else { return false }
            if (error as? UNError)?.code == .notificationsNotAllowed {
                self.notAllowedNow()
                return false
            }
            self.issue = "The last alert could not be shown: \(error.localizedDescription)"
            return false
        }
    }

    private func notAllowedNow() {
        self.allowed = false
        self.issue = Self.notAllowed
    }
}

extension AlertController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let slot = response.notification.request.content.userInfo["slot"] as? String
        Task { @MainActor in
            if let slot { self.openSlot?(slot) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
