import AppKit
@testable import Rota
import XCTest

@MainActor
final class MarkdownTableLayoutTests: XCTestCase {
    func testLongerContentGetsMoreWidthEvenWhenBothColumnsExceedFortyCharacters() {
        let widths = MarkdownTableView.columnWidths(contentLengths: [1, 60, 240],
                                                     availableWidth: 492, fontSize: 14, padding: 20)
        XCTAssertLessThan(widths[0], widths[1] / 2)
        XCTAssertGreaterThan(widths[2], widths[1] * 1.5)
        XCTAssertEqual(widths.reduce(0, +), 492, accuracy: 0.01)
    }

    func testNarrowTablePreservesUnequalColumnsAndReadableTextByScrolling() {
        let widths = MarkdownTableView.columnWidths(contentLengths: [1, 60, 240],
                                                     availableWidth: 388, fontSize: 21, padding: 30)
        XCTAssertGreaterThan(widths[2], widths[1] * 1.5)
        XCTAssertGreaterThanOrEqual(widths[1], 21 * 6 + 30)
        XCTAssertGreaterThan(widths.reduce(0, +), 388)
    }

    func testZoomScalesColumnWidthsWithoutChangingTheirProportions() {
        let normal = MarkdownTableView.columnWidths(contentLengths: [1, 60, 240],
                                                     availableWidth: 492, fontSize: 14, padding: 20)
        let zoomed = MarkdownTableView.columnWidths(contentLengths: [1, 60, 240],
                                                     availableWidth: 738, fontSize: 21, padding: 30)
        for (normalWidth, zoomedWidth) in zip(normal, zoomed) {
            XCTAssertEqual(zoomedWidth, normalWidth * 1.5, accuracy: 0.01)
        }
    }
}
