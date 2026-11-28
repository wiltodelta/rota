import Foundation
import os

/// All mutable state and file I/O belong to queue. Main-queue probes never wait on it.
public final class PerformanceDiagnostics: @unchecked Sendable {
    public static let shared = PerformanceDiagnostics()
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "performance")
    private let queue = DispatchQueue(label: "com.wiltodelta.rota.performance", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var journal: PerformanceLog?
    private var probes = PerformanceProbeState()
    private var resources: PerformanceResources?
    private var lastSample: TimeInterval = 0
    private var context = PerformanceContext()
    private var transcript = TranscriptPerformance()

    public init() {}

    public func start(directory: URL, metadata: [String: String],
                      context: @escaping @MainActor @Sendable () -> PerformanceContext) {
        queue.async { [self] in
            guard timer == nil else { return }
            do {
                journal = try PerformanceLog(directory: directory, metadata: metadata)
            } catch {
                Self.log.error("Couldn't start local performance diagnostics: \(error, privacy: .private)")
                return
            }
            probes.setSleeping(false)
            resources = nil
            lastSample = 0
            self.context = PerformanceContext()
            transcript = TranscriptPerformance()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick(context: context) }
            self.timer = timer
            timer.resume()
        }
    }

    public func setSleeping(_ sleeping: Bool) {
        queue.async { [self] in
            guard journal != nil else { return }
            probes.setSleeping(sleeping)
            resources = nil
            lastSample = 0
            write(PerformanceEvent(kind: sleeping ? .sleep : .wake))
        }
    }

    public func recordTranscript(seconds: TimeInterval, items: Int, earlier: Bool, shell: Bool) {
        queue.async { [self] in
            guard journal != nil else { return }
            transcript.add(seconds: seconds, items: items, earlier: earlier, shell: shell)
            if seconds >= 0.1 {
                var slow = TranscriptPerformance()
                slow.add(seconds: seconds, items: items, earlier: earlier, shell: shell)
                write(PerformanceEvent(kind: .slowTranscript, durationMs: seconds * 1_000,
                                       context: context, transcript: slow))
            }
        }
    }

    private func tick(context provider: @escaping @MainActor @Sendable () -> PerformanceContext) {
        guard journal != nil, !probes.sleeping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let delay = probes.stalled(at: now) {
            write(PerformanceEvent(kind: .mainThreadStall, durationMs: delay * 1_000, context: context))
        }
        if now - lastSample >= 10 {
            let next = PerformanceResources.current()
            write(PerformanceEvent(kind: .resources, cpuPercent: next.cpuPercent(since: resources),
                                   residentBytes: next.residentBytes, durationMs: probes.maxDelay * 1_000,
                                   context: context, transcript: transcript))
            resources = next
            lastSample = now
            probes.maxDelay = 0
            transcript = TranscriptPerformance()
        }
        guard let probe = probes.begin(at: now) else { return }
        DispatchQueue.main.async { [weak self] in
            let received = ProcessInfo.processInfo.systemUptime
            let context = provider()
            self?.queue.async { [weak self] in self?.received(probe, at: received, context: context) }
        }
    }

    private func received(_ probe: PerformanceProbeState.Probe, at now: TimeInterval,
                          context: PerformanceContext) {
        guard journal != nil, let delay = probes.finish(probe, at: now) else { return }
        self.context = context
        if delay >= 0.25 {
            write(PerformanceEvent(kind: .mainThreadDelay, durationMs: delay * 1_000, context: context))
        }
    }

    private func write(_ event: PerformanceEvent) {
        do {
            try journal?.append(event)
        } catch {
            Self.log.error("Local performance diagnostics stopped after a write failure: \(error, privacy: .private)")
            timer?.cancel()
            timer = nil
            journal = nil
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            write(PerformanceEvent(kind: .shutdown, context: context, transcript: transcript))
            journal = nil
            probes.setSleeping(true)
            transcript = TranscriptPerformance()
        }
    }
}
