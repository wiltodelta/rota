import AppKit
import os
import RotaCore

/// Opens a run's harness session in the terminal app picked in Settings,
/// through a `.command` file (`TerminalLauncher`).
@MainActor
enum ChatOpener {
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "chat")

    static func open(_ record: RunRecord, workingDirectory: String, scheduler: Scheduler, terminal: String?) {
        Task {
            if !scheduler.isActive(record) {
                guard await scheduler.continueInTerminal(record) else { return }
            }
            openAttached(record, workingDirectory: workingDirectory, scheduler: scheduler, terminal: terminal)
        }
    }

    private static func openAttached(_ record: RunRecord, workingDirectory: String,
                                     scheduler: Scheduler, terminal: String?) {
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
            let app = terminal.map { URL(fileURLWithPath: $0) }
            TerminalLauncher.open(file, in: app) { error in
                guard let error else { return }
                let reason = error.localizedDescription
                Task { @MainActor in
                    let target = app?.path ?? "the script"
                    log.error("Could not open \(target, privacy: .public): \(reason, privacy: .public)")
                    scheduler.lastError = "Could not open the terminal: \(reason)"
                }
            }
            let terminalName = app?.lastPathComponent ?? "the default terminal"
            log.info("Opened chat in \(terminalName, privacy: .public): \(command, privacy: .public)")
        } catch {
            scheduler.lastError = "Could not open the chat: \(error.localizedDescription)"
        }
    }
}
