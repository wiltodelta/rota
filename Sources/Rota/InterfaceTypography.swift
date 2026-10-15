import AppKit
import SwiftUI

/// Resolve the system's actual point size before drawing, preserving its face.
@MainActor
enum InterfaceTypography {
    static let minimumPointSize: Double = 10
    static func readableSize(_ size: Double) -> Double { max(minimumPointSize, size) }

    static func font(_ style: Font.TextStyle) -> NSFont {
        let native: NSFont.TextStyle
        switch style {
        case .headline: native = .headline
        case .callout: native = .callout
        case .caption: native = .caption1
        default: native = .body
        }
        return NSFont.preferredFont(forTextStyle: native)
    }
}

private struct InterfaceFontModifier: ViewModifier {
    var style: Font.TextStyle = .body
    var size: Double?
    var weight: Font.Weight?
    var design: Font.Design = .default

    func body(content: Content) -> some View {
        let font: Font
        if let size {
            font = .system(size: InterfaceTypography.readableSize(size), design: design)
        } else {
            let native = InterfaceTypography.font(style)
            font = design == .default ? Font(native) : .system(size: native.pointSize, design: design)
        }
        return content.font(weight.map { font.weight($0) } ?? font)
    }
}

extension View {
    func interfaceFont(_ style: Font.TextStyle, weight: Font.Weight? = nil,
                       design: Font.Design = .default) -> some View {
        modifier(InterfaceFontModifier(style: style, weight: weight, design: design))
    }

    func interfaceFont(size: Double, weight: Font.Weight? = nil) -> some View {
        modifier(InterfaceFontModifier(size: size, weight: weight))
    }
}
