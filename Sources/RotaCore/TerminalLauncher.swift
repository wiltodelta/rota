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
        guard let app = app ?? defaultTerminal() else {
            NSWorkspace.shared.open(script)
            return completion(nil)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let known = Bundle(url: app)?.bundleIdentifier.flatMap(KnownTerminal.init(rawValue:))
        if let arguments = known?.arguments(running: script.path) {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in completion(error) }
        } else {
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: configuration) { _, error in
                completion(error)
            }
        }
    }
}
