import AppKit
import CoreText
import os

/// Fonts are private to this process; nothing is installed in the user's font library.
@MainActor
enum BundledFonts {
    static let interfaceFamily = "IBM Plex Sans"
    static let monospacedFamily = "JetBrains Mono"

    static func register() { _ = registration }

    static func resourceBundle(in application: Bundle = .main) -> Bundle? {
        // SwiftPM's command-line build does not search Contents/Resources.
        // Resolve packaged resources explicitly; use .module only for tests/CLI builds.
        if application.bundleURL.pathExtension == "app" {
            guard let url = application.resourceURL?.appendingPathComponent("Rota_Rota.bundle") else {
                return nil
            }
            return Bundle(url: url)
        }
        return .module
    }

    private static let registration: Void = {
        let log = Logger(subsystem: "com.wiltodelta.rota", category: "fonts")
        guard let folder = resourceBundle()?.url(forResource: "Fonts", withExtension: nil),
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            log.error("Bundled fonts are missing")
            return
        }
        for case let url as URL in files where url.pathExtension == "ttf" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let reason = error?.takeRetainedValue(),
               CFErrorGetCode(reason) != CTFontManagerError.alreadyRegistered.rawValue {
                log.error("Couldn't register \(url.lastPathComponent, privacy: .public): \(reason)")
            }
        }
    }()
}
