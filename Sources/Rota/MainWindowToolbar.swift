import AppKit
import SwiftUI

/// Preserve the original detail-column navigation, title and trailing action group.
struct MainWindowToolbar: View {
    @Environment(\.interfaceScale) private var metrics
    let title: String
    let sidebarWidth: CGFloat
    let toggleSidebar: () -> Void
    let importRoutines: () -> Void
    let newRoutine: () -> Void
    /// Settings keeps its sections in the sidebar: it dims the toggle and hides the routine actions.
    let showsActions: Bool

    var body: some View {
        HStack(spacing: metrics.points(12)) {
            Button(action: toggleSidebar) {
                symbol("sidebar.left", title: sidebarWidth > 0 ? "Hide Sidebar" : "Show Sidebar")
                    .frame(width: metrics.points(36), height: metrics.points(36))
                    .background { glass(in: Circle()) }
            }
            .help("\(sidebarWidth > 0 ? "Hide" : "Show") the sidebar (Control-Command-S)")
            // Dimmed rather than removed, so the title keeps its place.
            .disabled(!showsActions)
            .accessibilityIdentifier("toggleSidebar")
            Text(title)
                .font(Font(InterfaceTypography.font(size: metrics.points(15), semibold: true)))
                .lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("mainWindowTitle")
                .help(title)
                .gesture(WindowDragGesture())
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            if showsActions { actions }
        }
        .buttonStyle(.plain)
        .padding(.leading, sidebarWidth > 0 ? sidebarWidth + metrics.points(8) : 96)
        .padding(.trailing, metrics.points(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Button(action: importRoutines) {
                symbol("square.and.arrow.down", title: "Import Routines")
                    .frame(width: metrics.points(28), height: metrics.points(36))
                    .contentShape(Rectangle())
            }
            .help("Import routines from Claude Desktop or Codex")
            .accessibilityIdentifier("import")
            Button(action: newRoutine) {
                symbol("plus", title: "New Routine")
                    .frame(width: metrics.points(28), height: metrics.points(36))
                    .contentShape(Rectangle())
            }
            .help("New Routine")
            .accessibilityIdentifier("newRoutine")
        }
        .padding(.horizontal, metrics.points(4))
        .background { glass(in: Capsule()) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbarActions")
    }

    private func symbol(_ name: String, title: String) -> some View {
        Image(systemName: name)
            .font(.system(size: metrics.points(16)))
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private func glass(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.interactive(), in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

/// A shared AppKit parent keeps overlays outside the hosting view's managed tree.
final class MainWindowContainer: NSViewController {
    private let body: NSViewController

    init<Content: View>(body: NSHostingController<Content>) {
        // The window owns its minimum size; content must reflow within it.
        body.sizingOptions = []
        self.body = body
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1040, height: 680))
        addChild(body)
        body.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body.view)
        NSLayoutConstraint.activate([
            body.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.view.topAnchor.constraint(equalTo: view.topAnchor),
            body.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

/// The original split view keeps its full-size window and native title-bar safe
/// area. Controls overlay that same title-bar area, rather than add a content row.
struct WindowToolbarOverlay: NSViewRepresentable {
    let content: AnyView
    let height: CGFloat
    let title: String

    static func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "RotaMain")
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func makeNSView(context: Context) -> ToolbarOverlayAnchor { ToolbarOverlayAnchor() }

    static func dismantleNSView(_ view: ToolbarOverlayAnchor, coordinator: ()) { view.uninstall() }

    func updateNSView(_ anchor: ToolbarOverlayAnchor, context: Context) {
        anchor.host.rootView = content
        anchor.height = height
        anchor.title = title
        anchor.install()
    }
}

final class ToolbarOverlayAnchor: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    var height: CGFloat = 52
    var title = "Rota"
    private let accessory = NSTitlebarAccessoryViewController()
    private let toolbarView = NSView()
    private weak var installedWindow: NSWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.safeAreaRegions = []
        host.sizingOptions = []
        accessory.layoutAttribute = .bottom
        accessory.automaticallyAdjustsSize = false
        accessory.view = NSView()
        toolbarView.autoresizingMask = [.width, .minYMargin]
        toolbarView.setAccessibilityElement(true)
        toolbarView.setAccessibilityRole(.toolbar)
        toolbarView.setAccessibilityIdentifier("mainToolbar")
        host.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor),
            host.topAnchor.constraint(equalTo: toolbarView.topAnchor),
            host.bottomAnchor.constraint(equalTo: toolbarView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    func install() {
        guard let window, let content = window.contentView else { return }
        if installedWindow !== window {
            installedWindow = window
            content.addSubview(toolbarView, positioned: .above, relativeTo: nil)
            window.addTitlebarAccessoryViewController(accessory)
            NotificationCenter.default.addObserver(self, selector: #selector(positionToolbar),
                                                   name: NSWindow.didUpdateNotification, object: window)
        }
        let extra = max(0, height - 52)
        if accessory.view.frame.height != extra {
            accessory.view.setFrameSize(NSSize(width: content.frame.width, height: extra))
            accessory.fullScreenMinHeight = extra
        }
        positionToolbar()
    }

    func uninstall() {
        toolbarView.removeFromSuperview()
        if let window = installedWindow,
           let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        installedWindow = nil
    }

    @objc private func positionToolbar() {
        guard let window = installedWindow, let content = window.contentView else { return }
        if window.title != title { window.title = title }
        let rect = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        let frame = content.convert(rect, from: nil)
        if toolbarView.frame != frame { toolbarView.frame = frame }
    }
}
