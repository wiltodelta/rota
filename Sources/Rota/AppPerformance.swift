import AppKit
import RotaCore

/// Connects local diagnostics to the app lifecycle without observing conversation content.
@MainActor
final class AppPerformance {
    private let diagnostics = PerformanceDiagnostics.shared
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel) {
        let info = Bundle.main.infoDictionary ?? [:]
        diagnostics.start(directory: StorageLocation.standard.logs.appendingPathComponent("Diagnostics"), metadata: [
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "appBuild": info["CFBundleVersion"] as? String ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpuCount": String(ProcessInfo.processInfo.processorCount),
            "launchID": UUID().uuidString
        ]) { [weak model] in
            var context = PerformanceContext()
            guard let model else { return context }
            context.activeRuns = model.scheduler.active.count
            context.routineCount = model.scheduler.routines.count
            context.appActive = NSApp.isActive
            let window = NSApp.windows.first {
                $0.isVisible && ($0 is MenuBarPanelWindow || $0.contentViewController is MainWindowContainer)
            }
            context.windowWidth = Double(window?.frame.width ?? 0)
            context.windowHeight = Double(window?.frame.height ?? 0)
            if model.settingsPane != nil {
                context.surface = .settings
            } else if window is NSPanel, window?.isVisible == true {
                context.surface = .panel
            } else if window?.isVisible == true {
                switch model.selection {
                case .session: context.surface = .conversation
                case .routine: context.surface = .routine
                case nil: context.surface = .empty
                }
            }
            return context
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                PerformanceDiagnostics.shared.setSleeping(sleeping)
            })
        }
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        diagnostics.stop()
    }
}
