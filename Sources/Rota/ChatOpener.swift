import AppKit
import os
import RotaCore

/// Opens a run's harness session in the user's terminal app, through a
/// `.command` file: that needs no Automation permission, unlike scripting Terminal.
@MainActor
enum ChatOpener {
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "chat")

    static func open(_ record: RunRecord, workingDirectory: String, scheduler: Scheduler) {
        guard let (executable, arguments) = scheduler.terminalCommand(for: record) else { return }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rota/chat")
        let file = folder.appendingPathComponent("\(record.routineID).command")
        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let script = "#!/bin/zsh -l\ncd \(shellQuote(workingDirectory)) || exit 1\nexec \(command)\n"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
            log.info("Opened chat: \(command, privacy: .public)")
        } catch {
            scheduler.lastError = "Could not open the chat: \(error.localizedDescription)"
        }
    }
}
