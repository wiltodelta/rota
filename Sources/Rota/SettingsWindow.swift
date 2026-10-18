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
        let hosting = SettingsPaneController(rootView: view.interfaceScale(model.interfaceScale).environment(model))
        // The tab controller copies the selected child's title to the window.
        hosting.title = label
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        hosting.onContentSizeChange = { [weak self, weak hosting] in
            guard let self, let hosting,
                  self.tabViewItems.indices.contains(self.selectedTabViewItemIndex),
                  self.tabViewItems[self.selectedTabViewItemIndex].viewController === hosting else { return }
            self.fitWindow(animated: true)
        }
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

    /// Resizes the window to the selected tab, keeping its top edge where it is.
    private func fitWindow(animated: Bool) {
        guard isViewLoaded, let window = view.window,
              tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPaneController,
              pane.contentSize.height > 0 else { return }
        let size = pane.contentSize
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height,
                                                            width: size.width, height: size.height))
        frame.origin.y = window.frame.maxY - frame.height
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// The form keeps its natural height inside a scroll view when the screen is shorter.
final class SettingsPaneController: NSViewController {
    private let hosting: NSHostingController<AnyView>
    private var pendingSize: CGSize?
    private(set) var contentSize: CGSize = .zero
    var onContentSizeChange: (() -> Void)?

    init(rootView: some View) {
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = [.preferredContentSize]
        super.init(nibName: nil, bundle: nil)
        hosting.rootView = AnyView(rootView.onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
            self?.scheduleSize(size)
        })
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
        updateSize(hosting.preferredContentSize)
    }

    /// The hosting controller's preferred size can retain its first proposal.
    /// Follow the form's measured size and coalesce updates after SwiftUI layout.
    private func scheduleSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        let scheduled = pendingSize != nil
        pendingSize = size
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let size = self.pendingSize else { return }
            self.pendingSize = nil
            self.updateSize(size)
        }
    }

    private func updateSize(_ size: CGSize) {
        guard size.height > 0, contentSize != size else { return }
        hosting.view.setFrameSize(size)
        // preferredContentSize adds height constraints to the viewport itself.
        // Keep the document's natural size separate so the viewport can scroll.
        contentSize = size
        onContentSizeChange?()
    }
}
