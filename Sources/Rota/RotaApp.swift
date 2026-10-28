import AppKit
import os
import RotaCore
import SwiftUI

@main
struct RotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A menu-bar accessory: the status item, its panel and the window are
        // AppKit, owned by AppDelegate. This scene only satisfies `App`; its menu
        // items are rerouted so Settings... (Command-,) opens Settings in the main window.
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
            // A single zoom for all app content; chat fonts remain independently configurable.
            CommandGroup(after: .toolbar) {
                SidebarToggleCommand()
                Divider()
                Button("Zoom In") { AppModel.shared.interfaceScale.increase() }
                    .disabled(!AppModel.shared.interfaceScale.canIncrease)
                    .keyboardShortcut("+")
                Button("Zoom Out") { AppModel.shared.interfaceScale.decrease() }
                    .disabled(!AppModel.shared.interfaceScale.canDecrease)
                    .keyboardShortcut("-")
                Button("Reset") { AppModel.shared.interfaceScale.reset() }
                    .keyboardShortcut("0")
                Divider()
                Menu("Chat Zoom") {
                    Button("Zoom In") { AppModel.shared.chatText.increase() }
                        .disabled(!AppModel.shared.chatText.canIncrease)
                        .keyboardShortcut("+", modifiers: [.command, .option])
                    Button("Zoom Out") { AppModel.shared.chatText.decrease() }
                        .disabled(!AppModel.shared.chatText.canDecrease)
                        .keyboardShortcut("-", modifiers: [.command, .option])
                    Button("Reset") { AppModel.shared.chatText.reset() }
                        .keyboardShortcut("0", modifiers: [.command, .option])
                }
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
        didSet {
            UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible")
            if sidebarVisible, !oldValue { keepWindowWidth() }
        }
    }
    /// SwiftUI widens the window by the sidebar's width when the sidebar returns.
    @ObservationIgnored var keepWindowWidth: () -> Void = {}

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
    let interfaceScale: InterfaceScaleSettings
    let chatText: ChatTextSettings
    private let notifier = Notifier()
    @ObservationIgnored var openMainWindow: () -> Void = {}

    private init() {
        let scale = InterfaceScaleSettings()
        interfaceScale = scale
        chatText = ChatTextSettings(interfaceScale: scale)
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
        SidebarItem.latest(routineID: routineID, records: scheduler.records(for: routineID))
    }

    /// The Settings section the main window shows; nil shows routines and sessions.
    var settingsPane: SettingsPane? {
        didSet {
            if let settingsPane { UserDefaults.standard.set(settingsPane.rawValue, forKey: SettingsPane.lastKey) }
            // Settings' sections and Back live in the sidebar, so it shows a hidden one.
            if oldValue == nil, settingsPane != nil, !sidebarVisible { keepWindowWidth() }
        }
    }
    /// What Back returns to.
    @ObservationIgnored var selectionBeforeSettings: SidebarItem?
    /// Settings shows the sidebar without changing the saved preference.
    var sidebarShown: Bool { sidebarVisible || settingsPane != nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "app")
    private let model = AppModel.shared
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanelController!
    private var mainWindow: NSWindow?
    private var widthGuard: NSObjectProtocol?
    private var macState: MacState?
    private var controlServer: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            Self.log.info("Another instance is running; quitting")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                     NSMenu.didRemoveItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuCommandsChanged(_:)),
                                                   name: name, object: nil)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            addShowMenuAction(to: button)
        }
        panel = MenuBarPanelController(rootView: MenuBarContent()
            .interfaceScale(model.interfaceScale).environment(model),
                                       size: NSSize(width: 340, height: 300), contentBackgroundOpacity: 0)
        model.openMainWindow = { [weak self] in self?.showMainWindow() }
        model.keepWindowWidth = { [weak self] in self?.keepMainWindowWidth() }
        observeStatus()

        Updater.shared.start()
        macState = MacState(scheduler: model.scheduler)
        model.scheduler.start()
        startControlServer()
        if model.scheduler.routines.isEmpty { showMainWindow() }
        // Development hooks: open settings, or the panel, where a capture script can find them.
        if let pane = ProcessInfo.processInfo.environment["ROTA_OPEN_SETTINGS"] {
            model.showSettings(SettingsPane(rawValue: pane) ?? .last)
        }
        if ProcessInfo.processInfo.environment["ROTA_OPEN_PANEL"] != nil, let screen = NSScreen.main {
            panel.show(topLeft: NSPoint(x: screen.visibleFrame.midX - 170, y: screen.visibleFrame.maxY - 40))
            Self.log
                .info("Panel window \(self.panel.windowNumber, privacy: .public)")
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func menuCommandsChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              NSApp.mainMenu?.items.contains(where: { $0.submenu === menu }) == true else { return }
        // Wait until SwiftUI and AppKit finish assembling the command group.
        DispatchQueue.main.async { MainMenu.separateFullScreen(in: menu) }
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
        let server = ControlServer { method, params in await scheduler.controlRequest(method, params) }
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

    /// A run lives in Rota's process, or is watched by it, so a person's quit asks
    /// first and stops the running sessions the way Stop does: they are recorded
    /// as stopped and can be continued later. A shutdown or an update relaunch
    /// asks nothing and leaves them open for the next launch to follow or continue.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.scheduler.active.count
        let unattended = macState?.poweringOff == true || Updater.shared.relaunchingForUpdate
        guard running > 0, !unattended else {
            if running > 0 { Self.log.info("Quitting unattended; \(running) open runs continue after relaunch") }
            return .terminateNow
        }
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
        // One pass over the scheduler's cached history snapshot.
        let records = model.scheduler.allRecords()
        let unread = records.filter(\.isUnread).count
        let waiting = records.filter { $0.attention != nil }.count
        var tip = running > 0 ? "Rota: \(running) running" : "Rota"
        if waiting > 0 { tip += ", \(waiting) waiting for your reply" }
        if unread > 0 { tip += ", \(unread) unread" }
        if let version = Updater.shared.pendingVersion { tip += ". Version \(version) is available" }
        button.toolTip = tip
        // The Dock shows the icon only while a window is open; count sessions needing a response.
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
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
        menu.addItem(item("Settings\u{2026}", symbol: "gearshape", action: #selector(showSettingsFromMenu), key: ","))
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
    @objc private func showSettingsFromMenu() { model.showSettings() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    // MARK: Windows

    private func showMainWindow() {
        panel.close()
        if mainWindow == nil {
            let content = MainWindow().interfaceScale(model.interfaceScale).environment(model)
            let hosting = NSHostingController(rootView: content)
            hosting.sceneBridgingOptions = []
            let window = NSWindow(contentViewController: MainWindowContainer(body: hosting))
            // One window: no tab bar, no tab items in the View and Window menus.
            window.tabbingMode = .disallowed
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.toolbar = WindowToolbarOverlay.makeToolbar()
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
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

    /// SwiftUI widens the window to keep the detail's width when the sidebar
    /// returns, and neither the split item's collapse behavior nor a `setFrame`
    /// override stops it. Putting the frame back as soon as it grows makes the
    /// detail give up the room instead, as a dragged divider does.
    private func keepMainWindowWidth() {
        guard let window = mainWindow, window.isVisible else { return }
        let frame = window.frame
        dropWidthGuard()
        widthGuard = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                            object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard window.frame.width > frame.width, window.frame.height == frame.height else { return }
                window.setFrame(frame, display: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.dropWidthGuard() }
    }

    private func dropWidthGuard() {
        widthGuard.map(NotificationCenter.default.removeObserver)
        widthGuard = nil
    }

    /// A window comes forward reliably only from a regular app, so Rota takes a
    /// Dock icon while its window is open and gives it up when it closes.
    private func present(_ window: NSWindow?) {
        // Reapply the label when entering the Dock: AppKit can retain the value set while accessory
        // without displaying it, and assigning the same value again does not redraw the badge.
        if NSApp.activationPolicy() != .regular { NSApp.dockTile.badgeLabel = nil }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        updateStatusItem()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        // Reopening shows routines and sessions again.
        model.closeSettings()
        NSApp.setActivationPolicy(.accessory)
    }
}
