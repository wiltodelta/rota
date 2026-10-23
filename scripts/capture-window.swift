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

// ScreenCaptureKit's filtered composite can omit text fragments after resizing.
// The native window capture preserves them; flatten its corners over the same backdrop.
func captureWindow(_ id: UInt32, frame: CGRect) throws -> CGImage {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("rota-capture-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-o", "-x", "-l", String(id), file.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let captured = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadUnknown) }
    let scale = CGFloat(captured.width) / frame.width
    guard abs(CGFloat(captured.height) / frame.height - scale) < 0.01 else {
        throw CocoaError(.fileReadUnknown)
    }
    let margin = Int((32 * scale).rounded())
    let width = captured.width + 2 * margin
    let height = captured.height + 2 * margin
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileReadUnknown) }
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(captured, in: CGRect(x: margin, y: margin, width: captured.width, height: captured.height))
    guard let image = context.makeImage() else { throw CocoaError(.fileReadUnknown) }
    return image
}

Task { @MainActor in
    do {
        let initial = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = initial.windows.first(where: { $0.windowID == windowID }),
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
              current.frame == target.frame
        else { throw CocoaError(.fileReadUnknown) }
        let image = try captureWindow(windowID, frame: current.frame)
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
