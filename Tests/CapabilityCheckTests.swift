import Foundation
import XCTest

/// Runs only deterministic evidence tests; the live probe requires a separate --live invocation.
final class CapabilityCheckTests: XCTestCase {
    func testCapabilityEvidenceChecker() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", "-m", "unittest", "discover", "-s", "scripts/tests", "-v"]
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: data, encoding: .utf8) ?? "Invalid test output")
    }
}
