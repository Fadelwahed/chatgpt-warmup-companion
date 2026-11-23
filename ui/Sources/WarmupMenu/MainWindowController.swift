// Adapted from Nameplate's SettingsWindowController (MIT, Peter Steinberger, revision
// 2d6efa0354065d7dee875a0d2e9e5a57f715d8d4): one persistent NSWindow hosting SwiftUI panes in
// an NSTabViewController with toolbar tabs. Panes and the visible-only refresh are Warm-up's.
import AppKit
import SwiftUI
import WarmupCore

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case status, schedule, accounts, settings

        var label: String {
            switch self {
            case .status: "Overview"
            case .schedule: "Schedule"
            case .accounts: "Accounts"
            case .settings: "Settings"
            }
        }

        var visibleTab: VisibleTab {
            switch self {
            case .status: .overview
            case .schedule: .schedule
            case .accounts: .accounts
            case .settings: .settings
            }
        }

        var symbol: String {
            switch self {
            case .status: "sun.horizon"
            case .schedule: "calendar"
            case .accounts: "person.2"
            case .settings: "gearshape"
            }
        }
    }

    private static let refreshInterval: TimeInterval = 30
    private static let paneSize = NSSize(width: 780, height: 600)
    private static let frameAutosaveName = "WarmupMainWindow.v2"
    private let model: AppModel
    private let alerts: AlertController
    private var window: NSWindow?
    private var tabController: NSTabViewController?
    private var timer: Timer?
    private var tabObservation: NSKeyValueObservation?

    init(model: AppModel, alerts: AlertController) {
        self.model = model
        self.alerts = alerts
        super.init()
        // Confirmations become sheets on this window while it is visible and key (X13).
        model.sheetWindow = { [weak self] in
            guard let window = self?.window, window.isVisible, window.isKeyWindow, window.attachedSheet == nil
            else { return nil }
            return window
        }
    }

    func show(tab: Tab? = nil) {
        let isNew = self.window == nil
        if isNew { self.makeWindow() }
        // While the window is open Warm-up is a regular app: it has a main menu, a Dock icon and a
        // place in Cmd-Tab, so keyboard and VoiceOver users can always get back to it.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        self.window?.makeKeyAndOrderFront(nil)
        // The first toolbar tab otherwise takes key focus and keeps its focus ring on every tab (A6).
        // Tab still moves into the window's controls from here.
        if isNew { self.window?.makeFirstResponder(nil) }
        if let tab { self.tabController?.selectedTabViewItemIndex = tab.rawValue }
        self.updateRefreshTimer()
    }

    private static let title = "Warm-up"

    private func makeWindow() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // The window title stays "Warm-up"; the toolbar already names the tab.
        tabs.canPropagateSelectedChildViewControllerTitle = false
        func addPane(_ tab: Tab, view: some View) {
            let root = view.environmentObject(self.model).environmentObject(self.alerts).frame(minWidth: 640, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
            let hosting = NSHostingController(rootView: root)
            // Found on the host (U4): with default sizing the split view's large ideal height made the
            // hosted pane taller than the window and pushed the Schedule content off screen.
            hosting.sizingOptions = []
            hosting.title = tab.label
            hosting.preferredContentSize = Self.paneSize
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            tabs.addTabViewItem(item)
        }
        addPane(.status, view: StatusPane(openSchedule: { [weak self] in self?.show(tab: .schedule) }))
        addPane(.schedule, view: SchedulePane())
        addPane(.accounts, view: AccountsPane())
        addPane(.settings, view: SettingsPane())

        let window = NSWindow(contentViewController: tabs)
        window.title = Self.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 640, height: 480)
        if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.tabController = tabs
        self.window = window
        self.tabObservation = tabs.observe(\.selectedTabViewItemIndex) { [weak self] _, _ in
            Task { @MainActor in
                self?.window?.title = Self.title
                self?.updateScheduleVisibility()
            }
        }
    }

    /// The model counts a problem as seen only while its explanation is on screen, and plans its
    /// reads from the visible tab (`.none` while the window is closed or hidden).
    private func updateScheduleVisibility() {
        let selected = self.tabController.flatMap { Tab(rawValue: $0.selectedTabViewItemIndex) }
        self.model.setScheduleVisible(self.isVisible && selected == .schedule)
        self.model.setVisibleTab(self.isVisible ? selected?.visibleTab ?? .none : .none)
    }

    // Refresh only while the window is actually visible. Closing or hiding it stops polling;
    // the LaunchAgent keeps scheduling regardless.
    private var isVisible: Bool {
        guard let window = self.window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func updateRefreshTimer() {
        self.updateScheduleVisibility()
        if self.isVisible {
            if self.timer == nil {
                Task { await self.model.refreshAll() }
                let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.isVisible else { return }
                        await self.model.refreshAll()
                    }
                }
                timer.tolerance = 5
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { self.updateRefreshTimer() }
    func windowDidMiniaturize(_ notification: Notification) { self.updateRefreshTimer() }
    func windowDidDeminiaturize(_ notification: Notification) { self.updateRefreshTimer() }
    func windowWillClose(_ notification: Notification) {
        self.model.setScheduleVisible(false)
        self.model.setVisibleTab(.none)
        self.timer?.invalidate()
        self.timer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Refresh (Cmd-R): every read, not only the planned ones.
    func refresh() { Task { await self.model.refreshAll(force: true) } }
}
