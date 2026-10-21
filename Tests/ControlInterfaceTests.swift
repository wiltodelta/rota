@testable import RotaCore
import XCTest

final class ControlInterfaceTests: XCTestCase {
    func testEveryPublicMethodHasOneMCPToolAndAWorkingCLICommand() throws {
        let tools = ControlInterface.tools
        XCTAssertEqual(Set(tools.map(\.method)), Set(ControlMethod.allCases.filter(\.isPublic)))
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
        XCTAssertEqual(Set(tools.map(\.command)).count, tools.count)
        for tool in tools {
            let raw = [tool.command, "digest", "hello", "--session", "session-id",
                       "--question", "question-id", "--action", "cancel"]
            let (method, _) = try ControlCLI.request(tool.command, ControlCLI.Arguments(raw))
            XCTAssertEqual(method, tool.method.rawValue)
            XCTAssertTrue(Set(tool.required).isSubset(of: Set(tool.properties.keys)))
        }
    }

    func testRoutineFieldsRemainAvailableThroughBothInterfaces() throws {
        let routine = Routine(id: "digest", name: "Digest", workingDirectory: "/tmp/project",
                              schedule: "0 9 * * *", prompt: "Summarize.")
        let editable = Set(Mirror(reflecting: routine).children.compactMap(\.label))
            .subtracting(["nextFire", "importIdentity"])
        let raw = ["add", "digest", "--name", "Digest", "--folder", "/tmp/project", "--schedule", "0 9 * * *",
                   "--harness", "codex", "--prompt", "Summarize.", "--model", "chosen-model", "--effort", "high",
                   "--time-limit", "30", "--off"]
        let (_, params) = try ControlCLI.request("add", ControlCLI.Arguments(raw))
        XCTAssertTrue(editable.isSubset(of: Set(params.keys)))
        for method in [ControlMethod.routinesCreate, .routinesUpdate] {
            let tool = try XCTUnwrap(ControlInterface.tools.first { $0.method == method })
            XCTAssertTrue(editable.isSubset(of: Set(tool.properties.keys)))
        }
    }

    func testSessionContextIsSharedAndNeverSelectsADeletionTarget() throws {
        let environment = ["ROTA_SESSION": "own-session", "ROTA_ROUTINE": "digest"]
        let arguments = try ControlCLI.Arguments(["session", "digest"])
        let (_, params) = try ControlCLI.request("session", arguments, environment: environment)
        XCTAssertEqual(params["session"] as? String, "own-session")
        for tool in ControlInterface.tools where tool.properties["session"] != nil {
            let input: [String: Any] = tool.method == .notify ? [:] : ["id": "digest"]
            let bound = ControlInterface.sessionArguments(input, method: tool.method, environment: environment)
            XCTAssertEqual(bound["session"] as? String, tool.method == .sessionsDelete ? nil : "own-session")
            let explicit = ControlInterface.sessionArguments(input.merging(["session": "explicit"]) { $1 },
                                                              method: tool.method, environment: environment)
            XCTAssertEqual(explicit["session"] as? String, "explicit")
        }
        let other = ControlInterface.sessionArguments(["id": "other"], method: .sessionsGet, environment: environment)
        XCTAssertNil(other["session"])
    }

    func testCLITranslatesStructuredAnswersAndRepeatedAttachments() throws {
        let raw = ["answer", "digest", "--question", "q1", "--action", "accept",
                   "--values", #"{"target":["staging"],"notes":["Тест"]}"#]
        let (method, params) = try ControlCLI.request("answer", ControlCLI.Arguments(raw))
        XCTAssertEqual(method, "sessions.answer")
        XCTAssertEqual(params["values"] as? [String: [String]], ["target": ["staging"], "notes": ["Тест"]])
        let args = try ControlCLI.Arguments(["send", "digest", "--attach", "/tmp/a.txt", "--attach", "/tmp/b.txt"])
        let (_, message) = try ControlCLI.request("send", args)
        XCTAssertEqual(message["attachments"] as? [String], ["/tmp/a.txt", "/tmp/b.txt"])
        XCTAssertEqual(message["text"] as? String, "")
    }

    func testCLIRejectsImplicitDeletionAndMissingOrMalformedAnswers() throws {
        for raw in [["delete-session", "digest"], ["answer", "digest"],
                    ["answer", "digest", "--question", "q", "--action", "accept", "--values", #"{"a":true}"#],
                    ["sessions", "digest", "--limit", "nonsense"]] {
            XCTAssertThrowsError(try ControlCLI.request(raw[0], ControlCLI.Arguments(raw)), raw.joined(separator: " "))
        }
        let args = try ControlCLI.Arguments(["off", "digest"])
        let (method, params) = try ControlCLI.request("off", args)
        XCTAssertEqual(method, "routines.setEnabled")
        XCTAssertEqual(params["enabled"] as? Bool, false)
    }
}
