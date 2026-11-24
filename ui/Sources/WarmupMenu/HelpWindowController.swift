import AppKit
import SwiftUI
import WarmupCore

/// The Help window (F16): one reusable window with the plain-words guide from `HelpText`.
@MainActor
final class HelpWindowController {
    private(set) var window: NSWindow?

    /// The window, made on first use. `MainWindowController` shows it, so Help shares the app's
    /// activation-policy lifecycle (Dock and Cmd-Tab while open) without starting engine reads.
    func prepared() -> (window: NSWindow, isNew: Bool) {
        if let window = self.window { return (window, false) }
        let window = self.makeWindow()
        self.window = window
        return (window, true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = HelpText.title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: HelpView())
        window.setContentSize(NSSize(width: 520, height: 560))
        window.center()
        return window
    }
}

private struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(HelpText.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.heading)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(section.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 360, minHeight: 300)
    }
}
