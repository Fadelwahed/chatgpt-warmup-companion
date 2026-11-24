import AppKit
import WarmupCore

/// The main menu for the window. Warm-up runs as a menu-bar (accessory) app; while its window is
/// open it becomes a regular app, so this menu gives the standard keyboard routes: Cmd-W, Cmd-M,
/// Cmd-Q, the Edit commands for the time fields, and Cmd-1 to Cmd-3 for the sidebar panes, Cmd-comma for the Settings window and Cmd-R to refresh.
/// The last menu, Help, opens the Warm-up Help window (Cmd-?).
@MainActor
final class MainMenu: NSObject {
    private let window: MainWindowController

    init(window: MainWindowController) {
        self.window = window
        super.init()
    }

    func install() {
        let main = NSMenu()
        main.addItem(
            self.submenu(
                "Warm-up",
                items: [
                    NSMenuItem(
                        title: "About Warm-up", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: ""),
                    .separator(),
                    self.settingsItem(),
                    .separator(),
                    NSMenuItem(title: "Hide Warm-up", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
                    .separator(),
                    NSMenuItem(
                        title: "Quit Warm-up", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
                ]))
        main.addItem(
            self.submenu(
                "Edit",
                items: [
                    NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
                    self.item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                    .separator(),
                    NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                    NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                    NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                    NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
                ]))
        var view: [NSMenuItem] = MainWindowController.sidebarTabs.map { tab in
            let item = NSMenuItem(
                title: tab.label, action: #selector(self.openTab(_:)), keyEquivalent: "\(tab.rawValue + 1)")
            item.target = self
            item.tag = tab.rawValue
            return item
        }
        let refresh = NSMenuItem(title: "Refresh", action: #selector(self.refresh), keyEquivalent: "r")
        refresh.target = self
        view += [.separator(), refresh]
        main.addItem(self.submenu("View", items: view))
        let windowMenu = self.submenu(
            "Window",
            items: [
                NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
                NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            ])
        main.addItem(windowMenu)
        let helpItem = NSMenuItem(title: HelpText.title, action: #selector(self.openHelp), keyEquivalent: "?")
        helpItem.target = self
        let helpMenu = self.submenu("Help", items: [helpItem])
        main.addItem(helpMenu)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.helpMenu = helpMenu.submenu
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func settingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Settings…", action: #selector(self.openSettings), keyEquivalent: ",")
        item.target = self
        return item
    }

    @objc private func openSettings() { self.window.show(tab: .settings) }

    @objc private func openTab(_ sender: NSMenuItem) {
        self.window.show(tab: MainWindowController.Tab(rawValue: sender.tag) ?? .status)
    }

    @objc private func refresh() { self.window.refresh() }

    @objc private func openHelp() { self.window.showHelp() }
}
