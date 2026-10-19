import Foundation

public enum QuestionHook {
    public static func run() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let request = QuestionRequest.claude(event)
        else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment["ROTA_SESSION"] else { throw ControlError("Missing Rota session.") }
        let socket = ControlServer.standardSocket
        let question = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.question))
        var answer = QuestionAnswer(action: "cancel")
        do {
            _ = try ControlClient.call("questions.create", ["session": session, "question": question], socket: socket)
            while true {
                let result = try ControlClient.call(
                    "questions.poll", ["session": session, "question": request.question.id], socket: socket)
                if let result = result as? [String: Any], result["pending"] as? Bool == true {
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                answer = try JSONDecoder().decode(
                    QuestionAnswer.self, from: JSONSerialization.data(withJSONObject: result))
                break
            }
        } catch {
            // A stopped run or lost app must never turn into approval or a terminal-only prompt.
            FileHandle.standardError.write(Data("Rota could not collect the answer. The request was canceled.\n".utf8))
        }
        let output = try JSONSerialization.data(withJSONObject: request.response(answer))
        FileHandle.standardOutput.write(output + Data("\n".utf8))
    }
}
