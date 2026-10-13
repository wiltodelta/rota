import AppKit
import SwiftUI

/// Layout uses point sizes, so fonts and vector shapes are drawn at their final resolution.
struct InterfaceMetrics {
    let scale: Double

    func callAsFunction(_ points: CGFloat) -> CGFloat { points * scale }

    /// Keep interactive targets usable even at the smallest zoom.
    func target(_ points: CGFloat) -> CGFloat { max(20, self(points)) }

    func surfaceWidth(_ points: CGFloat, available: CGFloat) -> CGFloat {
        min(self(points), max(240, available - 40))
    }

    func surfaceHeight(_ points: CGFloat, available: CGFloat) -> CGFloat {
        min(self(points), max(180, available - 100))
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
    var interfaceMetrics: InterfaceMetrics { InterfaceMetrics(scale: interfaceTextScale) }
}

private struct SettingsPaneModifier: ViewModifier {
    @Environment(\.interfaceMetrics) private var metrics

    func body(content: Content) -> some View {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1024, height: 800)
        content.formStyle(.grouped)
            .frame(width: metrics.surfaceWidth(520, available: available.width))
            .frame(maxHeight: available.height - 100)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Content buttons grow continuously; their hit area never falls below 20 pt.
struct InterfaceButtonStyle: ButtonStyle {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(.body)
            .padding(.horizontal, metrics(8))
            .padding(.vertical, metrics(4))
            .frame(minWidth: metrics.target(28), minHeight: metrics.target(28))
            .foregroundStyle(prominent ? accentInk
                             : configuration.role == .destructive ? Color.errorText : Color.primary)
            .background(prominent ? Color.accentColor
                         : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07),
                        in: RoundedRectangle(cornerRadius: metrics(6)))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .overlay {
                if prominent && configuration.isPressed {
                    RoundedRectangle(cornerRadius: metrics(6))
                        .strokeBorder(Color.primary.opacity(0.4), lineWidth: metrics(1))
                }
            }
    }

    private var accentInk: Color {
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
    @Environment(\.interfaceMetrics) private var metrics

    func body(content: Content) -> some View {
        content.padding(.vertical, metrics(6))
            .padding(.horizontal, metrics(4))
            .frame(minHeight: metrics.target(28))
            .contentShape(Rectangle())
    }
}

extension View {
    /// Settings grow with zoom and scroll before reaching the screen's edges.
    func settingsPane() -> some View { modifier(SettingsPaneModifier()) }

    func interfaceFooterTarget() -> some View { modifier(InterfaceFooterTarget()) }
}
