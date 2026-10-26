import AppKit
import SwiftUI
@testable import Rota
import XCTest

@MainActor
final class ControlRowAlignmentTests: XCTestCase {
    func testPickerLabelAndValueShareTheirVerticalCenter() throws {
        try verifyCenters {
            InterfacePicker(title: "Terminal", selection: .constant("terminal"),
                            choices: [.item("Terminal", "terminal")])
        }
    }

    func testButtonRowLabelAndValueShareTheirVerticalCenter() throws {
        try verifyCenters {
            LabeledContent("Terminal") {
                Button(interfaceTitle: "Terminal") {}
            }
            .labeledContentStyle(InterfaceFormRowStyle())
        }
    }

    func testSwitchRowLabelAndControlShareTheirVerticalCenter() throws {
        try verifyCenters(isSwitch: true) {
            Toggle("Terminal", isOn: .constant(true))
        }
    }

    func testTextBoundsIncludeAntialiasedEdges() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 10,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for y in 0..<10 {
                let light: CGFloat = (2...4).contains(y) ? 0.4 : (5...7).contains(y) ? 0.1 : 1
                let gray = appearance == .aqua ? light : 1 - light
                for x in 0..<4 {
                    bitmap.setColor(NSColor(deviceRed: gray, green: gray, blue: gray, alpha: 1), atX: x, y: y)
                }
            }
            let edge = try XCTUnwrap(bitmap.colorAt(x: 0, y: 2))
            XCTAssertEqual(edge.redComponent, appearance == .aqua ? 0.4 : 0.6, accuracy: 0.01)
            XCTAssertEqual(try center(in: bitmap, columns: 0..<4, appearance: appearance), 4.5)
        }
    }

    private func verifyCenters(isSwitch: Bool = false, @ViewBuilder content: () -> some View) throws {
        _ = NSApplication.shared
        let name = "rota-alignment-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let scale = InterfaceScaleSettings(defaults: defaults)
        for factor in InterfaceScaleSettings.levels {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                scale.factor = factor
                let width = InterfaceScale(factor: factor).sheetWidth(520)
                let host = NSHostingView(rootView: Form { content() }.settingsPane()
                    .interfaceScale(scale).frame(height: 120))
                host.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                                      styleMask: [], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let backing = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let labelCenter = try center(in: bitmap, columns: 0..<bitmap.pixelsWide / 2,
                                             appearance: appearance) / backing
                // Exclude the popup arrow; identical labels isolate alignment from glyph shapes.
                let end = isSwitch ? bitmap.pixelsWide : bitmap.pixelsWide - Int(60 * factor * backing)
                let controlCenter = try center(in: bitmap, columns: bitmap.pixelsWide / 2..<end,
                                               appearance: appearance, switchTrack: isSwitch) / backing
                var diagnostic = " backing=\(backing)"
                if abs(labelCenter - controlCenter) > 0.75 {
                    for threshold: CGFloat in [0.3, 0.5, 0.7, 0.9] {
                        let measured = try center(in: bitmap, columns: 0..<bitmap.pixelsWide / 2,
                                                  appearance: appearance, textThreshold: threshold) / backing
                        diagnostic += " threshold=\(threshold):\(measured)"
                    }
                    let font = InterfaceTypography.font(size: NSFont.systemFontSize * factor)
                    diagnostic += " font=\(font.fontName),size=\(font.pointSize),cap=\(font.capHeight)"
                }
                XCTAssertEqual(labelCenter, controlCenter, accuracy: 0.75,
                               "Control row centers at \(factor), \(appearance.rawValue)\(diagnostic)")
            }
        }
    }

    private func center(in bitmap: NSBitmapImageRep, columns: Range<Int>, appearance: NSAppearance.Name,
                        switchTrack: Bool = false, textThreshold: CGFloat = 0.5) throws -> CGFloat {
        var rows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in columns {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.9 else { continue }
                let ink: Bool
                if switchTrack && appearance == .aqua {
                    ink = max(color.redComponent, color.greenComponent, color.blueComponent) < 0.87
                } else if switchTrack {
                    ink = min(color.redComponent, color.greenComponent, color.blueComponent) > 0.7
                } else if appearance == .aqua {
                    // Include antialiased glyph edges; strong-ink cutoffs lose whole rows at 1x.
                    ink = max(color.redComponent, color.greenComponent, color.blueComponent) < textThreshold
                } else {
                    ink = min(color.redComponent, color.greenComponent, color.blueComponent) > 1 - textThreshold
                }
                if ink {
                    rows.append(y)
                    break
                }
            }
        }
        return CGFloat(try XCTUnwrap(rows.first) + XCTUnwrap(rows.last)) / 2
    }
}
