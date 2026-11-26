// Adapted from Nameplate's StatusItemController (MIT, Peter Steinberger, revision
// 2d6efa0354065d7dee875a0d2e9e5a57f715d8d4). Overlay, splash and attention items removed;
// the menu now shows scheduler state and opens the Warm-up window.
import AppKit
import Combine
import WarmupCore

/// Classic NSStatusItem + NSMenu (plan 6.2). Opening the menu reads status (and only the reads
/// `ReadPlan` asks for) unless the last good read is under 10 seconds old; it never sends a probe.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private static let maxAccountLines = 4
    /// The app menu's Schedule items target this controller, so both menus run the same actions with
    /// the same enabled state (app 0.7.0). Set at init; the app makes one.
    private(set) static weak var current: StatusItemController?

    private let model: AppModel
    private let window: MainWindowController
    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var titleTimer: Timer?
    /// The last state symbol from a good read: a failed read dims it instead of replacing it.
    private var lastGoodSymbol = GlanceState.scheduled.symbolName

    private let headerItem = NSMenuItem()
    /// "Today:  ✓ 08:00   ○ 13:00   ○ 18:00" (opens Schedule at `todaySlot`).
    private let todayItem = NSMenuItem()
    /// The full slot of the displayed Today mark the line opens (060-FIX5 item 4).
    private var todaySlot: String?
    /// The latest problem, only while unseen (opens that time's details).
    private let attentionItem = NSMenuItem()
    /// Possible sends with no result that are newer than the last review (opens Overview).
    private let unreviewedItem = NSMenuItem()
    private let accountsSeparator = NSMenuItem.separator()
    private let accountsHeader = NSMenuItem.sectionHeader(title: MenuText.accountsHeader)
    /// Up to four account lines, then "5 accounts…".
    private let accountItems = (0...StatusItemController.maxAccountLines).map { _ in NSMenuItem() }
    private let warmUpItem = NSMenuItem(title: "Warm Up Now…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Scheduling…", action: nil, keyEquivalent: "")

    init(model: AppModel, window: MainWindowController) {
        self.model = model
        self.window = window
        super.init()
        Self.current = self
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = self.buildMenu()
        self.statusItem = statusItem
        self.apply(model.glance)
        model.$glance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] glance in self?.apply(glance) }
            .store(in: &self.subscriptions)
        // The title follows the mode, each status read (`.nextTime`) and read failures.
        Publishers.Merge3(
            model.$menuBarMode.map { _ in () }, model.$status.map { _ in () }, model.$readIssue.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.updateTitle() }
        .store(in: &self.subscriptions)
    }

    /// The 30-second title timer runs only for Time left with a next time (P6), so the other modes
    /// wake the app for nothing; Next time changes only with a status read.
    private func updateTitleTimer() {
        let wanted = self.model.menuBarMode == .timeLeft && self.titleNext != nil
        guard wanted else {
            self.titleTimer?.invalidate()
            self.titleTimer = nil
            return
        }
        guard self.titleTimer?.isValid != true else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.titleTimer = timer
    }

    private func apply(_ glance: Glance) {
        guard let button = self.statusItem?.button else { return }
        let label = MenuText.itemLabel(glance: glance)
        // A failed read dims the last good symbol instead of showing a question mark (6.1).
        let failed = glance.state == .unavailable
        if !failed { self.lastGoodSymbol = glance.symbolName }
        let symbol = failed ? self.lastGoodSymbol : glance.symbolName
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.appearsDisabled = self.model.readIssue != nil || failed
        button.toolTip = label
        button.setAccessibilityLabel(label)
        self.headerItem.image = NSImage(systemSymbolName: glance.symbolName, accessibilityDescription: nil)
        self.updateMenu()
        self.updateTitle()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Enabled, so the key line is drawn at full contrast and reachable by keyboard and
        // VoiceOver; choosing it opens the Overview tab.
        self.headerItem.target = self
        self.headerItem.action = #selector(self.openStatus)
        menu.addItem(self.headerItem)
        self.todayItem.target = self
        self.todayItem.action = #selector(self.openToday)
        self.todayItem.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        menu.addItem(self.todayItem)
        self.attentionItem.target = self
        self.attentionItem.action = #selector(self.explainProblem)
        self.attentionItem.image = NSImage(
            systemSymbolName: GlanceState.unseenProblemSymbol, accessibilityDescription: nil)
        menu.addItem(self.attentionItem)
        self.unreviewedItem.target = self
        self.unreviewedItem.action = #selector(self.openStatus)
        self.unreviewedItem.image = NSImage(systemSymbolName: "questionmark.diamond", accessibilityDescription: nil)
        menu.addItem(self.unreviewedItem)
        menu.addItem(self.accountsSeparator)
        menu.addItem(self.accountsHeader)
        for item in self.accountItems {
            item.target = self
            item.action = #selector(self.openAccounts)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        self.warmUpItem.target = self
        self.warmUpItem.action = #selector(self.warmUp)
        self.warmUpItem.image = NSImage(systemSymbolName: MenuIcons.warmUp, accessibilityDescription: nil)
        menu.addItem(self.warmUpItem)
        self.pauseItem.target = self
        self.pauseItem.action = #selector(self.togglePause)
        menu.addItem(self.pauseItem)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Warm-up", action: #selector(self.openStatus), keyEquivalent: "o")
        open.target = self
        open.image = NSImage(systemSymbolName: MenuIcons.open, accessibilityDescription: nil)
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(self.openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: MenuIcons.settings, accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Warm-up", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: MenuIcons.quit, accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        self.updateMenu()
        // P3: a read under 10 seconds old is shown as it is.
        guard ReadPlan.menuOpenNeedsRead(lastGoodRead: self.model.lastGoodRead, now: Date()) else { return }
        Task {
            await self.model.refreshAll()
            self.updateMenu()
        }
    }

    /// Every line that depends on the model, in menu order.
    private func updateMenu() {
        self.updateHeader()
        self.updateToday()
        Self.show(MenuText.attention(glance: self.model.glance), in: self.attentionItem)
        if let text = self.attentionItem.isHidden ? nil : self.attentionItem.title {
            self.attentionItem.setAccessibilityLabel("\(text). Shows what happened.")
        }
        Self.show(MenuText.unreviewed(count: self.model.visibleUnresolved.count), in: self.unreviewedItem)
        self.updateAccounts()
        self.updateActions()
    }

    private func updateToday() {
        guard self.model.status != nil else {
            self.todayItem.isHidden = true
            self.todaySlot = nil
            return
        }
        let marks = self.model.todayMarks()  // for the date shown now, never a kept earlier day
        let line = MenuText.today(marks: marks ?? [], available: marks != nil)
        self.todaySlot = MenuText.todayTarget(marks: marks ?? [])
        self.todayItem.title = line.title
        self.todayItem.setAccessibilityLabel(line.accessibilityLabel)
        self.todayItem.isHidden = false
    }

    /// Account lines with labels (nicknames unless hidden), secondary color and tabular digits.
    private func updateAccounts() {
        let lines: [String]
        if let status = self.model.status {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let cells = status.accounts.map {
                (account: $0.enrollmentId, cell: UsageText.cell(usage: $0.usage, now: now, zone: status.schedule.zone))
            }
            lines = MenuText.accounts(cells: cells, labels: self.model.labels, limit: Self.maxAccountLines)
            let turnedOff = Set(
                (self.model.accounts?.rows ?? []).filter { AccountText.readiness($0) == "Turned off" }
                    .compactMap(\.enrollmentId))
            self.accountsHeader.title = MenuText.accountsTitle(
                accounts: status.accounts, turnedOff: turnedOff, now: now, zone: status.schedule.zone)
        } else {
            lines = []
        }
        self.accountsSeparator.isHidden = lines.isEmpty
        self.accountsHeader.isHidden = lines.isEmpty
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, item) in self.accountItems.enumerated() {
            guard index < lines.count else {
                item.isHidden = true
                continue
            }
            item.title = lines[index]
            item.attributedTitle = NSAttributedString(string: lines[index], attributes: attributes)
            item.setAccessibilityLabel("\(lines[index]). Opens Accounts.")
            item.isHidden = false
        }
    }

    private func updateActions() {
        let available = self.model.controlsAvailable
        self.warmUpItem.isEnabled = available
        self.warmUpItem.title = self.model.mutating ? "Warming Up…" : "Warm Up Now…"
        self.pauseItem.isEnabled = available
        let pause = MenuIcons.pauseItem(scheduleEnabled: self.model.status?.scheduleEnabled)
        self.pauseItem.title = pause.title
        self.pauseItem.image = NSImage(systemSymbolName: pause.symbol, accessibilityDescription: nil)
    }

    /// Enabled state and the pause or resume title for the app menu's Schedule items. The status menu
    /// does not auto-enable, so `updateActions` sets its own items.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(self.warmUp):
            return self.model.controlsAvailable
        case #selector(self.togglePause):
            item.title = MenuIcons.pauseItem(scheduleEnabled: self.model.status?.scheduleEnabled).title
            return self.model.controlsAvailable
        default:
            return true
        }
    }

    /// The window opens only when the action was confirmed, to show its result.
    @objc func warmUp() {
        self.model.request(
            .runAll(allowSlotOverlap: false), confirmed: { [weak self] in self?.window.show(tab: .status) })
    }

    @objc func togglePause() {
        guard let status = self.model.status else { return }
        let action: WarmupAction =
            status.scheduleEnabled
            ? .pause(expectedRevision: status.scheduleRevision) : .resume(expectedRevision: status.scheduleRevision)
        self.model.request(action, confirmed: { [weak self] in self?.window.show(tab: .status) })
    }

    /// The verdict with the countdown while the next slot is its subject: "All good · next 13:00 · in 2 h".
    private func updateHeader() {
        let title = MenuText.header(glance: self.model.glance, status: self.model.status, now: Date())
        self.headerItem.title = title
        self.headerItem.setAccessibilityLabel("\(title). Opens Warm-up.")
    }

    /// The text beside the icon for the chosen mode ("2h 15m", "13:00"); empty for Icon only or
    /// without a next time.
    private func updateTitle() {
        self.updateTitleTimer()
        guard let button = self.statusItem?.button else { return }
        let now = Date()
        guard let target = self.titleNext,
            let text = self.model.menuBarMode.title(for: target.next, zone: target.zone, now: now)
        else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        // Past the slot, the cached status is stale: read status again (read-only), at most every
        // five minutes, so the label moves on to the following slot.
        if self.model.menuBarMode == .timeLeft, let due = Countdown.date(of: target.next, zone: target.zone),
            now.timeIntervalSince(due) > Self.staleAfter,
            now.timeIntervalSince(self.lastTitleRefresh) > Self.refreshEvery
        {
            self.lastTitleRefresh = now
            Task { await self.model.refreshAll() }
        }
        button.title = " " + text
        button.imagePosition = .imageLeading
    }

    /// The next time the title shows, or nil when it is hidden. A failed last read hides it rather
    /// than showing one from an old status. The timer uses the same rule.
    private var titleNext: (next: NextSlot, zone: String)? {
        guard self.model.menuBarMode != .iconOnly, self.model.readIssue == nil, let status = self.model.status,
            status.scheduleEnabled, let next = status.next
        else { return nil }
        return (next, status.schedule.zone)
    }

    private static func show(_ text: String?, in item: NSMenuItem) {
        item.title = text ?? ""
        item.isHidden = text == nil
    }

    private static let staleAfter: TimeInterval = 120
    private static let refreshEvery: TimeInterval = 300
    private var lastTitleRefresh = Date.distantPast

    @objc private func openStatus() { self.window.show(tab: .status) }

    /// Opens Schedule at the displayed date's slot, as Overview's Today cells do.
    @objc private func openToday() {
        self.window.show(tab: .schedule)
        guard let slot = self.todaySlot else { return }
        Task { await self.model.showDay(slot: slot) }
    }

    @objc private func openAccounts() { self.window.show(tab: .accounts) }

    @objc private func openSettings() { self.window.show(tab: .settings) }

    @objc private func explainProblem() {
        guard let slot = self.model.glance.unseenProblemSlot else { return }
        self.window.show(tab: .schedule)
        Task { await self.model.explain(slot: slot) }
    }
}
