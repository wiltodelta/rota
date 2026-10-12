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
        let hosting = NSHostingController(rootView: view.environment(model))
        // The hosting view reports its SwiftUI height, which sizes the window per tab.
        hosting.sizingOptions = [.preferredContentSize]
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
        window.setFrame(frame, display: true, animate: animated)
    }
}
