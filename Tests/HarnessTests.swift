@testable import RotaCore
import XCTest

final class HarnessTests: XCTestCase {
    func testClaudeStreamArguments() {
        let plain = Harness.claude.arguments(settings: ClaudeUserSettings())
        XCTAssertEqual(plain, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--permission-mode", "bypassPermissions", "--permission-prompt-tool", "stdio",
                        "--include-partial-messages"])
        XCTAssertEqual(Array(Harness.claude.arguments(settings: ClaudeUserSettings(), resume: "s1").suffix(2)),
                       ["--resume", "s1"])
    }

    /// Chrome follows the user's default in ~/.claude.json, as an interactive session would; nothing else is added.
    func testClaudeGetsChromeExactlyWhenTheUsersSettingsTurnItOn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let on = folder.appendingPathComponent("on.json")
        try JSONSerialization.data(withJSONObject: ["claudeInChromeDefaultEnabled": true]).write(to: on)
        let off = folder.appendingPathComponent("off.json")
        try JSONSerialization.data(withJSONObject: ["claudeInChromeDefaultEnabled": false]).write(to: off)
        XCTAssertEqual(Harness.claude.arguments(settings: .read(on)).last, "--chrome")
        XCTAssertFalse(Harness.claude.arguments(settings: .read(off)).contains("--chrome"))
        XCTAssertFalse(Harness.claude.arguments(settings: .read(folder.appendingPathComponent("none")))
            .contains("--chrome"), "no settings file turns nothing on")
        XCTAssertTrue(Harness.codex.arguments(settings: .read(on)).isEmpty)
    }

    func testOnlyClaudeTakesCommandLineArguments() {
        for harness in [Harness.codex, .grok, .shell] {
            XCTAssertTrue(harness.arguments(settings: ClaudeUserSettings(chromeByDefault: true)).isEmpty)
        }
        XCTAssertEqual(Harness.allCases.map(\.launchMode),
                       [.claudeStream, .codexDaemon, .grokACP, .antigravityStream, .screen])
    }

    func testStreamJSONUserMessage() throws {
        let line = ClaudeStreamRun.userMessage("hi \"there\"")
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hi \"there\"")
    }

    func testTerminalCommandsWhileRunningAndAfter() {
        XCTAssertNil(Harness.claude.terminal(session: "s1", running: true), "Rota holds a running session")
        XCTAssertEqual(Harness.claude.terminal(session: "s1", running: false)?.arguments, ["--resume", "s1"])
        XCTAssertNil(Harness.codex.terminal(session: "t1", running: true))
        XCTAssertEqual(Harness.codex.terminal(session: "t1", running: false)?.arguments, ["resume", "t1"])
        XCTAssertNil(Harness.grok.terminal(session: "g1", running: true))
        XCTAssertEqual(Harness.grok.terminal(session: "g1", running: false)?.arguments, ["--resume", "g1"])
        XCTAssertEqual(Harness.shell.terminal(session: "rota-1", running: true)?.executable, "/usr/bin/screen")
        XCTAssertNil(Harness.shell.terminal(session: "rota-1", running: false))
    }

    func testWhoTakesMessagesInRota() {
        XCTAssertTrue(Harness.claude.takesMessages)
        XCTAssertTrue(Harness.codex.takesMessages)
        XCTAssertTrue(Harness.grok.takesMessages)
        XCTAssertFalse(Harness.shell.takesMessages)
    }

    /// Codex's daemon and Grok's leader outlive a run, so a run's variables go over the protocol.
    func testTheRunsVariablesReachSharedHarnessesOverTheProtocol() throws {
        let environment = ["ROTA_SESSION": "S1", "ROTA_ROUTINE": "digest", "ROTA_CLI": "/x/rota",
                           "CLAUDE_CODE_ENABLE_CFC": "1"]
        let overrides = CodexDaemonRun.configOverrides(environment)
        XCTAssertEqual(overrides["features.default_mode_request_user_input"] as? Bool, true)
        let variables = overrides.filter { $0.key.hasPrefix("shell_environment_policy.set.") } as? [String: String]
        XCTAssertEqual(variables, ["shell_environment_policy.set.ROTA_SESSION": "S1",
                                                        "shell_environment_policy.set.ROTA_ROUTINE": "digest",
                                                        "shell_environment_policy.set.ROTA_CLI": "/x/rota"])
        let rule = try XCTUnwrap(GrokACPRun.sessionRule(environment))
        XCTAssertTrue(rule.contains("'/x/rota' notify --session S1"), rule)
        XCTAssertTrue(rule.contains("routine digest"), rule)
        XCTAssertNil(GrokACPRun.sessionRule([:]))
        XCTAssertEqual(ProcessLauncher.helperDirectory, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// A run starts from the account's variables, whatever started Rota, and its login shell adds the rest.
    func testARunDoesNotInheritTheSessionThatStartedRota() {
        let inherited = ["HOME": "/Users/u", "USER": "u", "TMPDIR": "/tmp/u/", "CLAUDECODE": "1",
                         "ANTHROPIC_BASE_URL": "http://proxy", "SUPERCONDUCTOR_ENV": "release",
                         "PATH": "/agent/shims:/usr/bin", "ROTA_DATA_DIR": "/tmp/data"]
        let base = ProcessLauncher.baseEnvironment(inherited)
        XCTAssertEqual(base["HOME"], "/Users/u")
        XCTAssertEqual(base["ROTA_DATA_DIR"], "/tmp/data", "a dev build's command must reach the dev build")
        XCTAssertNil(base["CLAUDECODE"])
        XCTAssertNil(base["ANTHROPIC_BASE_URL"])
        XCTAssertNil(base["SUPERCONDUCTOR_ENV"])
        XCTAssertEqual(base["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        let process = ProcessLauncher.loginShellProcess("/bin/echo", [], in: "/", environment: ["ROTA_SESSION": "S"])
        XCTAssertEqual(process.environment?["ROTA_SESSION"], "S")
        XCTAssertNil(process.environment?["CLAUDECODE"])
    }

    func testDefaultExecutablesLiveUnderHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(Harness.claude.defaultExecutable(home: home), "/Users/someone/.local/bin/claude")
        XCTAssertEqual(Harness.grok.defaultExecutable(home: home), "/Users/someone/.local/bin/grok")
    }
}

final class TranscriptTests: XCTestCase {
    /// Only the header lines runners write are dropped; text that merely looks like one stays.
    func testTextThatLooksLikeAHeaderIsKept() {
        let agent = Transcript.parse("note: the report is late")
        XCTAssertEqual(agent.map(\.kind), [.agent])
        let output = Transcript.parse("$ make\nbuilt", shell: true)
        XCTAssertEqual(output.map(\.text), ["$ make\nbuilt"])
    }

    func testLogBecomesChatItems() {
        let log = """
            [you] Run the weekly check.
            [you] Then report.
            [codex thread 01a1]
            Starting.
            -> $ ls
            Found three files.
            They look fine.

            Second message.
            [rota: Succeeded after 20 s]
            [error] quota low
            """
        let items = Transcript.parse(log)
        XCTAssertEqual(items.map(\.kind), [.user, .agent, .tool, .agent, .agent, .status, .error])
        XCTAssertEqual(items[0].text, "Run the weekly check.\nThen report.")
        XCTAssertEqual(items[3].text, "Found three files.\nThey look fine.")
        XCTAssertEqual(items[5].text, "Completed after 20s")
        XCTAssertEqual(items.map(\.id), Array(0..<7))
    }

    func testDurationsReadInMinutes() {
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 412 s"), "Succeeded after 6m 52s")
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 120 s"), "Succeeded after 2m 0s")
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 3700 s"), "Succeeded after 1h 1m")
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 9 s"), "Succeeded after 9s")
        XCTAssertEqual(Transcript.parse("[result: success, 4 s, 2 turns]").first?.text, "success, 4s, 2 turns")
    }

    func testUserLinesRoundTrip() {
        let message = "line one\nline two"
        XCTAssertEqual(Transcript.parse(Transcript.userLines(message)).map(\.text), [message])
    }

    func testShellOutputIsOneBlock() {
        let items = Transcript.parse("[you] make test\nok 1\nok 2\n[rota: Succeeded after 1 s]", shell: true)
        XCTAssertEqual(items.map(\.kind), [.user, .output, .status])
        XCTAssertEqual(items[1].text, "ok 1\nok 2")
    }
}

final class StreamJSONFormatterTests: XCTestCase {
    func testSessionStart() {
        XCTAssertEqual(StreamJSONFormatter.format(#"{"type":"system","subtype":"init","model":"m1"}"#),
                       "[session started, m1]")
        XCTAssertNil(StreamJSONFormatter.format(#"{"type":"system","subtype":"hook"}"#))
    }

    func testAssistantTextAndToolUse() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"text","text":"Reading"},\#
        {"type":"tool_use","name":"Bash","input":{"command":"ls\n-la"}}]}}
        """#
        XCTAssertEqual(StreamJSONFormatter.format(line), "Reading\n-> Bash ls -la")
    }

    func testResult() {
        let line = #"{"type":"result","subtype":"success","duration_ms":12400,"num_turns":3,"result":"Done."}"#
        XCTAssertEqual(StreamJSONFormatter.format(line), "[result: success, 12 s, 3 turns]\nDone.")
    }

    func testUserEventsAreDroppedAndNonJSONPassesThrough() {
        XCTAssertNil(StreamJSONFormatter.format(#"{"type":"user","message":{}}"#))
        XCTAssertEqual(StreamJSONFormatter.format("zsh: command not found"), "zsh: command not found")
        XCTAssertNil(StreamJSONFormatter.format("   "))
    }
}

final class ExecutableDiscoveryTests: XCTestCase {
    func testFindsEachRealFileOnceInDirectoryOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rota-find-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let third = root.appendingPathComponent("third")
        for directory in [first, second, third] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let real = second.appendingPathComponent("grok")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        // A link to the same file is one copy, listed under the first folder it was found in.
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("grok"), withDestinationURL: real)
        // A file without the executable bit is not a copy.
        try Data("x".utf8).write(to: third.appendingPathComponent("grok"))

        let found = ExecutableDiscovery.find("grok", in: [first.path, "", second.path, third.path])
        XCTAssertEqual(found, [first.appendingPathComponent("grok").path])
    }

    func testVersionOfAMissingFileIsNil() {
        XCTAssertNil(ExecutableDiscovery.version(of: "/nonexistent/rota-cli", timeout: 2))
    }

    func testVersionReadsTheFirstLine() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("rota-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        try Data("#!/bin/sh\necho 'tool 1.2.3'\necho second\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // This integration check tests parsing, not the production startup deadline.
        XCTAssertEqual(ExecutableDiscovery.version(of: script.path, timeout: 30), "tool 1.2.3")
    }
}

final class ModelChoiceTests: XCTestCase {
    func testModelAndEffortBecomeFlagsForTheCLIsThatTakeThem() {
        func spec(model: String?, effort: String?) -> LaunchSpec {
            LaunchSpec(executable: "/x", prompt: "p", arguments: [], workingDirectory: "/", environment: [:],
                       mode: .claudeStream, timeout: nil, log: URL(fileURLWithPath: "/tmp/x.log"),
                       model: model, effort: effort)
        }
        XCTAssertEqual(spec(model: "opus", effort: "high").modelFlags(effortFlag: "--effort"),
                       ["--model", "opus", "--effort", "high"])
        XCTAssertEqual(spec(model: nil, effort: "low").modelFlags(effortFlag: "--reasoning-effort"),
                       ["--reasoning-effort", "low"])
        XCTAssertEqual(spec(model: nil, effort: nil).modelFlags(effortFlag: "--effort"), [])
        // The routine's choice travels in the spec, not in the harness's arguments.
        XCTAssertFalse(Harness.claude.arguments(settings: ClaudeUserSettings()).contains("--model"))
    }

    func testGrokModelsAreParsed() {
        let text = """
            You are logged in with grok.com.

            Default model: grok-4.7

            Available models:
              * grok-4.7 (default)
              - grok-4.6
            """
        let models = ModelCatalog.parseGrokModels(text)
        XCTAssertEqual(models.map(\.id), ["grok-4.7", "grok-4.6"])
        XCTAssertEqual(models.map(\.isDefault), [true, false])
    }

    func testCodexModelListKeepsVisibleModelsWithTheirEfforts() {
        let reply: [String: Any] = ["data": [
            ["id": "gpt-6-sol", "displayName": "GPT-6-Sol", "isDefault": true,
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]],
            ["id": "secret", "hidden": true, "supportedReasoningEfforts": []],
            ["id": "gpt-6-luna", "supportedReasoningEfforts": ["medium"]]
        ]]
        let models = ModelCatalog.parseCodexModels(reply)
        XCTAssertEqual(models.map(\.id), ["gpt-6-sol", "gpt-6-luna"])
        XCTAssertEqual(models.first?.efforts, ["low", "high"])
        XCTAssertEqual(models.first?.title, "GPT-6-Sol")
        XCTAssertEqual(models.last?.efforts, ["medium"])
    }

    func testRoutinesSavedBeforeModelsLoadWithoutOne() throws {
        let json = """
            [{"id":"r","name":"R","workingDirectory":"/p","schedule":"0 9 * * *","harness":"codex",
              "enabled":true,"prompt":"go","timeoutMinutes":30}]
            """
        let routines = try JSONDecoder().decode([Routine].self, from: Data(json.utf8))
        XCTAssertNil(routines.first?.model)
        XCTAssertNil(routines.first?.effort)
        // 0.1 saved timeoutMinutes: 30 was chosen and stays, its default 60 loads as no limit.
        XCTAssertEqual(routines.first?.timeLimitMinutes, 30)
        let defaulted = try JSONDecoder().decode([Routine].self, from: Data(json.replacingOccurrences(
            of: "\"timeoutMinutes\":30", with: "\"timeoutMinutes\":60").utf8))
        XCTAssertNil(defaulted.first?.timeLimitMinutes)
        // A routine saved by this version round-trips without the old key.
        let saved = try JSONEncoder().encode(defaulted)
        XCTAssertFalse(String(bytes: saved, encoding: .utf8)?.contains("timeoutMinutes") ?? true)
    }
}

final class ScheduleTextTests: XCTestCase {
    /// The form's menu titles each preset by its description, so none may lack one.
    func testEveryPresetReadsAsWords() {
        for cron in ScheduleText.presets {
            XCTAssertNotNil(ScheduleText.describe(cron, locale: Locale(identifier: "en_US")), cron)
        }
    }

    private let english = Locale(identifier: "en_US")

    func testCommonShapesReadAsWords() {
        XCTAssertEqual(ScheduleText.describe("0 10 * * *", locale: english), "Every day at 10:00\u{202F}AM")
        XCTAssertEqual(ScheduleText.describe("30 10 * * 5", locale: english), "Fridays at 10:30\u{202F}AM")
        XCTAssertEqual(ScheduleText.describe("7 13 * * 1,3,5", locale: english), "Mon, Wed, Fri at 1:07\u{202F}PM")
        XCTAssertEqual(ScheduleText.describe("0 9 * * 1-5", locale: english), "Weekdays at 9:00\u{202F}AM")
        XCTAssertEqual(ScheduleText.describe("0 9 * * 0,6", locale: english), "Weekends at 9:00\u{202F}AM")
        XCTAssertEqual(ScheduleText.describe("0 9 * * 7", locale: english), "Sundays at 9:00\u{202F}AM")
        XCTAssertEqual(ScheduleText.describe("10 14,17 * * *", locale: english),
                       "Every day at 2:10\u{202F}PM, 5:10\u{202F}PM")
        XCTAssertEqual(ScheduleText.describe("15 * * * *", locale: english), "Every hour at :15")
        XCTAssertEqual(ScheduleText.describe("0 */6 * * *", locale: english), "Every 6 hours at :00")
        XCTAssertEqual(ScheduleText.describe("*/15 * * * *", locale: english), "Every 15 minutes")
        XCTAssertEqual(ScheduleText.describe("0 8 1 * *", locale: english), "Monthly on day 1 at 8:00\u{202F}AM")
        // Shapes words would blur stay cron.
        XCTAssertNil(ScheduleText.describe("0 9 1 * 1"))
        XCTAssertNil(ScheduleText.describe("0 9 * 6 *"))
        XCTAssertNil(ScheduleText.describe("not cron"))
    }

    func testRRulesBecomeCron() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Wednesday 2026-10-07 09:30 in Los Angeles.
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 30))
        func cron(_ rule: String) -> String? { ScheduleText.cron(fromRRule: rule, anchor: anchor, calendar: calendar) }
        XCTAssertEqual(cron("FREQ=HOURLY;INTERVAL=24;BYMINUTE=0"), "0 9 * * *")
        XCTAssertEqual(cron("FREQ=HOURLY;INTERVAL=1;BYMINUTE=15"), "15 * * * *")
        XCTAssertEqual(cron("FREQ=HOURLY;INTERVAL=6;BYMINUTE=0"), "0 3,9,15,21 * * *")
        XCTAssertEqual(cron("FREQ=DAILY;BYHOUR=10;BYMINUTE=30"), "30 10 * * *")
        XCTAssertEqual(cron("RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=8;BYMINUTE=5"), "5 8 * * 1,3,5")
        XCTAssertEqual(cron("FREQ=WEEKLY"), "30 9 * * 3")
        XCTAssertEqual(cron("FREQ=HOURLY;INTERVAL=168;BYMINUTE=0"), "0 9 * * 3")
        XCTAssertEqual(cron("FREQ=MINUTELY;INTERVAL=15"), "*/15 * * * *")
        XCTAssertNil(cron("FREQ=MONTHLY;BYMONTHDAY=1"))
        XCTAssertNil(cron("FREQ=DAILY;INTERVAL=2;BYHOUR=9"))
        XCTAssertNil(cron("FREQ=WEEKLY;BYDAY=XX;BYHOUR=9"))
        XCTAssertNil(ScheduleText.cron(fromRRule: "FREQ=DAILY", anchor: nil))
    }

    func testIdentifiersKeepEveryScript() {
        XCTAssertEqual(RoutineImport.identifier(from: "Weekly SEO: report"), "weekly-seo-report")
        XCTAssertEqual(RoutineImport.identifier(from: "Отчёт по SEO"), "отчёт-по-seo")
    }

    func testRRuleMinuteListsAndIntervalPhasesArePreserved() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 1, minute: 7))!
        func cron(_ rule: String) -> String? { ScheduleText.cron(fromRRule: rule, anchor: anchor, calendar: calendar) }
        XCTAssertEqual(cron("FREQ=DAILY;BYHOUR=9;BYMINUTE=5,35"), "5,35 9 * * *")
        XCTAssertEqual(cron("FREQ=HOURLY;INTERVAL=4"), "7 1,5,9,13,17,21 * * *")
        XCTAssertEqual(cron("FREQ=MINUTELY;INTERVAL=15"), "7,22,37,52 * * * *")
        XCTAssertNil(cron("FREQ=DAILY;BYHOUR=9;BYMINUTE=bad"))
    }
}

final class CodexAutomationsImportTests: XCTestCase {
    /// A store with the Codex app's `automations` schema, read 2026-10-09.
    private func store(_ rows: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rota-codex-\(UUID().uuidString).db")
        let schema = """
            CREATE TABLE automations (id TEXT PRIMARY KEY, name TEXT NOT NULL, prompt TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'ACTIVE', next_run_at INTEGER, last_run_at INTEGER,
              cwds TEXT NOT NULL DEFAULT '[]', rrule TEXT NOT NULL DEFAULT 'FREQ=HOURLY;INTERVAL=24;BYMINUTE=0',
              model TEXT, reasoning_effort TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              target_type TEXT, project_id TEXT, kind TEXT NOT NULL DEFAULT 'cron', target_thread_id TEXT,
              execution_environment TEXT, local_environment_config_path TEXT, plugin_template_id TEXT,
              notification_policy TEXT, account_id TEXT, user_id TEXT, installation_id TEXT,
              legacy_automation_id TEXT);
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, schema + rows.joined(separator: "\n")]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return url
    }

    func testAutomationsBecomeCodexRoutinesWithTheirModel() throws {
        let url = try store([
            """
            INSERT INTO automations (id, name, prompt, status, cwds, rrule, model, reasoning_effort, created_at,
              updated_at) VALUES ('a1', 'Daily digest', 'Summarize.', 'ACTIVE', '["/p/one"]',
              'FREQ=DAILY;BYHOUR=7;BYMINUTE=15', 'gpt-6-sol', 'high', 0, 0);
            """,
            """
            INSERT INTO automations (id, name, prompt, status, cwds, rrule, created_at, updated_at, target_thread_id)
              VALUES ('a2', 'Follow up', 'Check.', 'PAUSED', '["/p"]', 'FREQ=DAILY;BYHOUR=9', 0, 0, 'thread-9');
            """,
            """
            INSERT INTO automations (id, name, prompt, status, cwds, rrule, created_at, updated_at)
              VALUES ('a3', 'Monthly', 'Bill.', 'PAUSED', '["/p"]', 'FREQ=MONTHLY;BYMONTHDAY=1', 0, 0);
            """
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let candidates = try CodexAutomationsImport.candidates(from: url)
        XCTAssertEqual(candidates.map(\.routine.id), ["daily-digest", "follow-up", "monthly"])
        let digest = candidates[0]
        XCTAssertEqual(digest.routine.harness, .codex)
        XCTAssertEqual(digest.routine.schedule, "15 7 * * *")
        XCTAssertEqual(digest.routine.workingDirectory, "/p/one")
        XCTAssertEqual(digest.routine.model, "gpt-6-sol")
        XCTAssertEqual(digest.routine.effort, "high")
        XCTAssertFalse(digest.routine.enabled)
        XCTAssertTrue(digest.onInSource)
        XCTAssertNil(digest.unsupported)
        XCTAssertFalse(candidates[1].onInSource)
        XCTAssertNotNil(candidates[1].unsupported, "a thread follow-up is not a routine")
        XCTAssertNotNil(candidates[2].unsupported, "a monthly rule has no cron here")
    }

    func testAStoreWithoutAutomationsHasNothingToImport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rota-codex-\(UUID().uuidString).db")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "CREATE TABLE other (id TEXT);"]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try CodexAutomationsImport.candidates(from: url), [])
    }
}

