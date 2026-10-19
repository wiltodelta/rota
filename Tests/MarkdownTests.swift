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
            .code("let a = 1\n\nlet b = 2", language: "swift"),
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

final class CodeFenceLanguageTests: XCTestCase {
    func testTheFenceNamesTheLanguage() {
        XCTAssertEqual(MarkdownBlock.parse("```swift\nlet a = 1\n```"), [.code("let a = 1", language: "swift")])
        XCTAssertEqual(MarkdownBlock.parse("```bash title\nls\n```"), [.code("ls", language: "bash")])
        XCTAssertEqual(MarkdownBlock.parse("```\nls\n```"), [.code("ls", language: nil)])
    }
}

final class MarkdownTableTests: XCTestCase {
    func testTableBetweenParagraphsPreservesInlineMarkdownAndAlignment() {
        let source = """
        Before.
        | # | Пункт | Результат |
        | ---: | :--- | :---: |
        | 1 | Длинное описание | **Готово**, `field_name` |
        | 2 | Следующий пункт | Проверено |

        After.
        """
        XCTAssertEqual(MarkdownBlock.parse(source), [
            .paragraph("Before."),
            .table(MarkdownTable(headers: ["#", "Пункт", "Результат"],
                                 alignments: [.right, .left, .center],
                                 rows: [["1", "Длинное описание", "**Готово**, `field_name`"],
                                        ["2", "Следующий пункт", "Проверено"]])),
            .paragraph("After.")
        ])
    }

    func testOptionalOuterPipesEscapesAndRaggedRows() {
        let source = "A | B\n--- | ---\nx\\|y | `a\\|b`\nshort |\n1 | 2 | ignored"
        XCTAssertEqual(MarkdownBlock.parse(source), [
            .table(MarkdownTable(headers: ["A", "B"], alignments: [.left, .left],
                                 rows: [["x|y", "`a|b`"], ["short", ""], ["1", "2"]]))
        ])
    }

    func testOnlyMatchingDelimiterRowsStartTablesAndFencesStayLiteral() {
        for source in ["a | b\n--- | invalid", "a | b\n---", "a | b\n--- | --- | ---"] {
            XCTAssertEqual(MarkdownBlock.parse(source), [.paragraph(source)])
        }
        XCTAssertEqual(MarkdownBlock.parse("```\na | b\n--- | ---\n```"), [.code("a | b\n--- | ---")])
        XCTAssertEqual(MarkdownBlock.parse("| a | b |\n| --- | --- |"), [
            .table(MarkdownTable(headers: ["a", "b"], alignments: [.left, .left], rows: []))
        ])
    }
}
