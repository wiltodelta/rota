import SwiftUI

/// Keep each control's foreground in the same native glass effect as its surface.
struct ControlSurface<Surface: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: Surface
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(
                tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: shape)
        } else {
            content
                .background(tint ?? Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.15)) }
        }
    }
}

/// Nearby control surfaces share one sampling region without changing their layout.
struct GlassControls<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Native glass preserves focus, roles, and the system's control sizing.
struct GlassActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
