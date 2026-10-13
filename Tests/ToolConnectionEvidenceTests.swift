@testable import RotaCore
import XCTest

final class ToolConnectionEvidenceTests: XCTestCase {
    private func evidence(_ title: String, input: String = "", output: String = "[]",
                          status: String = "completed") -> ToolConnectionEvidence {
        var transcript = SessionTranscript()
        transcript.apply(SessionEvent(turnID: "check", payload: .tool(id: "tool", title: title,
                                                                     input: input, output: output, status: status)))
        return ToolConnectionEvidence(items: transcript.items)
    }

    func testNativeChromeRequiresSuccessfulInventoryResult() {
        let title = "mcp__claude-in-chrome__list_connected_browsers"
        let output = #"[{"deviceId":"11111111-1111-4111-8111-111111111111","isLocal":true,"connectedAt":1}]"#
        XCTAssertTrue(evidence(title, output: output).chrome)
        XCTAssertTrue(evidence(title, output: output).browser)
        let wrapped = EventContent.text([["type": "text", "text": output]])!
        XCTAssertTrue(evidence(title, output: wrapped).chrome)
        XCTAssertFalse(evidence(title, output: output.replacingOccurrences(of: "true", with: "false")).chrome)
        XCTAssertFalse(evidence(title, status: "running").chrome)
        XCTAssertFalse(evidence(title, status: "failed").chrome)
        XCTAssertFalse(evidence(title, output: #"{"isError":true}"#).chrome)
        XCTAssertFalse(evidence("ToolSearch", output: title).chrome)
        XCTAssertFalse(evidence(title, output: "[]").chrome)
        XCTAssertFalse(evidence("mcp__claude-in-chrome__tabs_context_mcp",
                                output: "This session has no tab group.").chrome)
    }

    func testExternalAndIsolatedBrowsersCannotConfirmNativeConnection() {
        XCTAssertFalse(evidence("mcp__playwright__browser_tabs").browser)
        XCTAssertFalse(evidence("mcp__playwright-isolated__browser_tabs").browser)
        XCTAssertFalse(evidence("exec_command", output: "Chrome connected").chrome)
        XCTAssertFalse(evidence("mcp__claude-in-chrome__read_page").chrome)
    }

    func testCodexNativeBrowserInventoryCanConfirmChrome() {
        let input = #"{"code":"await cua.listTabs({browser: \"chrome\"});"}"#
        let output = EventContent.text([
            "_meta": ["codex/toolSurface": ["kind": "browserUse", "browserFamily": "chrome"]],
            "content": [["type": "text", "text": "[]"]]
        ])!
        XCTAssertTrue(evidence("js", input: input, output: output).chrome)
        XCTAssertTrue(evidence("js", input: input, output: output).browser)
        XCTAssertFalse(evidence("js", input: input, status: "failed").browser)
        XCTAssertFalse(evidence("mcp__cua_repl__js", input: "await cua.getApp('Calculator');").browser)
    }
    func testCodexListTabsUsesNativeBrowserMetadataForChromeIdentity() {
        let input = #"{"code":"await cua.listTabs({browser: '1'});"}"#
        let output = EventContent.text([
            "_meta": ["codex/toolSurface": ["kind": "browserUse", "browserFamily": "chrome", "browserId": "1"]],
            "content": [["type": "text", "text": "[]"]]
        ])!
        XCTAssertTrue(evidence("js", input: input, output: output).browser)
        XCTAssertTrue(evidence("js", input: input, output: output).chrome)
        XCTAssertFalse(evidence("js", input: input, output: output, status: "failed").chrome)
        XCTAssertFalse(evidence("js", input: "await cua.listBrowsers();", output: output).browser)
        let otherBrowser = output.replacingOccurrences(of: "chrome", with: "firefox")
        XCTAssertTrue(evidence("js", input: input, output: otherBrowser).browser)
        XCTAssertFalse(evidence("js", input: input, output: otherBrowser).chrome)
        XCTAssertFalse(evidence("js", input: "await cua.listTabs({browser: 'chrome'});",
                                output: otherBrowser).chrome)
    }

}
