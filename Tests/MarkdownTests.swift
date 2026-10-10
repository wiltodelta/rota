@testable import RotaCore
import XCTest

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let text = """
            ## Summary
            Clicks are down **8%**.
            Three pages lost most of it:
            - `/pricing` (-41)
              - nested
            2. second
            ```swift
            let a = 1

            let b = 2
            ```
            Done.
            """
        XCTAssertEqual(MarkdownBlock.parse(text), [
            .heading(level: 2, text: "Summary"),
            .paragraph("Clicks are down **8%**.\nThree pages lost most of it:"),
            .listItem(marker: "\u{2022}", text: "`/pricing` (-41)", indent: 0),
            .listItem(marker: "\u{2022}", text: "nested", indent: 1),
            .listItem(marker: "2.", text: "second", indent: 0),
            .code("let a = 1\n\nlet b = 2"),
            .paragraph("Done.")
        ])
    }

    func testNotHeadingsOrLists() {
        XCTAssertEqual(MarkdownBlock.parse("#hashtag and -dash and 2026. year"),
                       [.paragraph("#hashtag and -dash and 2026. year")])
        XCTAssertEqual(MarkdownBlock.parse("```\nunclosed"), [.code("unclosed")])
    }

    func testTranscriptKeepsFencedCodeWithBlankLinesInOneMessage() {
        let items = Transcript.parse("Here:\n```\nline 1\n\nline 3\n```\nAfter.")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Here:\n```\nline 1\n\nline 3\n```\nAfter.")
    }

    func testSkipsAreNotUnreadSessions() {
        let skip = RunRecord(routineID: "r", trigger: .scheduled, harness: .claude, startedAt: .now, endedAt: .now,
                             outcome: .skipped("previous run"))
        XCTAssertTrue(skip.isSkip)
        XCTAssertFalse(skip.isUnread)
    }
}