final class LoginPathTests: XCTestCase {
    /// The answer comes from a fresh login shell, not from the PATH Rota was started with.
    func testLoginPathIgnoresTheLaunchingEnvironment() {
        let original = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "/rota-leaked-wrapper/bin:/usr/bin:/bin", 1)
        defer { setenv("PATH", original, 1) }
        let path = ExecutableDiscovery.loginPath()
        XCTAssertFalse(path.isEmpty)
        XCTAssertFalse(path.contains("/rota-leaked-wrapper/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }
}

final class TerminalLauncherTests: XCTestCase {
    func testOnlyGhosttyTakesTheScriptAsAnArgument() {
        XCTAssertEqual(KnownTerminal.ghostty.arguments(running: "/s.command"), ["-e", "/s.command"])
        XCTAssertNil(KnownTerminal.terminal.arguments(running: "/s.command"))
        XCTAssertNil(KnownTerminal.iTerm.arguments(running: "/s.command"))
    }
}

final class TranscriptTurnTests: XCTestCase {
    func testWorkUpToTheLastToolThenTheAnswer() {
        let log = """
            [you] Check the site
            Looking at the pages.
            -> Bash curl -I https://example.com
            -> Read index.html

            All three pages answer 200.
            [result: succeeded after 12 s]
            [you] Thanks
            You're welcome.
            """
        let turns = TranscriptTurn.group(Transcript.parse(log))
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].prompt?.text, "Check the site")
        XCTAssertEqual(turns[0].work.map(\.kind), [.agent, .tool, .tool])
        XCTAssertEqual(turns[0].toolCount, 2)
        XCTAssertEqual(turns[0].answer.map(\.text), ["All three pages answer 200."])
        XCTAssertEqual(turns[0].notes.map(\.kind), [.status])
        XCTAssertEqual(turns[1].work, [])
        XCTAssertEqual(turns[1].answer.map(\.text), ["You're welcome."])
    }

