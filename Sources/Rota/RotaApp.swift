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
                SidebarToggleCommand()
                Divider()
                Button("Bigger") { AppModel.shared.chatText.bigger() }
                    .keyboardShortcut("+")
                Button("Smaller") { AppModel.shared.chatText.smaller() }
                    .keyboardShortcut("-")
                Button("Actual Size") { AppModel.shared.chatText.reset() }
                    .keyboardShortcut("0")
                Divider()
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
    /// Unsent messages survive switching between sessions for this app launch.
    var sessionDrafts: [UUID: String] = [:]
    var sessionAttachments: [UUID: [ChatAttachment]] = [:]

    func discardDraftAttachments() {
        guard !sessionAttachments.isEmpty else { return }
        for record in scheduler.allRecords() {
            guard let files = sessionAttachments[record.id],
                  let store = try? scheduler.history.attachments(for: record) else { continue }
            for file in files { try? store.discard(file) }
        }
        sessionAttachments = [:]
    }
    var presentingNew = false
    var presentingImport = false
    var sessionToDelete: RunRecord?
    /// The routine whose settings sheet is open.
    var editingRoutineID: String?
    /// Whether the sessions and routines list shows; kept across launches.
    var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }

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

    func deleteSession(_ record: RunRecord) {
        let records = selection == .session(record.id) ? scheduler.allRecords() : []
        guard scheduler.deleteSession(record) else { return }
        sessionDrafts[record.id] = nil
        sessionAttachments[record.id] = nil
        if selection == .session(record.id) {
            let remaining = records.filter { $0.id != record.id }
            if remaining.isEmpty {
                selection = .routine(record.routineID)
            } else {
                let index = min(records.firstIndex { $0.id == record.id } ?? 0, remaining.count - 1)
                selection = .session(remaining[index].id)
            }
        }
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
        scheduler.claudeInteractive = { settings.claudeInteractive }
        notifier.notifyOnSuccess = { settings.notifyOnSuccess }
        scheduler.notifier = notifier
        notifier.requestAuthorization()
        notifier.open = { [weak self] in self?.showMainWindow(selecting: $0) }
        notifier.reply = { [weak self] session, text in self?.reply(text, to: session) }
        notifier.canReply = { [weak self] in self?.scheduler.canMessage($0) == true }
        let helper = AgentAccess.helper()
        if FileManager.default.isExecutableFile(atPath: helper.path) { scheduler.commandPath = helper.path }
    }

    /// Answers a session from its notification's Reply field, as its composer would.
    func reply(_ text: String, to session: UUID) {
        guard let record = scheduler.current(session) else { return }
        scheduler.message(text, to: record)
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
    private var macState: MacState?
    private var controlServer: ControlServer?

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
            addShowMenuAction(to: button)
        }
        panel = MenuBarPanelController(rootView: MenuBarContent().environment(model),
                                       size: NSSize(width: 340, height: 300))
        model.openMainWindow = { [weak self] in self?.showMainWindow() }
        model.openSettingsWindow = { [weak self] in self?.showSettingsWindow() }
        observeStatus()

        Updater.shared.start()
        macState = MacState(scheduler: model.scheduler)
        model.scheduler.start()
        startControlServer()
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

    /// Lets the `rota` command and agents' MCP sessions reach the scheduler.
    private func startControlServer() {
        let scheduler = model.scheduler
        let server = ControlServer { method, params in scheduler.control(method, params) }
        do {
            try server.start()
            controlServer = server
        } catch {
            Logger(subsystem: "com.wiltodelta.rota", category: "control")
                .error("Control socket failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.discardDraftAttachments()
        controlServer?.stop()
    }

    /// A run lives in Rota's process, or is watched by it, so quitting asks first
    /// and stops the running sessions the way Stop does: they are recorded as
    /// stopped and can be continued later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.scheduler.active.count
        // A shutdown never waits on Rota: its open runs continue when Rota starts again.
        guard running > 0, macState?.poweringOff != true else { return .terminateNow }
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
        // One pass over the history, which allRecords reads from disk.
        let records = model.scheduler.allRecords()
        let unread = records.filter(\.isUnread).count
        let waiting = records.filter { $0.attention != nil }.count
        var tip = running > 0 ? "Rota: \(running) running" : "Rota"
        if waiting > 0 { tip += ", \(waiting) waiting for your reply" }
        if unread > 0 { tip += ", \(unread) unread" }
        if let version = Updater.shared.pendingVersion { tip += ". Version \(version) is available" }
        button.toolTip = tip
        // The Dock shows the icon only while a window is open; the badge counts sessions to look at.
        let badge = records.filter { $0.isUnread || $0.attention != nil }.count
        NSApp.dockTile.badgeLabel = badge > 0 ? "\(badge)" : nil
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
        menu.addItem(item("Check for Updates\u{2026}", symbol: "arrow.triangle.2.circlepath",
                          action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        // The standard selector lets macOS 26+ give the item its system icon.
        let quit = NSMenuItem(title: "Quit Rota", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        showsImage(quit)
        menu.addItem(quit)
        // System appearance, under the icon (popUp opened clipped above the menu bar).
        menu.appearance = NSApp.effectiveAppearance
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    // macOS 27 hides item images unless asked (1 = visible; runtime, as CI has an older SDK).
    private func showsImage(_ item: NSMenuItem) {
        guard item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        item.setValue(1, forKey: "preferredImageVisibility")
    }

    /// The right-click menu needs a real right click; VoiceOver gets this action instead.
    private func addShowMenuAction(to button: NSStatusBarButton) {
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show Menu") { [weak self] in
                self?.showQuickMenu()
                return true
            }
        ])
    }

    private func item(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if #available(macOS 26.0, *) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        showsImage(item)
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
            let window = NSWindow(contentViewController: SettingsTabController(model: model))
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

/// View > Hide Sidebar / Show Sidebar, Control-Command-S as in Finder and Mail.
private struct SidebarToggleCommand: View {
    @State private var model = AppModel.shared

    var body: some View {
        Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
            .keyboardShortcut("s", modifiers: [.control, .command])
    }
}
