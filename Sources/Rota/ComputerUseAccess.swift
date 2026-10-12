import AppKit
import ApplicationServices
import CoreGraphics

/// Whether macOS lets Rota, and so the Claude sessions it starts, use the
/// computer: computer use in an interactive Claude routine is attributed to
/// Rota (`responsible=com.wiltodelta.rota` in tccd's log, 2026-10-11), and
/// without both grants its every call answers that the permissions are required.
/// The checks never prompt; the requests show macOS's own prompt, or open its
/// settings pane once Rota is listed there and switched off.
struct ComputerUseAccess: Equatable {
    var accessibility: Bool
    var screenRecording: Bool

    static func current() -> ComputerUseAccess {
        ComputerUseAccess(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    static func requestAccessibility() {
        // macOS's prompt offers its settings pane itself.
        // The value of kAXTrustedCheckOptionPrompt, a C global Swift 6 treats as mutable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { open("Privacy_ScreenCapture") }
    }

    private static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