    func testAnAnswerSplitAtBlankLinesReadsAsOneMessage() {
        let log = "[you] Report\n## Review\nAll good.\n\n- one\n- two\n\nDone."
        let turn = TranscriptTurn.group(Transcript.parse(log))[0]
        XCTAssertEqual(turn.answer.count, 3)
        XCTAssertEqual(turn.answerMessages.map(\.text), ["## Review\nAll good.\n\n- one\n- two\n\nDone."])
        let shell = TranscriptTurn.group(Transcript.parse("[you] ls\na\n\nb", shell: true))[0]
        XCTAssertEqual(shell.answerMessages.map(\.kind), shell.answer.map(\.kind))
    }

    func testAShellRunIsItsOutput() {
        let log = "[you] echo hi\nhi\n[result: succeeded after 1 s]"
        let turns = TranscriptTurn.group(Transcript.parse(log, shell: true))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].answer.map(\.kind), [.output])
        XCTAssertEqual(turns[0].work, [])
    }
}

final class ToolStepTests: XCTestCase {
    func testKindsAcrossHarnesses() {
        XCTAssertEqual(ToolStep.kind(of: "Bash ls -la"), .execute)
        XCTAssertEqual(ToolStep.kind(of: "$ /bin/zsh -lc 'echo hi'"), .execute, "Codex")
        XCTAssertEqual(ToolStep.kind(of: "run_terminal_command"), .execute, "Grok")
        XCTAssertEqual(ToolStep.kind(of: "Read /p/a.swift"), .read)
        XCTAssertEqual(ToolStep.kind(of: "Edit /p/a.swift"), .edit)
        XCTAssertEqual(ToolStep.kind(of: "edit files"), .edit, "Codex file change")
        XCTAssertEqual(ToolStep.kind(of: "Grep pattern"), .search)
        XCTAssertEqual(ToolStep.kind(of: "WebFetch https://example.com"), .fetch)
        XCTAssertEqual(ToolStep.kind(of: "mcp__computer-use__screenshot"), .other)
    }

