@testable import RotaCore
import XCTest

final class TerminalEnvironmentTests: XCTestCase {
    func testOpeningArgumentsForEachTerminal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = URL(fileURLWithPath: "/folder with spaces/test.command")
        for terminal in KnownTerminal.allCases {
            let app = folder.appendingPathComponent("\(terminal.title).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": terminal.rawValue],
                                                         format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            let process = TerminalLauncher.openingProcess(script, in: app)
            let arguments = terminal == .ghostty
                ? ["-n", "-a", app.path, "--args", "-e", script.path]
                : ["-a", app.path, script.path]
            XCTAssertEqual(process.arguments, arguments)
        }
    }

    func testTerminalLaunchDoesNotInheritAnAgentSession() {
        let inherited = ["HOME": "/Users/example", "USER": "example", "LANG": "en_US.UTF-8",
                         "PATH": "/agent/shims:/usr/bin", "CLAUDECODE": "1",
                         "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "parent-session",
                         "CLAUDE_CODE_ENABLE_CFC": "1", "ANTHROPIC_BASE_URL": "https://proxy.example",
                         "SUPERCONDUCTOR_ENV": "release"]
        let process = TerminalLauncher.openingProcess(URL(fileURLWithPath: "/test.command"), in: nil,
                                                      environment: inherited)
        let environment = process.environment ?? [:]
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/open")
        XCTAssertEqual(process.arguments, ["/test.command"])
        XCTAssertEqual(environment["HOME"], inherited["HOME"])
        XCTAssertEqual(environment["USER"], inherited["USER"])
        XCTAssertEqual(environment["LANG"], inherited["LANG"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertFalse(environment.keys.contains { $0.hasPrefix("CLAUDE_CODE_") })
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["SUPERCONDUCTOR_ENV"])
    }
}
