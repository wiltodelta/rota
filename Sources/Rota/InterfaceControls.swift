import AppKit
import SwiftUI

/// An explicit label font survives the native button style's default font.
struct InterfaceButtonLabel: View {
    let title: String
    let symbol: String?

    var body: some View {
        Group {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .interfaceFont(.body)
    }
}

extension Button where Label == InterfaceButtonLabel {
    init(interfaceTitle: String, systemImage: String? = nil, role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            InterfaceButtonLabel(title: interfaceTitle, symbol: systemImage)
        }
    }
}

enum InterfaceChoice<Value: Hashable>: Equatable {
    case item(String, Value)
    case separator
}

/// SwiftUI's macOS Picker keeps its selected title at the native default font.
/// Keep a native popup, but give its cell the final font and fitting dimensions.
struct InterfacePicker<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let choices: [InterfaceChoice<Selection>]
    var identifier: String?
    var hidesLabel = false

    var body: some View {
        if hidesLabel { popup } else { LabeledContent(title) { popup } }
    }

    private var popup: some View {
        InterfacePopUp(selection: $selection, choices: choices, title: title, identifier: identifier)
    }
}

private struct InterfacePopUp<Selection: Hashable>: NSViewRepresentable {
    @Environment(\.interfaceScale) private var metrics
    @Environment(\.isEnabled) private var enabled
    @Binding var selection: Selection
    let choices: [InterfaceChoice<Selection>]
    let title: String
    let identifier: String?

    func makeCoordinator() -> PopUpCoordinator { PopUpCoordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(PopUpCoordinator.select(_:))
        // Intrinsic width includes the longest menu item; keep the selected value beside its arrow.
        button.alignment = .right
        button.cell?.lineBreakMode = .byTruncatingMiddle
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selectIndex = { index in
            guard choices.indices.contains(index), case .item(_, let value) = choices[index] else { return }
            selection = value
        }
        let oldTitle = button.title
        updateMenu(button)
        if let index = choices.firstIndex(where: { choice in
            if case .item(_, let value) = choice { return value == selection }
            return false
        }), index != button.indexOfSelectedItem {
            button.selectItem(at: index)
        }
        button.isEnabled = enabled
        let controlSize: NSControl.ControlSize = metrics.factor >= 1.25 ? .large : .regular
        let font = NSFont.systemFont(ofSize: metrics.points(NSFont.systemFontSize))
        let sizeChanged = button.controlSize != controlSize || button.font != font
        if button.controlSize != controlSize { button.controlSize = controlSize }
        if button.font != font { button.font = font }
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        if sizeChanged || oldTitle != button.title { button.invalidateIntrinsicContentSize() }
    }

    private func updateMenu(_ button: NSPopUpButton) {
        let titles = choices.map { choice -> String in
            if case .item(let title, _) = choice { return title }
            return ""
        }
        if button.itemArray.map(\.title) != titles {
            button.removeAllItems()
            for choice in choices {
                switch choice {
                case .item(let title, _): button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
                case .separator: button.menu?.addItem(.separator())
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let font = nsView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let width = (nsView.title as NSString).size(withAttributes: [.font: font]).width + metrics.points(34)
        let fittingWidth = max(width.rounded(.up), nsView.intrinsicContentSize.width)
        return CGSize(width: min(fittingWidth, proposal.width ?? .infinity),
                      height: max(28, (font.ascender - font.descender + metrics.points(8)).rounded(.up)))
    }
}

@MainActor
private final class PopUpCoordinator: NSObject {
    var selectIndex: (Int) -> Void = { _ in }
    @objc func select(_ sender: NSPopUpButton) { selectIndex(sender.indexOfSelectedItem) }
}
