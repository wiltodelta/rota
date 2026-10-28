import AppKit
import SwiftUI
@testable import Rota
import XCTest

@MainActor
final class WindowToolbarOverlayTests: XCTestCase {
    func testToolbarRemainsAtWindowTopAcrossZoomAndResize() async throws {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: fixture(height: 52))
        hosting.sceneBridgingOptions = []
        let window = NSWindow(contentViewController: MainWindowContainer(body: hosting))
        window.setContentSize(NSSize(width: 820, height: 600))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.toolbar = WindowToolbarOverlay.makeToolbar()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (width, height) in [(820.0, 52.0), (820, 78), (1040, 78), (820, 52)] {
            hosting.rootView = fixture(height: height)
            window.setFrame(NSRect(x: 100, y: 100, width: width, height: 600), display: false)
            for _ in 0..<5 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                window.update()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
            }
            let content = try XCTUnwrap(window.contentView)
            let toolbar = try XCTUnwrap(findToolbar(in: content))
            let frame = toolbar.convert(toolbar.bounds, to: nil)
            XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(frame.maxY, window.frame.height, accuracy: 0.5)
            XCTAssertEqual(frame.width, width, accuracy: 0.5)
            XCTAssertEqual(frame.height, height, accuracy: 0.5)
            XCTAssertEqual(window.frame.height - window.contentLayoutRect.maxY, height, accuracy: 0.5)
            XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
            XCTAssertEqual(window.title, "Example project: Scheduled report with a longer title")
        }
        hosting.rootView = fixture(height: 52, showToolbar: false)
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.update()
        }
        XCTAssertNil(findToolbar(in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
    }

    func testResizeDoesNotDependOnSwiftUIRebuildingOrWindowUpdate() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 820, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.toolbar = WindowToolbarOverlay.makeToolbar()
        window.isReleasedWhenClosed = false
        let anchor = ToolbarOverlayAnchor(frame: .zero)
        anchor.height = 78
        anchor.title = "Example"
        anchor.host.rootView = AnyView(MainWindowToolbar(title: "Example", sidebarWidth: 280,
                                                       toggleSidebar: {}, importRoutines: {}, newRoutine: {},
                                                       showsActions: true)
            .environment(\.interfaceScale, InterfaceScale(factor: 1.5)))
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(anchor)
        anchor.install()
        defer {
            anchor.uninstall()
            window.close()
        }
        let toolbar = try XCTUnwrap(findToolbar(in: content))
        // Native window setup can overwrite the name after the overlay first installs.
        window.title = "Untitled"
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        XCTAssertEqual(window.title, "Example")
        window.setFrame(NSRect(x: 100, y: 100, width: 1040, height: 520), display: false)
        content.layoutSubtreeIfNeeded()
        let frame = toolbar.convert(toolbar.bounds, to: nil)
        XCTAssertEqual(frame.width, 1040, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 520, accuracy: 0.5)
        XCTAssertEqual(frame.height, 78, accuracy: 0.5)
    }

    private func fixture(height: CGFloat, showToolbar: Bool = true) -> some View {
        let title = "Example project: Scheduled report with a longer title"
        return NavigationSplitView {
            Text("Sidebar")
        } detail: {
            Text("Detail")
        }
        .background {
            if showToolbar {
                WindowToolbarOverlay(content: AnyView(MainWindowToolbar(
                    title: title, sidebarWidth: 280,
                    toggleSidebar: {}, importRoutines: {}, newRoutine: {}, showsActions: true
                ).environment(\.interfaceScale, InterfaceScale(factor: height / 52))), height: height, title: title)
                    .frame(width: 0, height: 0)
            }
        }
    }

    private func findToolbar(in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == "mainToolbar" { return view }
        for child in view.subviews {
            if let result = findToolbar(in: child) { return result }
        }
        return nil
    }
}
