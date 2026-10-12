import AppKit
import Network
import os
import RotaCore

/// What the Mac is doing that decides when routines can run: whether it is
/// online, going to sleep, or shutting down. The scheduler waits for the
/// network before a due slot or a cut-off session, and a shutdown quits Rota
/// without asking, leaving its open runs to continue on the next launch.
@MainActor
final class MacState {
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "power")
    private let monitor = NWPathMonitor()
    /// nil until the monitor's first answer: unknown counts as online, as most launches are.
    private(set) var online: Bool?
    /// Set when macOS announces a shutdown, restart or logout.
    private(set) var poweringOff = false

    init(scheduler: Scheduler) {
        scheduler.isOnline = { [weak self] in self?.online ?? true }
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.online != satisfied else { return }
                self.online = satisfied
                Self.log.info("Network \(satisfied ? "available" : "unavailable", privacy: .public)")
                if satisfied { scheduler.networkBecameAvailable() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.wiltodelta.rota.network"))
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Self.log.info("Mac going to sleep")
                scheduler.systemWillSleep()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.info("Mac woke")
                // The network often comes back a moment later; the monitor then runs what waits.
                if self?.online != false { scheduler.networkBecameAvailable() }
            }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.info("Mac shutting down")
                self?.poweringOff = true
            }
        }
    }
}
