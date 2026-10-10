import Foundation

/// An installed copy of a harness CLI, as the settings list it.
public struct InstalledExecutable: Hashable, Identifiable, Sendable {
    public var path: String
    /// The first line of `--version`, or nil when it did not answer.
    public var version: String?
    public var id: String { path }
}

/// Finds the installed copies of each agent CLI, so the settings offer a choice
/// instead of a path to type. A copy is found on the login shell's PATH (the
/// one runs see) or in the folders installers use, and listed once per real
/// file: `~/.local/bin/grok` and the `~/.grok/bin/grok` it links to are one.
public enum ExecutableDiscovery {
    /// Every agent's installed copies. Blocks for up to a few seconds: call it
    /// off the main thread.
    public static func installedAgents() -> [Harness: [InstalledExecutable]] {
        let directories = loginPath() + knownDirectories()
        return Dictionary(uniqueKeysWithValues: Harness.agents.map { ($0, installed($0, in: directories)) })
    }

    /// Folders installers put these CLIs in, after the login PATH.
    public static func knownDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [".local/bin", ".grok/bin", ".bun/bin", ".npm-global/bin", ".volta/bin"]
            .map { home.appendingPathComponent($0).path } + ["/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// Executables named `name` in `directories`, in order, one per real file.
    public static func find(_ name: String, in directories: [String],
                            fileManager: FileManager = .default) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        for directory in directories where !directory.isEmpty {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if seen.insert(real).inserted { found.append(path) }
        }
        return found
    }

    /// The PATH a fresh login shell sets up. It starts from an empty
    /// environment, so the answer does not depend on what launched Rota: an
    /// app opened from a terminal inherits that terminal's PATH, wrappers and all.
    public static func loginPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["-i", "HOME=\(home.path)", "USER=\(NSUserName())", "LOGNAME=\(NSUserName())",
                             "SHELL=/bin/zsh", "/bin/zsh", "-lc", "printf %s \"$PATH\""]
        process.currentDirectoryURL = home
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let output = lossyUTF8(pipe.fileHandleForReading.readDataToEndOfFile())
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return output.split(separator: ":").map(String.init)
    }

    static func installed(_ harness: Harness, in directories: [String]) -> [InstalledExecutable] {
        let paths = find(harness.commandName, in: directories)
        var versions = [String: String]()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let found = version(of: paths[index])
            lock.withLock { versions[paths[index]] = found }
        }
        return paths.map { InstalledExecutable(path: $0, version: versions[$0]) }
    }

    /// The first line of `path --version`, given five seconds.
    public static func version(of path: String, timeout: TimeInterval = 5) -> String? {
        let (status, output) = ProcessLauncher.capture(path, ["--version"], in: NSTemporaryDirectory(),
                                                       timeout: timeout, errors: false)
        guard status == 0 else { return nil }
        let line = output.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

}
