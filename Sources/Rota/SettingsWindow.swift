import AppKit
import SwiftUI

/// Settings in toolbar tabs, as macOS apps lay them out: General, Chat and
/// Agents. The window takes each tab's height and remembers the last tab.
final class SettingsTabController: NSTabViewController {
    private static let lastTab = "settingsTab"

    init(model: AppModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        add(GeneralSettings(), label: "General", symbol: "gearshape", model: model)
        add(ChatSettings(), label: "Chat", symbol: "textformat.size", model: model)
        add(AgentSettings(), label: "Agents", symbol: "terminal", model: model)
        selectedTabViewItemIndex = min(UserDefaults.standard.integer(forKey: Self.lastTab), tabViewItems.count - 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func add(_ view: some View, label: String, symbol: String, model: AppModel) {
        let hosting = SettingsPaneController(rootView: view.environment(model))
        // The tab controller copies the selected child's title to the window.
        hosting.title = label
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.lastTab)
        fitWindow(animated: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The window was titled before the remembered tab was selected; it takes the tab's name.
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
        fitWindow(animated: false)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === tabViewItems[selectedTabViewItemIndex].viewController { fitWindow(animated: true) }
    }

    /// Resizes the window to the selected tab, keeping its top edge where it is.
    private func fitWindow(animated: Bool) {
        guard let window = view.window,
              let size = tabViewItems[selectedTabViewItemIndex].viewController?.preferredContentSize,
              size.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height,
                                                            width: size.width, height: size.height))
        frame.origin.y = window.frame.maxY - frame.height
        if let visible = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// The form keeps its natural height inside a scroll view when the screen is shorter.
private final class SettingsPaneController: NSViewController {
    private let hosting: NSHostingController<AnyView>

    init(rootView: some View) {
        hosting = NSHostingController(rootView: AnyView(rootView))
        hosting.sizingOptions = [.preferredContentSize]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addChild(hosting)
        scroll.documentView = hosting.view
        view = scroll
        updateSize()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard isViewLoaded else { return }
        updateSize()
    }

    private func updateSize() {
        let size = hosting.preferredContentSize
        guard size.height > 0, preferredContentSize != size else { return }
        hosting.view.setFrameSize(size)
        preferredContentSize = size
    }
}
