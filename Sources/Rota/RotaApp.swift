import AppKit
import os
import RotaCore
import SwiftUI

@main
struct RotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A menu-bar accessory: the status item, its panel and the windows are
        // AppKit, owned by AppDelegate. This scene only satisfies `App`; its menu
        // items are rerouted so Settings... (Command-,) opens the real window.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { AppModel.shared.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Routine\u{2026}") {
                    AppModel.shared.showMainWindow()
                    AppModel.shared.presentingNew = true
                }
                .keyboardShortcut("n")
                Button("Import Routines\u{2026}") {
                    AppModel.shared.showMainWindow()
                    AppModel.shared.presentingImport = true
                }
            }
            RoutineCommands()
            // Chat text size, as chat apps and browsers do it.
            CommandGroup(after: .toolbar) {
                Button("Bigger") { AppModel.shared.chatText.bigger() }
                    .keyboardShortcut("+")
                Button("Smaller") { AppModel.shared.chatText.smaller() }
                    .keyboardShortcut("-")
                Button("Actual Size") { AppModel.shared.chatText.reset() }
                    .keyboardShortcut("0")
            }
            CommandGroup(replacing: .help) {
                Button("Rota Help") {
                    if let url = URL(string: "https://github.com/wiltodelta/rota#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

/// The Routine menu: what a person does to the routine in front of them.
struct RoutineCommands: Commands {
    var body: some Commands {
        CommandMenu("Routine") {
            let model = AppModel.shared
            let routine = model.selectedRoutine
            let running = routine.map { model.scheduler.active[$0.id] != nil } ?? false
            Button("Run Now") {
                guard let routine else { return }
                model.scheduler.run(routine, trigger: .manual)
                model.selection = model.latest(of: routine.id)
            }
            .keyboardShortcut("r")
            .disabled(routine == nil || running)
            Button("Stop") { routine.map { model.scheduler.stop($0.id) } }
                .keyboardShortcut(".")
                .disabled(!running)
            Divider()
            Button("Edit Routine\u{2026}") { model.editSelectedRoutine() }
                .keyboardShortcut("e")
                .disabled(routine == nil)
        }
    }
}

/// App-wide state: the scheduler plus the window selection the menu bar can drive.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let scheduler: Scheduler
    var selection: SidebarItem?
    var presentingNew = false
    var presentingImport = false
    /// The routine whose settings sheet is open.
    var editingRoutineID: String?

    /// The routine the selection is about: the selected routine, or the selected session's.
    var selectedRoutine: Routine? {
        switch selection {
        case .routine(let id):
            return scheduler.routine(id)
        case .session(let id):
            _ = scheduler.historyVersion
            return scheduler.allRecords().first { $0.id == id }.flatMap { scheduler.routine($0.routineID) }
        case nil:
            return nil
        }
    }

    func editSelectedRoutine() {
        guard let routine = selectedRoutine else { return }
        selection = .routine(routine.id)
        editingRoutineID = routine.id
    }
    let settings = AppSettings()
    let chatText = ChatTextSettings()
    private let notifier = Notifier()
    @ObservationIgnored var openMainWindow: () -> Void = {}
    @ObservationIgnored var openSettingsWindow: () -> Void = {}

    private init() {
        // Development hook: render in one appearance without changing the system's.
        if let style = ProcessInfo.processInfo.environment["ROTA_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
        }
        scheduler = Scheduler(location: .standard, launcher: ProcessLauncher())
        let settings = settings
        scheduler.executable = { settings.executable(for: $0) }
        notifier.notifyOnSuccess = { settings.notifyOnSuccess }
        scheduler.notifier = notifier
        notifier.requestAuthorization()
        notifier.open = { [weak self] in self?.showMainWindow(selecting: $0) }
    }

    func showMainWindow(selecting item: SidebarItem? = nil) {
        if let item { selection = item }
        openMainWindow()
    }

    /// A routine's latest session, or the routine itself before its first run.
    func latest(of routineID: String) -> SidebarItem {
        scheduler.history.records(for: routineID).first.map { .session($0.id) } ?? .routine(routineID)
    }

    func showSettings() {
        openSettingsWindow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanelController!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            Logger(subsystem: "com.wiltodelta.rota", category: "app").info("Another instance is running; quitting")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panel = MenuBarPanelController(rootView: MenuBarContent().environment(model),
                                       size: NSSize(width: 340, height: 300))
        model.openMainWindow = { [weak self] in self?.showMainWindow() }
        model.openSettingsWindow = { [weak self] in self?.showSettingsWindow() }
        observeStatus()

        Updater.shared.start()
        model.scheduler.start()
        if model.scheduler.routines.isEmpty { showMainWindow() }
        // Development hooks: open settings, or the panel, where a capture script can find them.
        if ProcessInfo.processInfo.environment["ROTA_OPEN_SETTINGS"] != nil { showSettingsWindow() }
        if ProcessInfo.processInfo.environment["ROTA_OPEN_PANEL"] != nil, let screen = NSScreen.main {
            panel.show(topLeft: NSPoint(x: screen.visibleFrame.midX - 170, y: screen.visibleFrame.maxY - 40))
            Logger(subsystem: "com.wiltodelta.rota", category: "app")
                .info("Panel window \(self.panel.windowNumber, privacy: .public)")
        }
    }

    /// The status item can be hidden behind the notch or by the system, so
    /// opening Rota again from Finder or Spotlight must still reach its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// A run lives in Rota's process, or is watched by it, so quitting asks first
    /// and stops the running sessions the way Stop does: they are recorded as
    /// stopped and can be continued later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.scheduler.active.count
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        if running == 1 {
            alert.messageText = "Stop the running routine and quit?"
            alert.informativeText = "Its session is kept, and you can continue it after Rota opens again."
        } else {
            alert.messageText = "Stop \(running) running routines and quit?"
            alert.informativeText = "Their sessions are kept, and you can continue them after Rota opens again."
        }
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.scheduler.stopAll()
        waitForRunsToEnd(until: Date().addingTimeInterval(5))
        return .terminateLater
    }

    /// Runners report their end on the main queue, which keeps turning while the
    /// app waits to terminate; what has not ended by the deadline is closed as
    /// interrupted on the next launch.
    private func waitForRunsToEnd(until deadline: Date) {
        if model.scheduler.active.isEmpty || Date() > deadline {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitForRunsToEnd(until: deadline) }
    }

    /// Redraws the status item whenever a run starts or ends, or an update appears.
    private func observeStatus() {
        withObservationTracking {
            updateStatusItem()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeStatus() }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let running = model.scheduler.active.count
        // Template images from scripts/draw-icon.py: the dial when idle, a solid disc while running.
        if let image = NSImage(named: running > 0 ? "MenuIconActive" : "MenuIcon")?.copy() as? NSImage {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        }
        // VoiceOver reads the image-only button by this label, not the symbol's name.
        button.setAccessibilityLabel("Rota")
        button.setAccessibilityValue(running > 0 ? "\(running) running" : nil)
        let unread = model.scheduler.unreadCount
        var tip = running > 0 ? "Rota: \(running) running" : "Rota"
        if unread > 0 { tip += ", \(unread) unread" }
        if let version = Updater.shared.pendingVersion { tip += ". Update to \(version) available" }
        button.toolTip = tip
        // The Dock shows the icon only while a window is open; the badge counts unread sessions.
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.close()
            showQuickMenu()
            return
        }
        guard let button = statusItem.button else { return }
        if panel.isShown {
            panel.close()
        } else {
            panel.show(relativeTo: button)
        }
    }

    private func showQuickMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(item("Open Rota", symbol: "macwindow", action: #selector(openMainFromMenu)))
        menu.addItem(item("Settings\u{2026}", symbol: "gearshape", action: #selector(showSettingsWindow), key: ","))
        menu.addItem(item("Check for Updates\u{2026}", symbol: "arrow.down.circle",
                          action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        // The standard selector lets macOS 26+ give the item its system icon.
        menu.addItem(NSMenuItem(title: "Quit Rota", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func item(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if #available(macOS 26.0, *) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func openMainFromMenu() { showMainWindow() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    // MARK: Windows

    private func showMainWindow() {
        panel.close()
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainWindow().environment(model))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Rota"
            // One window: no tab bar, no tab items in the View and Window menus.
            window.tabbingMode = .disallowed
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1040, height: 680))
            window.contentMinSize = NSSize(width: 820, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameUsingName("RotaMain") { window.center() }
            window.setFrameAutosaveName("RotaMain")
            mainWindow = window
        }
        present(mainWindow)
    }

    @objc private func showSettingsWindow() {
        panel.close()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Rota Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    /// A window comes forward reliably only from a regular app, so Rota takes a
    /// Dock icon while one is open and gives it up when the last one closes.
    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Let the settings window go, so the next opening starts fresh.
        if closing === settingsWindow { settingsWindow = nil }
        let others = [mainWindow, settingsWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

/// User preferences kept in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var notifyOnSuccess: Bool {
        didSet { defaults.set(notifyOnSuccess, forKey: "notifyOnSuccess") }
    }

    private var executables: [String: String] {
        didSet { defaults.set(executables, forKey: "executables") }
    }

    init() {
        notifyOnSuccess = defaults.bool(forKey: "notifyOnSuccess")
        executables = defaults.dictionary(forKey: "executables") as? [String: String] ?? [:]
        refreshInstalled()
    }

    /// The installed copies of each agent CLI, found at launch and when Settings open.
    private(set) var installed: [Harness: [InstalledExecutable]] = [:]
    /// The models each agent offers, read from its CLI with the copies.
    private(set) var models: [Harness: [ModelOption]] = [:]

    /// The path runs use: the one picked in Settings, else the first installed
    /// copy, else where the CLI's installer puts it. The shell is always zsh.
    func executable(for harness: Harness) -> String {
        harness == .shell ? harness.defaultExecutable()
            : Self.resolve(harness, chosen: chosenExecutable(for: harness), installed: installed[harness] ?? [])
    }

    private nonisolated static func resolve(_ harness: Harness, chosen: String?,
                                            installed: [InstalledExecutable]) -> String {
        chosen ?? installed.first?.path ?? harness.defaultExecutable()
    }

    /// The path picked in Settings; nil means automatic.
    func chosenExecutable(for harness: Harness) -> String? {
        executables[harness.rawValue].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setExecutable(_ path: String?, for harness: Harness) {
        executables[harness.rawValue] = path
    }

    @ObservationIgnored private var refreshing: Task<Void, Never>?

    /// Finds the installed copies, then each agent's models, all agents at once.
    /// A newer call replaces one still running, so the latest choices win.
    func refreshInstalled() {
        let chosen = Dictionary(uniqueKeysWithValues: Harness.agents.map { ($0, chosenExecutable(for: $0)) })
        refreshing?.cancel()
        refreshing = Task.detached(priority: .utility) {
            let found = ExecutableDiscovery.installedAgents()
            guard !Task.isCancelled else { return }
            await MainActor.run { self.installed = found }
            let models = await withTaskGroup(of: (Harness, [ModelOption]).self) { group in
                for harness in Harness.agents {
                    let executable = Self.resolve(harness, chosen: chosen[harness] ?? nil,
                                                  installed: found[harness] ?? [])
                    group.addTask { (harness, ModelCatalog.models(for: harness, executable: executable)) }
                }
                return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self.models = models }
        }
    }
}
