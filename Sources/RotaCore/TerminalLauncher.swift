import AppKit
import UniformTypeIdentifiers

/// A terminal app Rota knows how to hand a script to.
public enum KnownTerminal: String, CaseIterable, Sendable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"

    public var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }

    /// The arguments that make a new instance run `script`, for an app that does
    /// not open a script handed to it as a document. Ghostty's `-e` sets the
    /// first window's command (ghostty.org/docs/config/reference, 2026-10-10).
    func arguments(running script: String) -> [String]? {
        self == .ghostty ? ["-e", script] : nil
    }

    public var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }
}

/// Opens an executable script in a terminal app: the one picked, or the app
/// macOS opens scripts with. A `.command` file needs no Automation permission,
/// unlike scripting the terminal.
public enum TerminalLauncher {
    /// The terminals among `KnownTerminal` that are installed.
    public static func installed() -> [KnownTerminal] {
        KnownTerminal.allCases.filter { $0.url != nil }
    }

    /// The terminal macOS treats as the default. macOS has no one setting for
    /// it: "Make iTerm2 Default Term" hands iTerm2 executables and shell scripts
    /// while `.command` files stay with Terminal (read on this Mac 2026-10-10), so
    /// the executables' app comes first and the `.command` handler is the fallback.
    public static func defaultTerminal() -> URL? {
        [UTType.unixExecutable, UTType(filenameExtension: "command")].compactMap { $0 }
            .lazy.compactMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.first
    }

    /// Opens `script` in the app at `app`, or in the default terminal when nil.
    public static func open(_ script: URL, in app: URL?, completion: @escaping @Sendable (Error?) -> Void) {
        let process = openingProcess(script, in: app ?? defaultTerminal())
        process.terminationHandler = { process in
            let error = process.terminationStatus == 0 ? nil : NSError(
                domain: "com.wiltodelta.rota.terminal", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "The terminal could not be opened."])
            completion(error)
        }
        do {
            try process.run()
        } catch {
            completion(error)
        }
    }

    static func openingProcess(_ script: URL, in app: URL?,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // NSWorkspace's configuration environment only adds overrides: omitted
        // child-session markers still leak. Give open a fully replaced environment.
        process.environment = ProcessLauncher.baseEnvironment(environment)
        process.standardInput = FileHandle.nullDevice
        let known = app.flatMap { Bundle(url: $0)?.bundleIdentifier }.flatMap(KnownTerminal.init(rawValue:))
        if let app, let arguments = known?.arguments(running: script.path) {
            process.arguments = ["-n", "-a", app.path, "--args"] + arguments
        } else {
            process.arguments = (app.map { ["-a", $0.path] } ?? []) + [script.path]
        }
        return process
    }
}
