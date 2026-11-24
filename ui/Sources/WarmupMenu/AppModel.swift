import AppKit
import Foundation
import ServiceManagement
import WarmupCore

/// Shared display state for the menu and the window. It owns only what it shows; every value
/// comes from a validated engine reply and is never written back.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var glance: Glance {
        didSet {
            // Announced here, not by a pane: a tab's view exists only once it has been shown.
            // Keyed by the problem, not the icon: a second missed time is announced too.
            let newProblem = self.glance.unseenProblemSlot.map { $0 != oldValue.unseenProblemSlot } ?? false
            let newlyStale =
                self.glance.symbolName == GlanceState.staleHeartbeatSymbol
                && oldValue.symbolName != GlanceState.staleHeartbeatSymbol
            if newProblem || newlyStale { Announcer.say(self.glance.headline) }
        }
    }
    @Published private(set) var status: EngineStatus?
    @Published private(set) var engineVersion: String?
    @Published private(set) var projection: ScheduleProjection?
    @Published private(set) var accounts: AccountList?
    @Published private(set) var accountsIssue: String?
    @Published private(set) var explanation: SlotExplanationResult?
    @Published private(set) var explanationIssue: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var readIssue: String?
    /// A failed `schedule inspect`, shown only on Schedule; status reads keep `readIssue`.
    @Published private(set) var projectionIssue: String?
    @Published private(set) var bindingIssue: BindingIssue?
    @Published private(set) var refreshing = false
    @Published var selectedSlot: String? {
        didSet { if self.selectedSlot != oldValue { self.selectedDetailFailed = false } }
    }
    // A6 operator actions. Only one runs at a time; nothing is queued or retried.
    @Published private(set) var mutating = false
    /// Set when an action is confirmed, before any wait, and held through its reconciling read:
    /// a second confirmation can never queue behind the first.
    @Published private(set) var actionPending = false
    @Published private(set) var reconcileRequired = false
    @Published private(set) var report: OperationReport?
    /// When the last result arrived; the result stays until dismissed or replaced.
    @Published private(set) var reportAt: Date?
    /// The last read that succeeded; with `readIssue` set, the values shown are from then.
    @Published private(set) var lastGoodRead: Date?
    /// The latest problem slot the operator has opened; the icon stops flagging it.
    private var acknowledgedSlot = UserDefaults.standard.string(forKey: AppModel.acknowledgedSlotKey) {
        didSet { UserDefaults.standard.set(self.acknowledgedSlot, forKey: Self.acknowledgedSlotKey) }
    }
    static let acknowledgedSlotKey = GlanceBuilder.acknowledgedSlotKey
    /// The one-time setup card: each question counts as answered once its switch has been changed
    /// or Done was pressed. The 0.5 Done flag (`setupCardAnswered`) still counts as both.
    @Published private(set) var alertsAnswered = AppModel.answered(AppModel.alertsAnsweredKey)
    @Published private(set) var loginAnswered = AppModel.answered(AppModel.loginAnsweredKey)
    static let alertsAnsweredKey = "setupAlertsAnswered"
    static let loginAnsweredKey = "setupLoginAnswered"
    static let legacySetupAnsweredKey = "setupCardAnswered"
    /// The engine's observation time from the last status reply (milliseconds).
    private(set) var lastObservedAt: Int?
    private var backgroundTimer: Timer?
    @Published private(set) var proposal: ProposedProjection?
    /// The schedule the proposal was computed against (same engine reply), for its New/removed marks.
    @Published private(set) var proposalBaseline: [ProjectedDay] = []
    /// When the schedule projection was last read successfully, and whether the latest try failed.
    @Published private(set) var projectionReadAt: Date?
    @Published private(set) var projectionStale = false
    /// The same for the Accounts list.
    @Published private(set) var accountsReadAt: Date?
    @Published private(set) var accountsStale = false
    /// True while the Schedule tab is on screen; a problem counts as seen only then.
    private(set) var scheduleVisible = false
    @Published private(set) var proposalEdit: ScheduleEdit?
    @Published private(set) var proposalIssue: String?
    // Read-only insights: the last seven days, wake readiness and short confirmations.
    @Published private(set) var week: [WeekDay] = []
    @Published private(set) var weekTruncated = false
    /// Increment C: seven-day outcomes from the same history read as the week strip.
    @Published private(set) var weekReport: WeekReport?
    /// The latest history read failed: `week` is fresh status plus `cachedHistory`, and no report.
    @Published private(set) var weekStale = false
    /// The last successful history read, kept so a failed read can still rebuild the strip.
    private var cachedHistory: (rows: [HistoryEntry], truncated: Bool, readAt: Int)?
    /// Sleep and wake times this app saw while running (NSWorkspace notifications).
    @Published private(set) var sleepJournal: SleepJournal
    private let journalStore: SleepJournalStore?
    /// Usage windows seen at each send, for "Did it help?" (kept only beside a verified binding).
    @Published private(set) var usageLog: UsageLog
    private let usageStore: UsageLogStore?
    private var sleepObservers: [NSObjectProtocol] = []
    @Published private(set) var wake: WakeReadiness = .unknown
    /// True when the Mac already has a repeating wake or power event; the suggested command replaces it.
    @Published private(set) var wakeRepeatExists = false
    @Published private(set) var copyConfirmation: String?
    @Published private(set) var launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    /// Registered, but macOS is waiting for the operator to allow it in System Settings.
    @Published private(set) var launchPending = SMAppService.mainApp.status == .requiresApproval
    @Published private(set) var launchIssue: String?
    /// Each new notice is announced, so a repeated refusal is announced again.
    @Published private(set) var overlapNotice: String? {
        didSet { if let notice = self.overlapNotice { Announcer.say(notice) } }
    }
    /// What the menu-bar item shows beside its icon (Settings: "Menu bar shows").
    @Published var menuBarMode = AppModel.loadMenuBarMode() {
        didSet { UserDefaults.standard.set(self.menuBarMode.rawValue, forKey: Self.menuBarModeKey) }
    }
    static let menuBarModeKey = "menuBarMode"
    /// The 0.5 countdown switch, read once to migrate to `menuBarMode` and then removed.
    static let legacyMenuBarCountdownKey = "menuBarCountdown"
    /// "Did it help?" (F1), recomputed when the usage log, accounts, count-from date or names change (P11).
    @Published private(set) var effect: EffectState?
    /// The "count from" day as picked ("yyyy-MM-dd"), or nil when not set.
    @Published private(set) var effectCountFromDay = UserDefaults.standard.string(forKey: AppModel.effectCountFromDayKey)
    static let effectCountFromDayKey = "effectCountFromDay"
    /// On-screen account labels by enrollment ID: nicknames unless hidden, otherwise "Account N" (F3).
    @Published private(set) var labels: [String: String] = [:]
    /// "Account N" per enrollment, shown beside nicknames and used in run results.
    @Published private(set) var accountNumbers: [String: String] = [:]
    @Published private(set) var accountNames: AccountNames
    private let namesStore: AccountNamesStore?
    @Published var hideAccountNames = UserDefaults.standard.bool(forKey: AppModel.hideAccountNamesKey) {
        didSet {
            guard self.hideAccountNames != oldValue else { return }
            UserDefaults.standard.set(self.hideAccountNames, forKey: Self.hideAccountNamesKey)
            self.recomputeLabels()
        }
    }
    static let hideAccountNamesKey = "hideAccountNames"
    /// Possible sends without a result the operator marked as reviewed (F8); hidden unless `showReviewed`.
    @Published private(set) var reviewedSends: ReviewedSends
    private let reviewedStore: ReviewedSendsStore?
    @Published var showReviewed = false
    /// A nickname or reviewed mark that could not be saved; the old value stays.
    @Published private(set) var saveIssue: String?
    /// Mirrors the alerts switch, for the setup card (`AlertController` reports it).
    @Published private(set) var alertsOn = false
    let editorInput = EditorInput()
    let vacationInput = VacationInput()
    private var proposalToken = 0
    /// Bumped once per completed copy, so each one is announced even when its text repeats.
    @Published private(set) var copySerial = 0
    private var explanationRequest = 0
    /// The last detail read for the current selection failed: the next refresh reads it again.
    private var selectedDetailFailed = false
    /// Counts successful status reads, so a check can tell a fresh reply from the cached one.
    private var statusReads = 0
    private var activeObserver: NSObjectProtocol?
    /// The one running refresh (P8); waiters await it instead of polling.
    private var inFlight: Task<Void, Never>?
    // ReadPlan inputs (F5): the status the last complete set of reads was planned from, its local
    // date, the visible tab and tabs that appeared since the last refresh.
    private var planBaseline: EngineStatus?
    private var planDay: String?
    private var visibleTab: VisibleTab = .none
    private var scheduleAppeared = false
    private var accountsAppeared = false
    private var lastList: Date?
    private var lastWake: Date?
    /// The installation of the last verified status, so alerts started late can observe it without a read.
    private var lastInstallation: String?

    private let client: EngineClient?
    /// Receives every validated status with its installation. Used only by opt-in alerts.
    var statusObserver: ((String, EngineStatus) -> Void)?
    /// The main window when it can host a confirmation sheet (visible, key, no sheet open) (X13).
    var sheetWindow: (() -> NSWindow?)?

    init(store: BindingStore?) {
        var issue: BindingIssue = .missing
        var client: EngineClient?
        if let store {
            do {
                let binding = try store.load()
                if let fileIssue = BindingVerifier.checkFiles(nodePath: binding.nodePath, scriptPath: binding.scriptPath) {
                    issue = fileIssue
                } else {
                    client = EngineClient(binding: binding)
                }
            } catch {
                issue = error
            }
        }
        self.client = client
        // The journal lives beside a verified binding only; its store re-checks the folder is private.
        self.journalStore = client == nil ? nil : store.map { SleepJournalStore(directory: $0.directory) }
        self.sleepJournal = self.journalStore?.load() ?? SleepJournal()
        self.usageStore = client == nil ? nil : store.map { UsageLogStore(directory: $0.directory) }
        self.usageLog = self.usageStore?.load() ?? UsageLog()
        self.namesStore = client == nil ? nil : store.map { AccountNamesStore(directory: $0.directory) }
        self.accountNames = self.namesStore?.load() ?? AccountNames()
        self.reviewedStore = client == nil ? nil : store.map { ReviewedSendsStore(directory: $0.directory) }
        self.reviewedSends = self.reviewedStore?.load() ?? ReviewedSends()
        self.bindingIssue = client == nil ? issue : nil
        self.glance = client == nil ? GlanceBuilder.setupRequired(issue) : GlanceBuilder.notChecked()
        self.activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLaunchAtLogin() }
        }
        self.recordPower(.launch)
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, kind) in [
            (NSWorkspace.willSleepNotification, SleepJournal.Kind.sleep), (NSWorkspace.didWakeNotification, .wake),
        ] {
            self.sleepObservers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.recordPower(kind)
                        // After a wake the icon must be right before anyone opens the menu.
                        if kind == .wake { Task { await self?.refreshAll() } }
                    }
                })
        }
        // One read at launch, so the menu-bar icon and Today line are right without a click.
        if client != nil { Task { await self.refreshAll() } }
    }

    /// `menuBarMode`, migrating the 0.5 countdown switch once and then removing its key.
    private static func loadMenuBarMode() -> MenuBarMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.menuBarModeKey), let mode = MenuBarMode(rawValue: raw) { return mode }
        let mode = MenuBarMode.migrated(oldCountdownSwitch: defaults.bool(forKey: Self.legacyMenuBarCountdownKey))
        defaults.set(mode.rawValue, forKey: Self.menuBarModeKey)
        defaults.removeObject(forKey: Self.legacyMenuBarCountdownKey)
        return mode
    }

    /// P10 step 1: a published value is assigned only when it changed, so views redraw only then.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private static func nowMilliseconds() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// The next background status read, from the latest status (`RefreshPlan`). Read-only.
    private func scheduleBackgroundRefresh(atMost limit: TimeInterval? = nil) {
        // An earlier check already planned (for example two minutes after a slot) is never pushed
        // back: read its time before replacing it.
        let pending = self.backgroundTimer.flatMap { $0.isValid ? $0.fireDate.timeIntervalSinceNow : nil }
        self.backgroundTimer?.invalidate()
        guard self.client != nil else { return }
        let planned = RefreshPlan.delay(
            nowMilliseconds: Self.nowMilliseconds(), status: self.status,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        var delay = limit.map { min($0, planned) } ?? planned
        if let pending { delay = min(delay, max(pending, 1)) }  // an overdue check runs at once
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        timer.tolerance = min(30, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.backgroundTimer = timer
    }

    /// The window reports whether the Schedule tab is visible; a loaded explanation shown then
    /// marks its problem as seen.
    func setScheduleVisible(_ visible: Bool) {
        let appeared = visible && !self.scheduleVisible
        self.scheduleVisible = visible
        if appeared { self.scheduleAppeared = true }
        // The detail on screen may be older than the problem: read it again, and acknowledge only
        // that fresh reply.
        if appeared, let slot = self.selectedSlot, slot == self.glance.unseenProblemSlot {
            Task { await self.explain(slot: slot) }
        }
    }

    /// The window reports the tab on screen (`.none` when it is closed or hidden). Schedule or
    /// Accounts appearing starts a refresh so their reads (`ReadPlan`) run at once.
    func setVisibleTab(_ tab: VisibleTab) {
        guard tab != self.visibleTab else { return }
        self.visibleTab = tab
        guard tab == .schedule || tab == .accounts else { return }
        if tab == .accounts { self.accountsAppeared = true }
        Task { await self.refreshAll() }
    }

    /// Marks the latest problem as seen once its explanation has loaded and is on screen.
    private func acknowledge(_ slot: String) {
        guard self.scheduleVisible, slot == self.glance.unseenProblemSlot, let status = self.status else { return }
        self.acknowledgedSlot = slot
        self.glance = GlanceBuilder.make(
            status: status, today: FriendlyTime.today(zone: status.schedule.zone), observedAt: self.lastObservedAt,
            acknowledgedSlot: slot, runs: RunTimes.make(status: status, projection: self.projection))
    }

    /// A failed read leaves the Schedule and Accounts rows from an earlier read on screen.
    private func markRowsStale() {
        self.assign(\.projectionStale, self.projection != nil)
        self.assign(\.accountsStale, self.accounts != nil)
    }

    /// The setup card shows until both questions are answered; a switch that is on counts as answered.
    var setupNeeded: Bool {
        SetupCard.needed(
            alertsAnswered: self.alertsAnswered, loginAnswered: self.loginAnswered, alertsOn: self.alertsOn,
            loginOn: self.launchAtLogin && !self.launchPending)
    }

    /// `AlertController` reports its switch, for the setup card.
    func setAlertsOn(_ on: Bool) { self.assign(\.alertsOn, on) }

    /// Re-delivers the last verified status to the alerts observer, so alerts allowed after the launch
    /// read can observe it without another read.
    func replayStatus() {
        guard self.bindingIssue == nil, self.readIssue == nil, let status, let installation = self.lastInstallation
        else { return }
        self.statusObserver?(installation, status)
    }

    // MARK: - Names, reviewed sends and the count-from date (F1, F3, F8)

    /// Possible sends without a result that have not been marked as reviewed.
    var visibleUnresolved: [UnresolvedReservation] { self.status.map { self.reviewedSends.visible($0.unresolved) } ?? [] }

    /// Possible sends already marked as reviewed, listed again with "Show reviewed".
    var reviewedUnresolved: [UnresolvedReservation] {
        self.status.map { self.reviewedSends.reviewed($0.unresolved) } ?? []
    }

    /// Saves a cleaned nickname (blank removes it). A failed save keeps the old names.
    func rename(account: String, to name: String) {
        let updated = self.accountNames.setting(name, for: account)
        guard updated != self.accountNames else { return }
        guard let store = self.namesStore, store.save(updated) else {
            self.saveIssue = "The name could not be saved."
            return
        }
        self.saveIssue = nil
        self.accountNames = updated
        self.recomputeLabels()
    }

    /// Marks every currently visible possible send as reviewed. Nothing is sent to the engine.
    func markReviewed() {
        let rows = self.visibleUnresolved
        guard !rows.isEmpty else { return }
        let updated = self.reviewedSends.marking(rows)
        guard let store = self.reviewedStore, store.save(updated) else {
            self.saveIssue = "The reviewed mark could not be saved."
            return
        }
        self.saveIssue = nil
        self.reviewedSends = updated
    }

    /// Sets or clears the "count from" day ("yyyy-MM-dd"). A day that is not a real date is ignored.
    func setCountFrom(_ day: String?) {
        if let day, EffectReport.countFromStart(day: day, zone: "UTC") == nil { return }
        guard day != self.effectCountFromDay else { return }
        self.effectCountFromDay = day
        UserDefaults.standard.set(day, forKey: Self.effectCountFromDayKey)
        self.recomputeEffect()
    }

    private var labelOrder: [String] {
        AccountNaming.order(
            status: self.status?.accounts.map(\.enrollmentId) ?? [],
            list: self.accounts?.rows.compactMap(\.enrollmentId) ?? [])
    }

    /// Labels follow status order, then accounts only in the Accounts list; the effect rows use them.
    private func recomputeLabels() {
        let order = self.labelOrder
        self.assign(\.accountNumbers, AccountNaming.numbers(order: order))
        self.assign(\.labels, AccountNaming.labels(order: order, names: self.accountNames, hidden: self.hideAccountNames))
        self.recomputeEffect()
    }

    /// "Did it help?" from the usage log, counted from the chosen day in the schedule zone when set.
    private func recomputeEffect() {
        guard let status, self.bindingIssue == nil else {
            self.assign(\.effect, nil)
            return
        }
        let now = Self.nowMilliseconds()
        let zone = status.schedule.zone
        let order = status.accounts.map(\.enrollmentId)
        let countFrom = self.effectCountFromDay.flatMap { EffectReport.countFromStart(day: $0, zone: zone) }
        let summary = EffectReport.summary(self.usageLog, order: order, now: now, countFrom: countFrom)
        let label = countFrom.map { EffectReport.countFromLabel(ms: $0, zone: zone, now: now) }
        let rows = EffectReport.rows(
            log: self.usageLog, order: order, labels: self.labels, countFrom: countFrom, now: now, zone: zone)
        self.assign(
            \.effect,
            EffectState(
                summary: summary, rows: rows, countFromLabel: label,
                progress: EffectProgress.text(clear: summary.clear, countFromLabel: label),
                progressFraction: EffectProgress.fraction(clear: summary.clear),
                decision: EffectDecision.make(counts: summary.counts, total: summary.total, countFrom: countFrom)))
    }

    /// Today's marks for the schedule zone's date at `now`, each with the slot it opens; nil while the
    /// kept projection cannot speak for that date ("Schedule not available"). Derived when shown, so
    /// the marks, the availability check and the click target share one date (060-FIX4 item 3).
    func todayMarks(at now: Date = Date()) -> [TodayMark]? {
        guard let status else { return nil }
        return TodayMark.marks(
            projection: self.projection, status: status, week: self.week,
            today: FriendlyTime.today(zone: status.schedule.zone, now: now),
            now: Int(now.timeIntervalSince1970 * 1000))
    }

    private static func answered(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key) || UserDefaults.standard.bool(forKey: Self.legacySetupAnsweredKey)
    }

    /// Done answers both questions.
    func answerSetup() {
        self.answerAlerts()
        self.answerLogin()
    }

    func answerAlerts() {
        guard !self.alertsAnswered else { return }
        self.alertsAnswered = true
        UserDefaults.standard.set(true, forKey: Self.alertsAnsweredKey)
    }

    func answerLogin() {
        guard !self.loginAnswered else { return }
        self.loginAnswered = true
        UserDefaults.standard.set(true, forKey: Self.loginAnsweredKey)
    }

    /// Speaks a short message to VoiceOver (results, alert issues), whichever pane is loaded.
    func announce(_ text: String) { Announcer.say(text) }

    func batchNote(for slot: String) -> String? { self.status.flatMap { BatchNote.text(status: $0, slot: slot) } }

    func dismissReport() {
        self.report = nil
        self.reportAt = nil
    }

    private func recordPower(_ kind: SleepJournal.Kind) {
        self.sleepJournal.record(kind, at: Int(Date().timeIntervalSince1970 * 1000))
        self.journalStore?.save(self.sleepJournal)
    }

    /// For a not-admitted slot whose admission minute this app recorded the Mac asleep through.
    /// The minute comes from the ledger row recorded with the miss (its own admission and zone), so
    /// a later schedule or zone change cannot shift it; without that row there is no note.
    func sleepNote(for explanation: SlotExplanation, zone: String) -> String? {
        guard explanation.notAdmitted != nil,
            let row = self.status?.slotLedger.first(where: { $0.slot == explanation.slot }),
            let at = LedgerInstant.admissionAt(row)
        else { return nil }
        return self.sleepJournal.explanation(admissionAt: at, zone: zone)
    }

    var isBound: Bool { self.client != nil }
    /// The shown status came from the newest read through a verified binding (no read or binding issue),
    /// and no action (a resume, say) is running or awaiting its follow-up read, which could change it.
    var statusVerified: Bool {
        self.bindingIssue == nil && self.readIssue == nil && self.status != nil && !self.mutating
            && !self.actionPending
    }

    /// Why the action buttons are dimmed, in words, or nil when they are available.
    var controlsUnavailableReason: String? {
        if let issue = self.bindingIssue { return issue.description }
        if self.client == nil { return "Setup required: no verified engine binding." }
        if self.mutating || self.actionPending { return "A change is running." }
        if self.reconcileRequired { return "The last change has an unknown outcome. Refresh first." }
        if let issue = self.readIssue { return "The last read failed (\(issue)). Refresh to try again." }
        if self.status == nil { return "Status has not been read yet. Refresh first." }
        return nil
    }

    /// The latest usage evidence for an enrollment, from the last status read.
    func usageLine(enrollmentId: String?) -> String? {
        guard let enrollmentId, let status = self.status,
            let usage = status.accounts.first(where: { $0.enrollmentId == enrollmentId })?.usage
        else { return nil }
        return UsageSummary.line(usage, zone: status.schedule.zone, now: Int(Date().timeIntervalSince1970 * 1000))
    }

    /// True when the verified engine advertises `feature` (Increment B controls need engine 1.2).
    func supports(_ feature: String) -> Bool {
        self.bindingIssue == nil && self.status?.capability?.features.contains(feature) == true
    }

    /// Confirms and saves one Increment B setting with the current revision and local date.
    func setting(_ setting: ScheduleSetting, account: String? = nil) {
        guard let status = self.status else { return }
        let date = setting.usesLocalDate ? FriendlyTime.today(zone: status.schedule.zone) : nil
        if setting.usesLocalDate, date == nil { return }
        let action = WarmupAction.setting(setting, expectedRevision: status.scheduleRevision, expectedLocalDate: date)
        self.request(action, account: account)
    }

    func addVacation(from start: Date, to end: Date) {
        guard let zone = self.status?.schedule.zone else { return }
        let timeZone = TimeZone(identifier: zone) ?? .current
        let (from, to) = (ClockTime.day(from: start, zone: timeZone), ClockTime.day(from: end, zone: timeZone))
        guard from <= to else { return }
        self.setting(.exclude(start: from, end: to))
    }

    /// Whether scheduled batches include this enrollment (every enabled one when no list is saved).
    func isScheduled(_ enrollment: String) -> Bool {
        self.status?.scheduledAccounts?.contains(enrollment) ?? true
    }

    /// Sets one account to the value the checkbox asked for (never a flip of what was last read).
    /// The first removal turns "all" into an explicit list; re-adding the last missing enabled
    /// account returns to "all". The engine applies it under its lock with the revision guard.
    func setScheduled(_ enrollment: String, to wanted: Bool, account: String) {
        guard let status = self.status,
            let change = ScheduledAccounts.change(
                enrollment, scheduled: wanted, current: status.scheduledAccounts,
                enabled: ScheduledAccounts.allEnabled(status))
        else { return }
        self.setting(change, account: account)
    }

    /// The label for an account without usage evidence: never observed, or left out of the reply.
    var usageMissingLabel: String {
        self.status?.usageTruncated == true ? "Not observed, or left out of a large reply" : "Not observed"
    }

    /// Controls are offered only for a verified binding, a current status, no running change and
    /// no unreconciled unknown outcome. A background read does not dim them: an action waits for
    /// it to finish. The engine still revalidates everything under its locks.
    var controlsAvailable: Bool { self.controlsReady && !self.actionPending }

    /// Everything but the action reservation, for the reserved action's own checks.
    private var controlsReady: Bool {
        self.client != nil && self.bindingIssue == nil && self.status != nil && self.readIssue == nil && !self.mutating
            && !self.reconcileRequired
    }

    /// Waits until no refresh is running (P8: one stored task, no polling).
    private func waitForRefresh() async {
        while let running = self.inFlight { await running.value }
    }

    /// A status read alone, through the same one-at-a-time guard as `refresh` but without the planned
    /// reads, so the Run Anyway recheck compares a status nothing else waited behind (060-FIX1 item 1).
    /// Busy or no client: no read, so `statusReads` stays unchanged and the caller refuses.
    private func readStatusOnly() async {
        guard let client else { return }
        await self.waitForRefresh()
        guard self.inFlight == nil, !self.mutating else { return }
        let job = Task {
            await self.readStatus(client)
            self.inFlight = nil
            self.assign(\.refreshing, false)
        }
        self.inFlight = job
        self.assign(\.refreshing, true)
        await job.value
    }

    /// Read-only history from `since` (engine milliseconds), for alerts. Nil when it cannot be
    /// read or the engine is shown read-only after a binding mismatch.
    func readHistory(since milliseconds: Int) async -> HistoryReport? {
        guard let client, self.bindingIssue == nil else { return nil }
        let command = EngineCommand.history(account: nil, since: AlertTracker.historySince(milliseconds))
        guard case let .success(reply) = await client.read(command, as: HistoryReport.self),
            reply.envelope.outcome == "ready", let report = reply.payload
        else { return nil }
        return report
    }

    /// Status, then only the reads `ReadPlan` says can have changed. Every status read goes through
    /// here (timers, menu, wake, alerts), so the plan always compares with the status it last used.
    /// Busy: a background retry is planned shortly; a forced refresh first waits for the running one.
    /// The client rejects any reply from a different installation, so views cannot mix installations.
    func refreshAll(force: Bool = false) async { await self.refresh(force: force, afterChange: false) }

    private func refresh(force: Bool, afterChange: Bool) async {
        guard let client else { return }
        if force || afterChange { await self.waitForRefresh() }
        guard self.inFlight == nil, !self.mutating else {
            // Busy now: try again shortly, so a skipped background read never leaves the icon stale.
            self.scheduleBackgroundRefresh(atMost: 30)
            return
        }
        let job = Task {
            await self.runReads(client, force: force, afterChange: afterChange)
            // Cleared inside the task, so a waiter that resumes never sees a finished job.
            self.inFlight = nil
            self.assign(\.refreshing, false)
        }
        self.inFlight = job
        self.assign(\.refreshing, true)
        await job.value
    }

    private func runReads(_ client: EngineClient, force: Bool, afterChange: Bool) async {
        guard await self.readStatus(client), let current = self.status else {
            self.planBaseline = nil  // the next good read reads everything again
            return
        }
        let today = FriendlyTime.today(zone: current.schedule.zone)
        let context = ReadContext(
            visibleTab: self.visibleTab, scheduleBecameVisible: self.scheduleAppeared,
            accountsBecameVisible: self.accountsAppeared, afterChange: afterChange, force: force,
            lastList: self.lastList, lastWake: self.lastWake, now: Date(), localDateChanged: today != self.planDay,
            selectedSlotInProgress: self.selectedSlot != nil && self.selectedSlot == current.activeBatch?.slot,
            hasSelectedSlot: self.selectedSlot != nil, selectedDetailFailed: self.selectedDetailFailed)
        self.scheduleAppeared = false
        self.accountsAppeared = false
        let reads = ReadPlan.reads(previous: self.planBaseline, current: current, context: context)
        var complete = true
        if reads.contains(.inspect) { complete = await self.loadProjection(client) && complete }
        if reads.contains(.list) { complete = await self.loadAccounts(client) && complete }
        self.dropStaleProposal()
        if reads.contains(.history) { complete = await self.loadWeek(client) && complete }
        if reads.contains(.wake) {
            await self.checkWake()
            self.lastWake = Date()
        }
        if reads.contains(.slotDetail), let slot = self.selectedSlot { await self.loadExplanation(client, slot: slot) }
        // A failed read is retried next time: without a baseline the plan reads everything.
        self.planBaseline = complete ? current : nil
        self.planDay = today
    }

    /// `schedule inspect`. Returns false when it failed (the last good projection stays, marked stale).
    private func loadProjection(_ client: EngineClient) async -> Bool {
        switch await client.read(.scheduleInspect, as: ScheduleProjection.self) {
        case let .success(reply):
            // A busy or blocked reply has no schedule: keep the last good one and say why.
            guard reply.envelope.outcome == "ready", let projection = reply.payload else {
                self.assign(\.projectionIssue, "Schedule not available: \(Wording.reason(reply.envelope.reason))")
                self.assign(\.projectionStale, self.projection != nil)
                return false
            }
            self.assign(\.projection, projection)
            self.projectionReadAt = Date()
            self.assign(\.projectionStale, false)
            self.assign(\.projectionIssue, nil)
            return true
        case let .failure(issue):
            self.assign(\.projectionIssue, "Schedule could not be read: \(issue.description)")
            self.assign(\.projectionStale, self.projection != nil)
            return false
        }
    }

    /// `list`. Returns false when it failed; no stale rows are kept with live actions.
    private func loadAccounts(_ client: EngineClient) async -> Bool {
        defer { self.recomputeLabels() }
        switch await client.read(.list, as: AccountList.self) {
        case let .success(reply):
            let ready = reply.envelope.outcome == "ready"
            self.assign(\.accounts, ready ? reply.payload : nil)
            if ready {
                self.accountsReadAt = Date()
                self.lastList = Date()
            }
            self.assign(\.accountsStale, false)
            self.assign(\.accountsIssue, ready ? nil : "Accounts unavailable: \(Wording.code(reply.envelope.reason))")
            return ready
        case let .failure(issue):
            self.assign(\.accounts, nil)
            self.assign(\.accountsStale, false)
            self.assign(\.accountsIssue, issue.description)
            return false
        }
    }

    /// Read-only `history` for the last seven days, summarized per slot for the week strip.
    /// Returns false when the read failed.
    private func loadWeek(_ client: EngineClient) async -> Bool {
        guard let status = self.status, self.bindingIssue == nil, let today = FriendlyTime.today(zone: status.schedule.zone)
        else { return true }  // nothing to read for an unverified engine
        let since = Int(Date().addingTimeInterval(-8 * 86_400).timeIntervalSince1970 * 1000)
        let command = EngineCommand.history(account: nil, since: AlertTracker.historySince(since))
        guard case let .success(reply) = await client.read(command, as: HistoryReport.self),
            reply.envelope.outcome == "ready", let report = reply.payload
        else {
            // A failed read leaves no report: an older one would be copied as if it were current.
            self.assign(\.weekReport, nil)
            // The strip still follows fresh status; earlier days come from the last good read, or
            // from none when no read has succeeded yet.
            let rows = self.cachedHistory?.rows ?? []
            let truncated = self.cachedHistory?.truncated ?? false
            let week = WeekSummary.make(today: today, status: status, history: rows, truncated: truncated)
            self.assign(\.weekTruncated, truncated)
            self.assign(\.week, week)
            self.assign(\.weekStale, true)
            return false
        }
        let truncated = report.truncated == true
        let week = WeekSummary.make(today: today, status: status, history: report.rows, truncated: truncated)
        self.cachedHistory = (report.rows, truncated, Self.nowMilliseconds())
        self.assign(\.weekStale, false)
        self.assign(\.weekTruncated, truncated)
        self.assign(\.week, week)
        self.assign(
            \.weekReport,
            WeekReport.make(
                week: week, status: status, history: report.rows, truncated: truncated,
                asOf: Self.nowMilliseconds()))
        return true
    }

    /// Reads the system's scheduled wakes (`/usr/bin/pmset -g sched`, read-only) against the next
    /// slot in Mac local time. Any failure leaves the readiness unknown.
    private func checkWake() async {
        guard let status = self.status, let next = status.next,
            let due = Countdown.date(of: next, zone: status.schedule.zone)
        else {
            self.assign(\.wake, .unknown)
            return
        }
        // Mac local time, POSIX digits: pmset prints the Mac's own clock.
        let parts = [ClockTime.day(from: due, zone: .current), ClockTime.string(from: due, zone: .current)]
        let output = try? await ProcessRunner().run(
            executable: "/usr/bin/pmset", arguments: ["-g", "sched"], environment: ["PATH": "/usr/bin:/bin", "LANG": "C"],
            workingDirectory: "/", timeout: .seconds(3), terminateOnOverflow: true)
        guard let output, output.exitCode == 0, !output.timedOut, parts.count == 2,
            let text = String(data: output.stdout, encoding: .utf8)
        else {
            self.assign(\.wake, .unknown)
            return
        }
        self.assign(\.wake, WakeReadiness.assess(pmset: text, date: parts[0], admission: parts[1]))
        self.assign(\.wakeRepeatExists, WakeReadiness.hasRepeating(pmset: text))
    }

    /// The next slot's admission time in Mac local time, for wake guidance.
    var nextLocalAdmission: String? {
        guard let status = self.status, let next = status.next else { return nil }
        return ClockTime.localAdmission(next, scheduleZone: status.schedule.zone)
    }

    /// Selects a slot from the menu's Today line (060-FIX5 item 4). When the kept projection is of
    /// another day, it is read again first (the existing inspect read), so Schedule never labels an
    /// older day "Today".
    func showDay(slot: String) async {
        if self.projection?.localDate != String(slot.prefix(10)), let client, !self.mutating {
            _ = await self.loadProjection(client)
        }
        await self.explain(slot: slot)
    }

    func explain(slot: String) async {
        self.selectedSlot = slot
        // The previous slot's detail (and its Copy button) goes away at once.
        self.explanation = nil
        self.explanationIssue = nil
        guard let client else { return }
        await self.loadExplanation(client, slot: slot)
    }

    // MARK: - Operator actions

    /// Asks for explicit confirmation when the action needs it, then performs the action once.
    /// `confirmed` runs when it went ahead. With the main window visible and key the question is a
    /// sheet on it (X13); otherwise an app-modal dialog. Either way the answer comes before anything
    /// is reserved or performed.
    func request(
        _ operation: WarmupAction, account: String? = nil, recheck: (@MainActor () async -> Bool)? = nil,
        confirmed: (@MainActor () -> Void)? = nil
    ) {
        guard self.controlsAvailable, let status = self.status else { return }
        guard operation.needsConfirmation else {
            if self.reserveAndPerform(operation, recheck: recheck) { confirmed?() }
            return
        }
        let alert = Self.confirmation(for: operation, status: status, account: account)
        if let window = self.sheetWindow?() {
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    // Other actions may have been confirmed while the sheet was open; reserve first.
                    guard response == .alertFirstButtonReturn, let self,
                        self.reserveAndPerform(operation, recheck: recheck)
                    else { return }
                    confirmed?()
                }
            }
            return
        }
        // An accessory app must come forward first, or the dialog can open behind other windows
        // without keyboard or VoiceOver focus.
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The modal dialog runs its own event loop, so another action may have been confirmed
        // meanwhile; reserve before anything asynchronous happens.
        if self.reserveAndPerform(operation, recheck: recheck) { confirmed?() }
    }

    /// The confirmation dialog. Cancel is the default (Return) button: a stray keypress never confirms.
    private static func confirmation(for operation: WarmupAction, status: EngineStatus, account: String?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = operation.title + "?"
        alert.informativeText = Confirmation.text(for: operation, enabledAccounts: status.enabled, pilots: status.pilots, account: account)
        alert.alertStyle = operation.sendsRequests ? .warning : .informational
        let confirm = alert.addButton(withTitle: operation.confirmLabel)
        let cancel = alert.addButton(withTitle: "Cancel")
        confirm.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.layout()
        alert.window.initialFirstResponder = cancel
        return alert
    }

    private func reserveAndPerform(_ operation: WarmupAction, recheck: (@MainActor () async -> Bool)?) -> Bool {
        guard self.controlsAvailable else { return false }
        self.actionPending = true
        Task {
            if let recheck, await !recheck() {
                self.actionPending = false
                return
            }
            await self.perform(operation, reserved: true)
        }
        return true
    }

    /// Runs one confirmed action. Without a reservation from `request`, it takes one itself.
    func perform(_ operation: WarmupAction, reserved: Bool = false) async {
        if !reserved {
            guard self.controlsAvailable else { return }
            self.actionPending = true
        }
        defer { self.actionPending = false }
        // A background read may be running: wait for it, then check again before changing anything.
        await self.waitForRefresh()
        guard let client, self.controlsReady else { return }
        self.mutating = true
        let report: OperationReport
        switch operation {
        case .runAll, .runAccount:
            // Numbers only: a result stays on screen, and Hide account names may be turned on later.
            let labels = self.accountNumbers
            report = Self.makeReport(operation, await client.mutate(operation.command, as: RunReply.self)) {
                OperationReporter.run(operation, envelope: $0, reply: $1, labels: labels)
            }
        case .enroll:
            report = Self.makeReport(operation, await client.mutate(operation.command, as: EnrollReply.self)) { OperationReporter.change(operation, envelope: $0, reply: nil, enrolled: $1) }
        case .pause, .resume, .saveEdit, .setting:
            report = Self.makeReport(operation, await client.mutate(operation.command, as: ScheduleChangeReply.self)) { OperationReporter.change(operation, envelope: $0, reply: $1) }
        }
        // Read the client's flag before reopening controls, so there is no gap with stale state.
        self.reconcileRequired = await client.reconcileRequired
        self.mutating = false
        self.report = report
        self.reportAt = Date()
        self.overlapNotice = nil  // an older override notice never sits beside a newer result
        Announcer.say("Result: \(report.headline)")
        if case .saveEdit = operation, report.kind != .busy { self.discardProposal() }
        if report.kind == .unknown { self.discardProposal() }
        // Never skipped (it waits for a running read): a fresh read reconciles an unknown outcome
        // before any new action.
        await self.refresh(force: false, afterChange: true)
        self.reconcileRequired = await client.reconcileRequired
    }

    private static func makeReport<Payload>(
        _ operation: WarmupAction, _ result: Result<EngineReply<Payload>, ClientIssue>, build: (Envelope, Payload) -> OperationReport
    ) -> OperationReport {
        switch result {
        case let .failure(issue):
            switch issue {
            case .mutationOutcomeUnknown: return OperationReporter.unknown(operation, issue: issue)
            default: return OperationReporter.refused(operation, issue: issue)
            }
        case let .success(reply):
            guard let payload = reply.payload else { return OperationReporter.unknown(operation, issue: .malformedOutput) }
            return build(reply.envelope, payload)
        }
    }

    /// Read-only preview of an edit with the engine's own validator. Nothing is saved.
    func preview(_ edit: ScheduleEdit) async {
        guard let client, !self.mutating else { return }
        self.discardProposal()
        let token = self.proposalToken
        let result = await client.read(.scheduleInspectProposal(edit), as: ProposalReply.self)
        guard token == self.proposalToken, !self.mutating else { return } // superseded by a save or discard
        switch result {
        case let .success(reply):
            if let proposal = reply.payload?.proposal, reply.envelope.outcome == "ready" {
                self.proposal = proposal
                self.proposalBaseline = reply.payload?.days ?? []
                self.proposalEdit = edit
                self.proposalIssue = nil
            } else {
                self.proposalIssue = "Not valid: \(Wording.code(reply.envelope.reason))"
            }
        case let .failure(issue): self.proposalIssue = issue.description
        }
    }

    func saveProposal() {
        guard let proposal = self.proposal, let edit = self.proposalEdit else { return }
        self.request(.saveEdit(edit, expectedRevision: proposal.expectedRevision, expectedLocalDate: proposal.localDate))
    }

    func discardProposal() {
        self.proposalToken &+= 1
        self.proposal = nil
        self.proposalBaseline = []
        self.proposalEdit = nil
        self.proposalIssue = nil
    }

    /// A proposal is only saveable while the observed revision and local date still match it.
    private func dropStaleProposal() {
        guard let proposal = self.proposal else { return }
        let revisionMoved = self.status.map { $0.scheduleRevision != proposal.expectedRevision } ?? true
        // A stale projection (kept after a failed read) cannot say the date moved; the engine
        // still refuses a save whose expected date has passed.
        let shownDate = self.projectionStale ? nil : self.projection?.localDate
        let dateMoved = shownDate.map { $0 != proposal.localDate } ?? false
        if revisionMoved || dateMoved {
            self.discardProposal()
            self.proposalIssue = "The schedule or date changed since the preview. Preview again."
        }
    }

    func copyDiagnostic() {
        guard let explanation else { return }
        self.copy(SlotDiagnostic.text(explanation, engineVersion: self.engineVersion), confirmation: "Warm-up summary copied")
    }

    /// Copies a redacted summary of the whole status: codes, counts and local times only.
    func copyStatusDiagnostic() {
        // A mismatched engine is shown read-only; its text is not trusted enough to copy.
        guard let status, self.bindingIssue == nil else { return }
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.copy(
            StatusDiagnostic.text(status, engineVersion: self.engineVersion, appVersion: app, observedAt: Date()),
            confirmation: "Status summary copied")
    }

    /// "Warm-up 0.5.1 (6) · Engine 1.2.0" for Settings; "dev" for a bare build.
    var versionLine: String {
        VersionText.line(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            engineVersion: self.engineVersion)
    }

    /// Copies the effect report: counts, progress and per-send lines with accounts numbered, never named.
    func copyEffectReport() {
        guard let effect else { return }
        self.copy(
            EffectReport.text(effect.summary, rows: effect.rows, countFromLabel: effect.countFromLabel),
            confirmation: "Effect report copied")
    }

    /// Copies the seven-day report with accounts numbered instead of named.
    func copyWeekReport() {
        guard let weekReport, let zone = self.status?.schedule.zone, self.bindingIssue == nil, self.readIssue == nil
        else { return }
        self.copy(weekReport.text(zone: zone), confirmation: "Weekly report copied")
    }

    private func copy(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self.copySerial &+= 1
        let token = self.copySerial
        // Announced here, once per copy, whichever pane the Copy button is on.
        Announcer.say(confirmation)
        self.copyConfirmation = confirmation
        Task {
            try? await Task.sleep(for: .seconds(3))
            if token == self.copySerial { self.copyConfirmation = nil }
        }
    }

    /// Copies text the operator asked for (a suggested command), with a short confirmation.
    func copyText(_ text: String, confirmation: String) { self.copy(text, confirmation: confirmation) }

    /// "Run anyway" for an overlap refusal: reads status again and asks for confirmation only if
    /// the refused slot is still the next one; otherwise the stale offer is withdrawn.
    /// The check runs twice: before the confirmation dialog, and again after the operator confirms,
    /// so a dialog left open while another slot becomes next never sends the override. The engine
    /// must support `scoped_slot_overlap`, which also refuses the override if another slot became
    /// next; an engine without it gets no override at all.
    func runAnyway(_ report: OperationReport) async {
        guard let overlap = report.overlap else { return }
        // An unscoped override would cover whichever slot is next when the engine takes its lock:
        // without the refused slot's instant nothing is sent and no confirmation is shown.
        guard let at = overlap.at else { return self.refuseUnscopedOverride() }
        guard await self.overlapStillApplies(overlap, zone: nil) else { return }
        guard self.status?.capability?.features.contains("scoped_slot_overlap") == true else {
            return self.refuseUnscopedOverride()
        }
        // The zone seen now must still be the zone after confirmation: a zone change can keep the
        // same slot ID, date and time while moving the real admission.
        let zone = self.status?.schedule.zone
        self.overlapNotice = nil
        let operation: WarmupAction
        var account: String?
        switch report.operation {
        case let .runAccount(id, _, _):
            operation = .runAccount(enrollmentId: id, allowSlotOverlap: true, overlapAt: at)
            account = self.labels[id]
        default: operation = .runAll(allowSlotOverlap: true, overlapAt: at)
        }
        self.request(operation, account: account) { [weak self] in await self?.overlapStillApplies(overlap, zone: zone) ?? false }
    }

    private func refuseUnscopedOverride() {
        self.overlapNotice =
            "This engine cannot limit the override to one time, so it was not sent. "
            + "Wait until the scheduled warm-up has run."
    }

    /// Requires a fresh, successful status read (never the cached one), then compares the slot.
    private func overlapStillApplies(_ overlap: OverlapSlot, zone: String?) async -> Bool {
        // A change cannot be running: Run Anyway is offered only while controls are available.
        let before = self.statusReads
        await self.readStatusOnly()
        // Fresh, successful, and still a verified engine with controls open; otherwise `perform`
        // would refuse silently after the operator confirmed.
        guard self.statusReads != before, self.readIssue == nil, self.controlsReady else {
            self.report = nil
            if let issue = self.bindingIssue {
                self.overlapNotice = "The override was not sent: \(issue.description)."
            } else if self.statusReads == before || self.readIssue != nil {
                self.overlapNotice =
                    "Status could not be read again, so the override was not sent. Warm up again to recheck."
            } else {
                self.overlapNotice =
                    "The override was not sent: controls are unavailable. Refresh and check the status."
            }
            return false
        }
        let sameZone = zone == nil || self.status?.schedule.zone == zone
        guard sameZone, OverlapOverride.stillApplies(overlap, next: self.status?.next) else {
            self.report = nil
            self.overlapNotice = "The time that warning named is no longer next. Warm up again to recheck."
            return false
        }
        return true
    }

    /// Opens Warm-up at login. The switch registers this app bundle with macOS Login Items; the
    /// operator can also remove it in System Settings.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            self.launchIssue = nil
        } catch {
            self.launchIssue = "Login item could not be changed: \(error.localizedDescription)"
        }
        self.readLaunchAtLogin()
        // Answered once the change took effect; a registration still awaiting approval in System
        // Settings keeps the card (Done still dismisses it).
        if self.launchIssue == nil, !self.launchPending { self.answerLogin() }
    }

    /// Rereads the Login Items registration (also when the app becomes active, since the operator
    /// can approve or remove it in System Settings). A registration awaiting approval shows as on,
    /// so the switch can still withdraw it.
    func readLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            self.launchAtLogin = true
            self.launchPending = false
            self.answerLogin()  // on, including after approval in System Settings
        case .requiresApproval:
            self.launchAtLogin = true
            self.launchPending = true
        default:
            self.launchAtLogin = false
            self.launchPending = false
        }
    }

    /// "Today 12:31" in the schedule zone (the Mac's when no status has been read).
    func localDateTime(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "Unknown" }
        return FriendlyTime.instant(milliseconds, zone: self.status?.schedule.zone ?? TimeZone.current.identifier)
    }

    /// "History could not be read; earlier days are from Today 13:02." while the strip is stale, or
    /// "History could not be read." when no read has succeeded yet.
    var weekStaleLine: String? {
        guard self.weekStale, let zone = self.status?.schedule.zone else { return nil }
        return WeekStaleText.line(readAt: self.cachedHistory?.readAt, zone: zone)
    }

    /// A Mac-local time shown the same way, for app-side times such as the last check.
    func friendly(_ date: Date?) -> String {
        guard let date else { return "never" }
        return FriendlyTime.instant(Int(date.timeIntervalSince1970 * 1000), zone: TimeZone.current.identifier)
    }

    @discardableResult
    private func readStatus(_ client: EngineClient) async -> Bool {
        let result = await client.read(.status, as: EngineStatus.self)
        self.lastChecked = Date()  // once per refresh: every refresh reads status exactly once
        defer { self.scheduleBackgroundRefresh() }
        switch result {
        case let .failure(issue):
            self.assign(\.readIssue, issue.description)
            self.markRowsStale()
            self.assign(\.weekReport, nil)
            self.assign(\.glance, GlanceBuilder.unavailable(issue.description))
            await client.setCapability(nil)
            return false
        case let .success(reply):
            guard reply.envelope.outcome == "ready", let status = reply.payload else {
                self.assign(\.readIssue, "Engine reported \(Wording.code(reply.envelope.reason))")
                self.markRowsStale()
                self.assign(\.weekReport, nil)
                self.assign(\.glance, GlanceBuilder.unavailable(Wording.code(reply.envelope.reason)))
                await client.setCapability(nil)
                return false
            }
            self.assign(\.status, status)
            self.lastGoodRead = Date()
            self.statusReads &+= 1
            self.assign(\.engineVersion, reply.envelope.engineVersion)
            self.assign(\.readIssue, nil)
            self.assign(\.bindingIssue, BindingVerifier.compare(client.binding, envelope: reply.envelope, status: status))
            // A verified read reconciles an unknown outcome even when it is not the first read after it.
            if self.bindingIssue == nil { self.assign(\.reconcileRequired, await client.reconcileRequired) }
            // A mismatched engine is still shown, read-only, but no further command is offered.
            await client.setCapability(self.bindingIssue == nil ? status.capability : nil)
            self.lastObservedAt = HeartbeatCheck.milliseconds(iso8601: reply.envelope.observedAt)
            // A detail read while its batch was running, or before its time came, is read again once
            // the batch has ended (the plan reads the detail only while its batch runs).
            if let shown = self.explanation?.explanation, shown.slot == self.selectedSlot,
                status.activeBatch?.slot != shown.slot,
                shown.verdict == "in_progress"
                    || (shown.verdict == "scheduled" && (status.lastSlotOutcome?.slot ?? "") >= shown.slot)
            {
                Task { await self.explain(slot: shown.slot) }
            }
            self.assign(
                \.glance,
                GlanceBuilder.make(
                    status: status, today: FriendlyTime.today(zone: status.schedule.zone),
                    observedAt: self.lastObservedAt, acknowledgedSlot: self.acknowledgedSlot,
                    runs: RunTimes.make(status: status, projection: self.projection)))
            // Alerts observe only a verified engine, never one shown read-only after a mismatch.
            self.lastInstallation = self.bindingIssue == nil ? reply.envelope.installationId : nil
            if self.bindingIssue == nil, let installation = reply.envelope.installationId {
                self.statusObserver?(installation, status)
            }
            // Recorded on a copy, so the published log changes only when a row was added.
            var log = self.usageLog
            if self.bindingIssue == nil, log.record(status.accounts, now: Self.nowMilliseconds()) {
                self.usageLog = log
                self.usageStore?.save(log)
            }
            self.recomputeLabels()  // also recomputes "Did it help?"
            return true
        }
    }

    private func loadExplanation(_ client: EngineClient, slot: String) async {
        self.explanationRequest &+= 1
        let request = self.explanationRequest
        let result = await client.read(.scheduleInspectSlot(slot), as: SlotExplanationResult.self)
        // Only the newest request may fill the detail: an older reply for the same slot (A, B, A)
        // or for another slot is dropped.
        guard request == self.explanationRequest, self.selectedSlot == slot else { return }
        switch result {
        case let .success(reply):
            self.explanation = reply.payload
            self.explanationIssue = reply.payload == nil ? "No explanation: \(Wording.code(reply.envelope.reason))" : nil
            self.selectedDetailFailed = reply.payload == nil
            // Only a detail that shows the recorded outcome counts as seeing the problem.
            let pending = ["scheduled", "in_progress"]
            if let shown = reply.payload?.explanation, shown.slot == slot, !pending.contains(shown.verdict) {
                self.acknowledge(slot)
            }
        case let .failure(issue):
            self.explanation = nil
            self.explanationIssue = issue.description
            self.selectedDetailFailed = true
        }
    }
}

/// "Did it help?" as the Overview shows it: the summary, per-send rows (labels may be nicknames, on
/// screen only), the progress line and the decision card. Copied text uses `EffectReport.text`.
struct EffectState: Equatable {
    let summary: EffectSummary
    let rows: [EffectRow]
    /// "1 Dec", or nil when no count-from date is set.
    let countFromLabel: String?
    /// "3 of 10 warm-ups measured since 1 Dec".
    let progress: String
    /// 0…1, for the progress bar.
    let progressFraction: Double
    let decision: EffectDecision?
}
