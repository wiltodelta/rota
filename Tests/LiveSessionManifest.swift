import Foundation
import RotaCore
import XCTest

/// Retains provider-returned IDs so live-test cleanup never guesses which sessions belong to the run.
enum LiveSessionManifest {
    static func record(_ session: String, harness: Harness, cwd: String, folder: URL) {
        guard let destination = ProcessInfo.processInfo.environment["ROTA_HOOK_LIVE_MANIFEST"] else { return }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: ["session": session, "harness": harness.rawValue,
                                                                    "cwd": cwd, "folder": folder.path])
            let url = URL(fileURLWithPath: destination)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            _ = try output.seekToEnd()
            try output.write(contentsOf: bytes + Data([10]))
        } catch { XCTFail("Could not retain the live session ID: " + error.localizedDescription) }
    }
}
