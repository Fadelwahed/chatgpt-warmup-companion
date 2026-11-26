// Adapted from Nameplate's AppMain (MIT, Peter Steinberger, revision
// 2d6efa0354065d7dee875a0d2e9e5a57f715d8d4): plain AppKit lifecycle with an accessory-policy
// status item. Overlay, splash, fleet, URL-command and Sparkle updater behavior removed.
import AppKit
import WarmupCore

@main
@MainActor
enum WarmupMain {
    private static let delegate = AppDelegate()

    static func main() {
        switch StatusCLI.parse(Array(CommandLine.arguments.dropFirst())) {
        case let .provision(arguments): exit(Provisioning.run(arguments: arguments))
        case .status: exit(StatusCommand.run(json: false))
        case .json: exit(StatusCommand.run(json: true))
        case let .usage(text):
            FileHandle.standardError.write(Data("\(text)\n".utf8))
            exit(StatusCLI.exitUsage)
        case .app: break
        }
        let app = NSApplication.shared
        app.delegate = self.delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var window: MainWindowController?
    private var statusItem: StatusItemController?
    private var alerts: AlertController?
    private var mainMenu: MainMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy hands over to the first. Correctness never depends on this: engine
        // locks and installation guards protect state even with two apps running.
        if let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel(store: BindingStore.defaultStore())
        let alerts = AlertController(model: model)
        let window = MainWindowController(model: model, alerts: alerts)
        alerts.openSlot = { [weak window, weak model] slot in
            // A notice without a slot (060-FIX5 item 2) opens Overview.
            guard !slot.isEmpty else {
                window?.show(tab: .status)
                return
            }
            window?.show(tab: .schedule)
            Task { await model?.explain(slot: slot) }
        }
        self.model = model
        self.window = window
        self.alerts = alerts
        self.statusItem = StatusItemController(model: model, window: window)
        let mainMenu = MainMenu(window: window)
        mainMenu.install()
        self.mainMenu = mainMenu
        // With a verified binding, launch performs one read-only status so the menu-bar icon is right
        // without a click (AppModel.init). With alerts on and allowed, that read also sets the
        // alert baseline.
        alerts.start()
    }

    /// Quitting never cancels or interrupts an engine change. While one runs, the app stays open
    /// (or hides its window) until the engine replies; a relaunch only observes state.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard self.model?.mutating == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A change is still running"
        alert.informativeText = "Warm-up stays open until the engine finishes it. Quitting would not stop the engine, and the result could not be shown."
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Hide Window")
        // From the status menu an accessory app must come forward first, or the dialog opens behind.
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { NSApp.hide(nil) }
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        self.window?.show()
        return false
    }
}

/// `WarmupMenu --status` / `--json`: read-only `status`, `schedule inspect` and `history` through the
/// stored binding, printed without IDs, paths or nicknames. Exit 0 all good, 1 needs attention, 2 unreadable.
enum StatusCommand {
    static func run(json: Bool) -> Int32 {
        guard let store = BindingStore.defaultStore(), let binding = try? store.load(),
            BindingVerifier.checkFiles(nodePath: binding.nodePath, scriptPath: binding.scriptPath) == nil
        else { return self.finish(StatusCLI.render(nil, json: json, now: Date())) }
        let client = EngineClient(binding: binding)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var snapshot: StatusCLI.Snapshot?
        Task.detached {
            snapshot = await StatusCLI.read(client: client)
            semaphore.signal()
        }
        semaphore.wait()
        // Read-only: the same app-domain value the menu uses, so both say "Needs a look" alike.
        let seen = UserDefaults.standard.string(forKey: GlanceBuilder.acknowledgedSlotKey)
        // Read-only: the app's reviewed sends from the same private store; a missing or unreadable file
        // loads as nothing reviewed. The CLI never writes it.
        let reviewed = ReviewedSendsStore(directory: store.directory).load()
        return self.finish(
            StatusCLI.render(snapshot, json: json, now: Date(), acknowledgedSlot: seen, reviewed: reviewed))
    }

    private static func finish(_ output: (stdout: Data, stderr: String?, code: Int32)) -> Int32 {
        FileHandle.standardOutput.write(output.stdout)
        if let message = output.stderr { FileHandle.standardError.write(Data("\(message)\n".utf8)) }
        return output.code
    }
}

/// The operator's explicit binding step: `WarmupMenu --provision-binding --node PATH --script PATH
/// --expect-build sha256:HEX`. It runs read-only status through exactly those paths, checks the
/// capability, build and paths the engine reports, and only then writes the private binding.
enum Provisioning {
    static func run(arguments: [String]) -> Int32 {
        var options: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count, ["--node", "--script", "--expect-build"].contains(arguments[index]), options[arguments[index]] == nil {
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard index == arguments.count, let node = options["--node"], let script = options["--script"], let build = options["--expect-build"] else {
            return self.fail("usage: WarmupMenu --provision-binding --node PATH --script PATH --expect-build sha256:HEX")
        }
        if let issue = BindingVerifier.checkFiles(nodePath: node, scriptPath: script) { return self.fail(issue.description) }
        guard let store = BindingStore.defaultStore() else { return self.fail("Application Support is unavailable") }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<(Envelope, EngineStatus), ClientIssue> = .failure(.launchFailed)
        Task.detached {
            outcome = await EngineClient.provisionalStatus(nodePath: node, scriptPath: script)
            semaphore.signal()
        }
        semaphore.wait()
        let envelope: Envelope, status: EngineStatus
        switch outcome {
        case let .failure(issue): return self.fail(issue.description)
        case let .success(value): (envelope, status) = value
        }
        guard let installation = envelope.installationId else { return self.fail("engine reported no installation") }
        guard status.capability?.version == EngineBinding.supportedCapability else { return self.fail("unsupported engine capability") }
        guard status.engineBuild == build else { return self.fail("engine build does not match --expect-build") }
        guard status.engine?.nodePath == node, status.engine?.scriptPath == script else { return self.fail("engine reports different paths") }
        let binding = EngineBinding(nodePath: node, scriptPath: script, engineBuild: build, installationId: installation, capabilityVersion: EngineBinding.supportedCapability)
        do { try store.save(binding) } catch { return self.fail("could not write the binding") }
        // The installation ID stays in the binding file only, never in a transcript.
        print("Bound.")
        print(store.file.path)
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Provisioning refused: \(message)\n".utf8))
        return 2
    }
}
