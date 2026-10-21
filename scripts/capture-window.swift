// Composite a Rota window over an opaque backdrop, excluding all other apps.
// Usage: capture-window <window-id> <light|dark> <output.png>
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 4, let windowID = UInt32(arguments[1]),
      ["light", "dark"].contains(arguments[2]) else {
    fatalError("Usage: capture-window <window-id> <light|dark> <output.png>")
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let dark = arguments[2] == "dark"
let color = NSColor(srgbRed: dark ? 0.09 : 0.86, green: dark ? 0.10 : 0.88,
                    blue: dark ? 0.12 : 0.91, alpha: 1)

Task { @MainActor in
    do {
        let initial = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = initial.windows.first(where: { $0.windowID == windowID }),
              let display = initial.displays.first(where: { $0.displayID == CGMainDisplayID() }),
              let screen = NSScreen.screens.first else { throw CocoaError(.fileReadUnknown) }
        let rect = target.frame.insetBy(dx: -32, dy: -32)
        let backdrop = NSWindow(contentRect: NSRect(x: rect.minX,
                                                   y: screen.frame.maxY - rect.maxY,
                                                   width: rect.width, height: rect.height),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isOpaque = true
        backdrop.backgroundColor = color
        backdrop.ignoresMouseEvents = true
        backdrop.order(.below, relativeTo: Int(windowID))
        try await Task.sleep(for: .milliseconds(400))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let current = content.windows.first(where: { $0.windowID == windowID }),
              current.frame == target.frame,
              let background = content.windows.first(where: { $0.windowID == UInt32(backdrop.windowNumber) })
        else { throw CocoaError(.fileReadUnknown) }
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.backgroundColor = color.cgColor
        let filter = SCContentFilter(display: display, including: [background, current])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let output = URL(fileURLWithPath: arguments[3])
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL,
                                                           UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        backdrop.orderOut(nil)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Capture failed: \(error)\n".utf8))
        exit(1)
    }
}
app.run()