    func testARunIsSummedUpByWhatItDid() {
        let run = ["Bash a", "Bash b", "Read x", "Edit y", "Edit z", "Edit w", "mcp__rota__list_routines"]
        XCTAssertEqual(ToolStep.summary(run), "read 1 file, ran 2 commands, edited 3 files, used 1 tool")
        XCTAssertEqual(ToolStep.dominant(run), .edit)
        XCTAssertEqual(ToolStep.dominant(["Bash a", "Read b"]), .execute, "a tie goes to the kind that changes more")
        XCTAssertEqual(ToolStep.summary(["Grep a"]), "1 search")
    }
}

final class PlanTests: XCTestCase {
    func testPlansFromEachHarnessReadAsTheLatestPerTurn() {
        let first = PlanStep.lines([PlanStep(status: "completed", text: "Read the config"),
                                    PlanStep(status: "in_progress", text: "Check each page"),
                                    PlanStep(status: "pending", text: "Report")])
        let second = PlanStep.lines([PlanStep(status: "completed", text: "Read the config"),
                                     PlanStep(status: "inProgress", text: "Check each page"),
                                     PlanStep(status: nil, text: "Report")])
        let turns = TranscriptTurn.group(Transcript.parse("[you] Go\n\(first)\n\(second)\nDone."))
        XCTAssertEqual(turns.count, 1)
        let steps = PlanStep.parse(turns[0].plan?.text ?? "")
        XCTAssertEqual(steps.map(\.status), [.completed, .inProgress, .pending], "two updates in a row stay two plans")
        XCTAssertEqual(steps.map(\.text), ["Read the config", "Check each page", "Report"])
        XCTAssertEqual(turns[0].answer.map(\.text), ["Done."])
    }

