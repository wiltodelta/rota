import AppKit
import SwiftUI

/// A native menu with a button using the standard system body font.
struct InterfacePicker<Selection: Hashable, Options: View>: View {
    @Environment(\.isEnabled) private var enabled
    let title: String
    let value: String
    @Binding var selection: Selection
    let options: Options

    init(_ title: String, value: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        self.value = value
        _selection = selection
        self.options = options()
    }

    var body: some View {
        LabeledContent {
            NativePickerButton(title: title, value: value, enabled: enabled,
                               content: AnyView(Picker(title, selection: $selection) { options }.pickerStyle(.inline)))
                .frame(minHeight: 22)
        } label: {
            Text(title).interfaceFont(.body)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NativePickerButton: NSViewRepresentable {
    let title: String
    let value: String
    let enabled: Bool
    let content: AnyView

    func makeNSView(context: Context) -> InterfaceMenuButton { InterfaceMenuButton() }

    func updateNSView(_ button: InterfaceMenuButton, context: Context) {
        button.title = value
        let font = InterfaceTypography.font(.body)
        button.font = font
        button.attributedTitle = NSAttributedString(string: value,
                                                     attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        button.contentTintColor = .labelColor
        button.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        button.isEnabled = enabled
        button.menu = NSHostingMenu(rootView: content)
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(value)
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InterfaceMenuButton, context: Context) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width),
                      height: max(20, ideal.height))
    }
}

private final class InterfaceMenuButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .rounded
        alignment = .right
        imagePosition = .imageTrailing
        lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        target = self
        action = #selector(showChoices)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func showChoices() {
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125 { showChoices() } else { super.keyDown(with: event) }
    }
}
