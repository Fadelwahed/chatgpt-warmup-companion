// Adapted from Nameplate's SettingsWindowController (MIT, Peter Steinberger, revision
// 2d6efa0354065d7dee875a0d2e9e5a57f715d8d4): one persistent NSWindow hosting SwiftUI panes in
// an NSTabViewController. Since 0.6.3 a sidebar picks the pane and Settings has its own window;
// the panes, the sidebar and the visible-only refresh are Warm-up's.
import AppKit
import Combine
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

    /// The three panes in the sidebar, in order (Cmd-1 to Cmd-3). Settings has its own window (0.6.3).
    static let sidebarTabs: [Tab] = [.status, .schedule, .accounts]

    private static let refreshInterval: TimeInterval = 30
    private static let paneSize = NSSize(width: 760, height: 600)
    private static let paneMinWidth: CGFloat = 640
    private static let windowSize = NSSize(width: 960, height: 640)
    private static let settingsSize = NSSize(width: 560, height: 620)
    // New names, so the larger sidebar layout does not open in the old tab window's saved frame.
    private static let frameAutosaveName = "WarmupMainWindow.v3"
    private static let settingsAutosaveName = "WarmupSettingsWindow"
    private let model: AppModel
    private let alerts: AlertController
    private let navigation = SidebarSelection()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private let help = HelpWindowController()
    private var tabController: NSTabViewController?
    private var timer: Timer?
    private var selectionObservation: AnyCancellable?
    /// The window in `windowWillClose`, which still reports itself visible.
    private var closing: NSWindow?

    init(model: AppModel, alerts: AlertController) {
        self.model = model
        self.alerts = alerts
        super.init()
        // Confirmations become sheets on the key Warm-up window while it is visible (X13).
        model.sheetWindow = { [weak self] in
            guard let self else { return nil }
            return [self.window, self.settingsWindow].compactMap { $0 }.first {
                $0.isVisible && $0.isKeyWindow && $0.attachedSheet == nil
            }
        }
    }

    func show(tab: Tab? = nil) {
        if tab == .settings { return self.showSettings() }
        let isNew = self.window == nil
        if isNew { self.makeWindow() }
        self.present(self.window, isNew: isNew)
        if let tab { self.navigation.tab = tab }
        self.updateRefreshTimer()
    }

    func showSettings() {
        let isNew = self.settingsWindow == nil
        if isNew { self.makeSettingsWindow() }
        self.present(self.settingsWindow, isNew: isNew)
        self.updateRefreshTimer()
    }

    /// Help (F16) counts as an open window for the app's Dock and Cmd-Tab presence, but not for
    /// engine reads (`isVisible` leaves it out).
    func showHelp() {
        let (window, isNew) = self.help.prepared()
        window.delegate = self
        self.present(window, isNew: isNew)
    }

    private func present(_ window: NSWindow?, isNew: Bool) {
        // While a window is open Warm-up is a regular app: it has a main menu, a Dock icon and a
        // place in Cmd-Tab, so keyboard and VoiceOver users can always get back to it.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // A first control otherwise takes key focus and keeps its focus ring (A6). Tab still moves
        // into the window's controls from here.
        if isNew { window?.makeFirstResponder(nil) }
    }

    private static let title = "Warm-up"

    private func hosted(_ view: some View, minWidth: CGFloat) -> NSHostingController<some View> {
        let root = view.environmentObject(self.model).environmentObject(self.alerts)
            .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        let hosting = NSHostingController(rootView: root)
        // Found on the host (U4): with default sizing the split view's large ideal height made the
        // hosted pane taller than the window and pushed the Schedule content off screen.
        hosting.sizingOptions = []
        return hosting
    }

    private func makeWindow() {
        // The panes stay loaded in a tab view without tabs, as before: switching keeps each pane's
        // state, and the Overview pane keeps making its announcements.
        let tabs = NSTabViewController()
        tabs.tabStyle = .unspecified
        for tab in Self.sidebarTabs {
            let view: AnyView =
                switch tab {
                case .status: AnyView(StatusPane(openSchedule: { [weak self] in self?.show(tab: .schedule) }))
                case .schedule: AnyView(SchedulePane())
                case .accounts, .settings: AnyView(AccountsPane())
                }
            let hosting = self.hosted(view, minWidth: Self.paneMinWidth)
            hosting.title = tab.label
            hosting.preferredContentSize = Self.paneSize
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.label
            tabs.addTabViewItem(item)
        }
        let sidebar = NSHostingController(rootView: SidebarView(selection: self.navigation))
        sidebar.sizingOptions = []
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: tabs)
        content.minimumThickness = Self.paneMinWidth
        // The window has a full-size content view for the sidebar: keep the panes below the toolbar.
        if #available(macOS 26.0, *) { content.automaticallyAdjustsSafeAreaInsets = true }
        split.addSplitViewItem(content)

        let window = NSWindow(contentViewController: split)
        window.title = Self.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "WarmupMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        // The sidebar's widest pane (Schedule's list and detail, about 621 pt) plus the sidebar.
        window.contentMinSize = NSSize(width: Self.paneMinWidth + 180, height: 480)
        window.setContentSize(Self.windowSize)
        if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.tabController = tabs
        self.window = window
        self.selectionObservation = self.navigation.$tab.sink { [weak self] tab in
            // `sink` runs before the published value is stored: use the value passed in.
            MainActor.assumeIsolated { self?.select(tab) }
        }
    }

    private func select(_ tab: Tab) {
        guard let index = Self.sidebarTabs.firstIndex(of: tab) else { return }
        self.tabController?.selectedTabViewItemIndex = index
        self.window?.subtitle = tab.label
        self.updateScheduleVisibility(selected: tab)
    }

    private func makeSettingsWindow() {
        let hosting = self.hosted(SettingsPane(), minWidth: 480)
        hosting.preferredContentSize = Self.settingsSize
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // Two separate windows: with "Prefer tabs" macOS would otherwise merge Settings into the main
        // window as a tab (seen in the 0.6.3 screenshots).
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentMinSize = NSSize(width: 480, height: 480)
        window.setContentSize(Self.settingsSize)
        if !window.setFrameUsingName(Self.settingsAutosaveName) { window.center() }
        window.setFrameAutosaveName(Self.settingsAutosaveName)
        self.settingsWindow = window
    }

    /// The model counts a problem as seen only while its explanation is on screen, and plans its
    /// reads from the visible tab (`.none` while the window is closed or hidden).
    private func updateScheduleVisibility(selected: Tab? = nil) {
        let selected = selected ?? self.navigation.tab
        let mainVisible = self.isOnScreen(self.window)
        // "Seen" needs the Schedule really in front: the main window must be key, so the Settings
        // window, a panel or another app covering it never marks a problem as seen (0.6.3 review).
        // A sheet (Edit Times, Rename) covers the detail too.
        let inFront = mainVisible && self.window?.isKeyWindow == true && self.window?.attachedSheet == nil
        self.model.setScheduleVisible(inFront && selected == .schedule)
        let visible: VisibleTab =
            mainVisible ? selected.visibleTab : self.isOnScreen(self.settingsWindow) ? .settings : .none
        self.model.setVisibleTab(visible)
    }

    // Refresh only while a window is actually visible. Closing or hiding them stops polling;
    // the LaunchAgent keeps scheduling regardless.
    private var isVisible: Bool { self.isOnScreen(self.window) || self.isOnScreen(self.settingsWindow) }

    private func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let window, window !== self.closing else { return false }
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
    func windowDidBecomeKey(_ notification: Notification) { self.updateScheduleVisibility() }
    func windowDidResignKey(_ notification: Notification) { self.updateScheduleVisibility() }
    func windowWillBeginSheet(_ notification: Notification) {
        // The sheet is not attached yet when this arrives: Schedule stops counting as seen now.
        if (notification.object as? NSWindow) === self.window { self.model.setScheduleVisible(false) }
    }
    func windowDidEndSheet(_ notification: Notification) { self.updateScheduleVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { self.updateRefreshTimer() }
    func windowDidDeminiaturize(_ notification: Notification) { self.updateRefreshTimer() }
    func windowWillClose(_ notification: Notification) {
        // The closing window still reports visible here: leave it out of every check below.
        self.closing = notification.object as? NSWindow
        defer { self.closing = nil }
        self.updateRefreshTimer()
        // A minimized window is still open, so the app stays regular for it (its polling stops anyway).
        let anyOpen = [self.window, self.settingsWindow, self.help.window].contains { window in
            guard let window, window !== self.closing else { return false }
            return window.isVisible || window.isMiniaturized
        }
        if !anyOpen { NSApp.setActivationPolicy(.accessory) }
    }

    /// Refresh (Cmd-R): every read, not only the planned ones.
    func refresh() { Task { await self.model.refreshAll(force: true) } }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? { nil }
}

/// The sidebar's selected pane, shared by the sidebar list and the window controller.
@MainActor
final class SidebarSelection: ObservableObject {
    @Published var tab: MainWindowController.Tab = .status
}

/// The sidebar: Overview, Schedule and Accounts. Settings is in its own window (Cmd-comma).
private struct SidebarView: View {
    @ObservedObject var selection: SidebarSelection

    var body: some View {
        List(
            selection: Binding(
                get: { self.selection.tab },
                // A click on empty space deselects: keep the current pane.
                set: { if let tab = $0 { self.selection.tab = tab } })
        ) {
            ForEach(MainWindowController.sidebarTabs, id: \.self) { tab in
                Label(tab.label, systemImage: tab.symbol).tag(tab)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Sections")
    }
}