    func testClaudeTodoWriteBecomesAPlan() {
        // swiftlint:disable:next line_length
        let event = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Fix the link","status":"in_progress","activeForm":"Fixing"}]}}]}}"#
        let lines = StreamJSONFormatter.format(event) ?? ""
        let item = Transcript.parse(lines).first
        XCTAssertEqual(item?.kind, .plan)
        XCTAssertEqual(PlanStep.parse(item?.text ?? ""), [PlanStep(status: .inProgress, text: "Fix the link")])
    }
}

final class OutgoingTests: XCTestCase {
    func testAMessageShowsAsSendingUntilTheLogHasIt() {
        let before = Transcript.parse("[you] Check it\nLooking.")
        let message = Outgoing(text: "Also say EXTRA", seen: Outgoing.count("Also say EXTRA", in: before))
        XCTAssertFalse(message.delivered(in: before))
        XCTAssertTrue(message.delivered(in: Transcript.parse("[you] Check it\nLooking.\n[you] Also say EXTRA")))
        // The same words sent twice wait for the second copy.
        let again = Outgoing(text: "ok", seen: 1)
        XCTAssertFalse(again.delivered(in: Transcript.parse("[you] ok\nfine")))
        XCTAssertTrue(again.delivered(in: Transcript.parse("[you] ok\nfine\n[you] ok")))
    }
}
