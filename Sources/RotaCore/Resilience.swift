import Foundation

/// Routines cut off by the Mac or its network: a run going when the Mac slept,
/// one that failed on a network error or while offline, and one still open when
/// the Mac shut down or Rota stopped. Once the Mac is online and the agent's
/// service answers (`ServiceProbe`), a run with a session continues in it (the
/// agent gets "Continue", shown in the chat like any message), and an agent run that
/// failed on the network before it had a session runs again. Scheduled slots
/// wait for the network too (`tick`). Shell commands are never run twice behind
/// the user's back; each run continues, and each routine reruns, twice at most.
extension Scheduler {
    public static let resumeLimit = 2
    /// How long a run cut off waits before asking the service again.
    public static let retryDelay: TimeInterval = 60

    /// What the agent gets to pick the work back up, shown in the chat where the session went on.
    public static let resumeMessage = "Continue"

    /// The Mac is about to sleep: the runs going now may be cut off by it.
    public func systemWillSleep() {
        sleptThrough.formUnion(active.keys)
    }

    /// The network is back: due slots run, and cut-off runs continue.
    public func networkBecameAvailable() {
        tick()
        resumePending()
    }

    func resumable(_ record: RunRecord) -> Bool {
        guard record.terminalState == nil, record.harness.isAgent, record.sessionID != nil,
              (record.resumes ?? 0) < Self.resumeLimit else {
            return false
        }
        switch record.outcome {
        case .interrupted, .failed: return true
        default: return false
        }
    }

    /// A run that just ended: continued or run again if the Mac or its network cut it off.
    func recover(_ record: RunRecord, sleptThrough: Bool) {
        guard record.terminalState == nil else { return }
        if record.sessionID != nil { reruns[record.routineID] = nil }
        let failed: Bool
        switch record.outcome {
        case .interrupted, .failed: failed = true
        default: failed = false
        }
        guard failed, sleptThrough || !isOnline() || endedOnNetworkError(record) else { return }
        if resumable(record) {
            pendingResumes[record.id] = record.routineID
        } else if record.harness.isAgent, record.sessionID == nil,
                  (reruns[record.routineID] ?? 0) < Self.resumeLimit {
            pendingReruns[record.routineID] = record.trigger
        }
        resumePending()
    }

    func endedOnNetworkError(_ record: RunRecord) -> Bool {
        guard let path = record.logPath else { return false }
        return NetworkFailure.matches(Self.tail(of: path, characters: 4000).0)
    }

    /// An interactive Claude outlives Rota in its screen session; one still at work is not started again.
    func stillRunning(_ record: RunRecord) -> Bool {
        guard record.harness == .claude, let session = record.sessionID else { return false }
        return sessionAlive(ClaudeInteractiveRun.screenName(session))
    }

    /// Continues or reruns what waits, each once its service answers; what cannot yet waits a minute.
    func resumePending() {
        guard !pendingResumes.isEmpty || !pendingReruns.isEmpty else { return }
        guard isOnline() else { return retryLater() }
        for (recordID, routineID) in pendingResumes {
            guard let routine = routine(routineID) else {
                pendingResumes[recordID] = nil
                continue
            }
            probe(routine.harness) { [weak self] reachable in
                guard let self, reachable else { self?.retryLater(); return }
                guard self.pendingResumes.removeValue(forKey: recordID) != nil,
                      // A routine already running again leaves the older session as it ended.
                      self.active[routineID] == nil,
                      var record = self.history.records(for: routineID).first(where: { $0.id == recordID })
                else { return }
                record.resumes = (record.resumes ?? 0) + 1
                Self.log.info("Continuing \(routineID, privacy: .public) after an interruption")
                self.continueSession(record, with: Self.resumeMessage)
            }
        }
        for (routineID, trigger) in pendingReruns {
            guard let routine = routine(routineID) else {
                pendingReruns[routineID] = nil
                continue
            }
            probe(routine.harness) { [weak self] reachable in
                guard let self, reachable else { self?.retryLater(); return }
                guard self.pendingReruns.removeValue(forKey: routineID) != nil, self.active[routineID] == nil,
                      let routine = self.routine(routineID) else { return }
                self.reruns[routineID, default: 0] += 1
                Self.log.info("Running \(routineID, privacy: .public) again after a network failure")
                self.run(routine, trigger: trigger)
            }
        }
    }

    private func retryLater() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.retryScheduled = false
                self?.resumePending()
            }
        }
    }
}

/// Words agent CLIs end on when their connection failed, not their work: what
/// Node, URLSession, curl and the CLIs themselves write for a lost or missing network.
public enum NetworkFailure {
    static let phrases = [
        "connection error", "econnreset", "econnrefused", "etimedout", "enotfound", "eai_again", "getaddrinfo",
        "network is unreachable", "network connection was lost", "could not resolve host", "stream disconnected",
        "error sending request", "fetch failed", "socket hang up", "appears to be offline", "connection reset",
        "dns error", "failed to connect", "unable to connect"
    ]

    public static func matches(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return phrases.contains { lowered.contains($0) }
    }
}

/// Whether an agent's service answers over the network: any HTTP reply, even
/// an error status, means the way there works; no reply in ten seconds means it does not.
public enum ServiceProbe {
    public static func host(for harness: Harness) -> URL? {
        switch harness {
        case .claude: return URL(string: "https://api.anthropic.com")
        case .codex: return URL(string: "https://api.openai.com")
        case .grok: return URL(string: "https://api.x.ai")
        // Antigravity has no verified public inference health endpoint.
        case .antigravity, .shell: return nil
        }
    }

    public static func check(_ harness: Harness, _ done: @escaping @MainActor (Bool) -> Void) {
        guard let url = host(for: harness) else { return DispatchQueue.main.async { done(true) } }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let answered = response is HTTPURLResponse
            DispatchQueue.main.async { MainActor.assumeIsolated { done(answered) } }
        }.resume()
    }
}
