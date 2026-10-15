import AppKit
import SwiftUI

/// Bound forms and sheets to the visible screen and parent window.
struct InterfaceMetrics {
    func surfaceWidth(_ points: CGFloat, available: CGFloat) -> CGFloat {
        min(points, max(240, available - 40))
    }

    func surfaceHeight(_ points: CGFloat, available: CGFloat) -> CGFloat {
        min(points, max(180, available - 100))
    }

    @MainActor
    func sheetWidth(_ points: CGFloat) -> CGFloat {
        surfaceWidth(points, available: NSApp.mainWindow?.contentLayoutRect.width ?? 820)
    }

    @MainActor
    func sheetHeight(_ points: CGFloat) -> CGFloat {
        surfaceHeight(points, available: NSApp.mainWindow?.contentLayoutRect.height ?? 600)
    }
}

extension EnvironmentValues {
    var interfaceMetrics: InterfaceMetrics { InterfaceMetrics() }
}

private struct SettingsPaneModifier: ViewModifier {
    @Environment(\.interfaceMetrics) private var metrics

    func body(content: Content) -> some View {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1024, height: 800)
        content.formStyle(.grouped)
            // Keep all five native Settings tabs reachable.
            .frame(width: max(420, metrics.surfaceWidth(520, available: available.width)))
            .frame(maxHeight: available.height - 100)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Choose readable text for the chat send button under the system accent.
enum AccentInk {
    static func accentInk(for colorScheme: ColorScheme) -> Color {
        var ink = NSColor.labelColor
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance { ink = Self.ink(for: .controlAccentColor) }
        return Color(nsColor: ink)
    }

    /// Choose the higher-contrast ink, including custom system accent colors.
    static func ink(for accent: NSColor) -> NSColor {
        guard let rgb = accent.usingColorSpace(.sRGB) else { return .labelColor }
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05 ? .white : .black
    }
}

private struct InterfaceFooterTarget: ViewModifier {

    func body(content: Content) -> some View {
        content.padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Settings scroll before reaching the screen's edges.
    func settingsPane() -> some View { modifier(SettingsPaneModifier()) }

    func interfaceFooterTarget() -> some View { modifier(InterfaceFooterTarget()) }
}
