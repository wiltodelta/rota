import AppKit
import SwiftUI

/// App zoom and chat text size are independent preferences.
@MainActor
@Observable
final class AppZoomSettings {
    static let range = 50...200
    private let defaults: UserDefaults
    var percent: Int {
        didSet {
            let clamped = Self.normalize(percent)
            if percent != clamped { percent = clamped }
            defaults.set(percent, forKey: "appZoomPercent")
        }
    }

    var scale: Double { Double(percent) / 100 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: "appZoomPercent") as? Int ?? 100
        percent = Self.normalize(stored)
    }

    private static func normalize(_ value: Int) -> Int {
        let bounded = min(max(value, range.lowerBound), range.upperBound)
        return Int((Double(bounded) / 10).rounded()) * 10
    }

    func increase() { percent += 10 }
    func decrease() { percent -= 10 }
    func reset() { percent = 100 }
}

/// Resolve the system's actual point size before drawing, preserving its face.
@MainActor
enum InterfaceTypography {
    static func font(_ style: Font.TextStyle, scale: Double) -> NSFont {
        let native: NSFont.TextStyle
        switch style {
        case .headline: native = .headline
        case .callout: native = .callout
        case .caption: native = .caption1
        default: native = .body
        }
        let base = NSFont.preferredFont(forTextStyle: native)
        return NSFont(descriptor: base.fontDescriptor, size: base.pointSize * scale) ?? base
    }
}

private struct InterfaceTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    var interfaceTextScale: Double {
        get { self[InterfaceTextScaleKey.self] }
        set { self[InterfaceTextScaleKey.self] = newValue }
    }
}

private struct AppZoomModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .environment(\.interfaceTextScale, model.appZoom.scale)
            .font(Font(InterfaceTypography.font(.body, scale: model.appZoom.scale)))
            .environment(\.defaultMinListRowHeight, 28 * model.appZoom.scale)
            .controlSize(model.appZoom.scale > 1.2 ? .large : model.appZoom.scale < 0.8 ? .small : .regular)
            .buttonStyle(InterfaceButtonStyle())
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.interfaceTextScale) private var scale
    var style: Font.TextStyle = .body
    var size: Double?
    var weight: Font.Weight?
    var design: Font.Design = .default

    func body(content: Content) -> some View {
        let native = InterfaceTypography.font(style, scale: scale)
        let pointSize = size.map { $0 * scale } ?? native.pointSize
        let font = design == .default && size == nil
            ? Font(native) : .system(size: pointSize, design: design)
        content.font(weight.map { font.weight($0) } ?? font)
    }
}

extension View {
    func appZoom() -> some View { modifier(AppZoomModifier()) }

    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(style: style, weight: weight, design: design))
    }

    func scaledFont(size: Double, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight))
    }
}
