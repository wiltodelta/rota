import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Synthetic pixels and a randomized text marker, never a user's files.
enum AttachmentTestFixture {
    static func create(in folder: URL) throws -> (files: [URL], marker: String) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 80, y: 100, width: 160, height: 160))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 370, y: 110, width: 140, height: 140))
        let image = folder.appendingPathComponent("sample-shapes.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let marker = UUID().uuidString.lowercased()
        let report = folder.appendingPathComponent("sample-report.txt")
        try Data(("Attachment marker: " + marker).utf8).write(to: report)
        return ([image, report], marker)
    }
}
