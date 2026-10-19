import AppKit
import Observation

/// Preserve NSTabViewController's native toolbar, selection and placement.
/// A plain view around each button keeps AppKit from normalizing its font and size.
class ScalableSettingsTabController: NSTabViewController {
    private let scale: InterfaceScaleSettings
    private var tabViews: [String: SettingsTabItemView] = [:]

    init(scale: InterfaceScaleSettings) {
        self.scale = scale
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        observeScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                          willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let inherited = super.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag)
        guard let index = tabViewItems.firstIndex(where: { ($0.identifier as? String) == identifier.rawValue })
            else { return inherited }
        let item = inherited ?? NSToolbarItem(itemIdentifier: identifier)
        item.label = tabViewItems[index].label
        item.image = tabViewItems[index].image
        let tab = SettingsTabItemView(title: item.label, image: item.image, target: self,
                                      action: #selector(selectTab))
        tab.button.tag = index
        tab.button.setAccessibilityIdentifier("settingsTab-\(item.label)")
        tabViews[identifier.rawValue] = tab
        tab.update(factor: scale.factor, selected: selectedTabViewItemIndex == index)
        item.view = tab
        return item
    }

    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        _ = super.toolbarDefaultItemIdentifiers(toolbar)
        return [.flexibleSpace] + tabIdentifiers + [.flexibleSpace]
    }

    override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        _ = super.toolbarAllowedItemIdentifiers(toolbar)
        return [.flexibleSpace] + tabIdentifiers
    }

    override func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        _ = super.toolbarSelectableItemIdentifiers(toolbar)
        return tabIdentifiers
    }

    private var tabIdentifiers: [NSToolbarItem.Identifier] {
        tabViewItems.compactMap { item in
            (item.identifier as? String).map { NSToolbarItem.Identifier($0) }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadToolbar()
        updateTabs()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if isViewLoaded, let identifier = tabViewItem?.identifier as? String {
            view.window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(identifier)
        }
        updateTabs()
    }

    @objc private func selectTab(_ sender: NSButton) { selectedTabViewItemIndex = sender.tag }

    private func observeScale() {
        withObservationTracking {
            _ = scale.factor
            updateTabs()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.reloadToolbar()
                self?.observeScale()
            }
        }
    }

    /// The tab controller's toolbar fixes custom item heights at their first size.
    /// Keep its identifiers and delegate, but let a fresh native toolbar measure the views.
    private func reloadToolbar() {
        guard isViewLoaded, let window = view.window, let previous = window.toolbar else { return }
        let toolbar = NSToolbar(identifier: previous.identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        tabViews.removeAll()
        for (index, identifier) in toolbarDefaultItemIdentifiers(previous).enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        window.toolbarStyle = .expanded
        window.toolbar = toolbar
        toolbar.displayMode = .iconOnly
        if let identifier = tabViewItems[selectedTabViewItemIndex].identifier as? String {
            toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(identifier)
        }
    }

    private func updateTabs() {
        for tab in tabViews.values {
            tab.update(factor: scale.factor, selected: tab.button.tag == selectedTabViewItemIndex)
        }
    }
}

final class SettingsTabItemView: NSView {
    // Native link blue is too dark on the selected toolbar background in dark appearance.
    private static let selectedCaptionColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 122 / 255, green: 186 / 255, blue: 1, alpha: 1) : .linkColor
    }
    let button: NSButton
    let caption: NSTextField
    let imageView = NSImageView()
    private let symbol: NSImage?
    private var factor: CGFloat = 1
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 64)
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 68)

    init(title: String, image: NSImage?, target: AnyObject?, action: Selector) {
        symbol = image
        button = NSButton(title: "", target: target, action: action)
        caption = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.setAccessibilityLabel(title)
        caption.alignment = .center
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(button)
        addSubview(imageView)
        addSubview(caption)
        setAccessibilityChildren([button])
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(factor: CGFloat, selected: Bool) {
        self.factor = factor
        caption.font = .systemFont(ofSize: 13 * factor)
        imageView.image = symbol?.withSymbolConfiguration(.init(pointSize: 24 * factor, weight: .regular))
        let color = selected ? Self.selectedCaptionColor : .labelColor.withAlphaComponent(0.66)
        caption.textColor = color
        imageView.contentTintColor = color
        button.setAccessibilityValue(selected ? "Selected" : "")
        let size = intrinsicContentSize
        widthConstraint.constant = size.width
        heightConstraint.constant = size.height
        invalidateIntrinsicContentSize()
        setFrameSize(size)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let imageSize = 32 * factor
        let captionHeight = caption.intrinsicContentSize.height
        let bottom = (bounds.height - imageSize - 6 * factor - captionHeight) / 2
        caption.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: captionHeight)
        imageView.frame = NSRect(x: (bounds.width - imageSize) / 2, y: caption.frame.maxY + 6 * factor,
                                 width: imageSize, height: imageSize)
        button.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : button
    }

    override var intrinsicContentSize: NSSize {
        let font = caption.font ?? NSFont.systemFont(ofSize: 13)
        let label = (caption.stringValue as NSString).size(withAttributes: [.font: font])
        return NSSize(width: max(label.width, 32 * factor) + 16 * factor,
                      height: 68 * factor)
    }
}
