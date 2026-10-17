@testable import RotaCore
import XCTest

final class ChatAttachmentTests: XCTestCase {
    private var folder: URL!
    private var source: URL!
    private var store: ChatAttachmentStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("Notes [draft]\ncopy.txt")
        try Data("synthetic attachment".utf8).write(to: source)
        store = ChatAttachmentStore(log: folder.appendingPathComponent("session.log"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testCopiesAreIndependentAndDiscardNeverRemovesTheOriginal() throws {
        let first = try XCTUnwrap(store.stage([source]).first)
        let second = try XCTUnwrap(store.stage([source]).first)
        XCTAssertNotEqual(first.path, second.path)
        let original = try Data(contentsOf: source)
        try Data("changed source".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: first.url), original)
        try store.discard(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("changed source".utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), original)
        XCTAssertThrowsError(try store.discard(ChatAttachment(name: "original", path: source.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testBatchFailureRollsBackOnlyNewCopiesAndRejectsFoldersAndLinks() throws {
        let kept = try XCTUnwrap(store.stage([source]).first)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.folder.path)
        XCTAssertThrowsError(try store.stage([source, folder.appendingPathComponent("missing")]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.path), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertThrowsError(try store.stage([folder]))
        XCTAssertThrowsError(try store.stage([URL(string: "https://example.com/file")!] ))
        let outside = folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let escaped = ChatAttachmentStore(log: folder.appendingPathComponent("escaped.log"))
        try FileManager.default.createSymbolicLink(at: escaped.folder, withDestinationURL: outside)
        XCTAssertThrowsError(try escaped.stage([source]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testFileOnlyMessageRoundTripsAndMalformedManifestsRemainVisible() throws {
        let attachments = try store.stage([source])
        let message = ChatMessage(text: "", attachments: attachments)
        let encoded = try message.encoded()
        XCTAssertTrue(encoded.contains("[Rota attachments v1]"))
        XCTAssertTrue(encoded.contains("\\ncopy.txt"))
        XCTAssertEqual(ChatMessage.decode(encoded), message)
        let text = "Keep this literal\n\n[Rota attachments v1]\nnot JSON"
        XCTAssertEqual(ChatMessage.decode(text), ChatMessage(text: text))
        XCTAssertEqual(try ChatMessage(text: "ordinary").encoded(), "ordinary")
    }

    func testSessionDeletionAndRetentionRemoveCopiesWhileSharedLogsKeepThem() throws {
        let location = StorageLocation(root: folder.appendingPathComponent("data"),
                                       logs: folder.appendingPathComponent("logs"))
        let history = RunHistory(location: location)
        var records: [RunRecord] = []
        for index in 0...RunHistory.limit {
            var record = RunRecord(routineID: "fixture", trigger: .manual, harness: .codex,
                                   startedAt: Date(timeIntervalSince1970: Double(index)), outcome: .succeeded)
            record.logPath = history.logFile(for: record).path
            _ = try history.attachments(for: record).stage([source])
            try history.upsert(record)
            records.append(record)
        }
        let firstStore = try history.attachments(for: records[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstStore.folder.path))
        let last = try XCTUnwrap(records.last)
        let lastStore = try history.attachments(for: last)
        var shared = last
        shared.id = UUID()
        shared.logPath = last.logPath?.replacingOccurrences(of: "/logs/fixture/", with: "/logs/fixture/../fixture/")
        try history.upsert(shared)
        XCTAssertTrue(try history.remove(last.id, for: last.routineID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lastStore.folder.path))
        XCTAssertTrue(try history.remove(shared.id, for: shared.routineID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lastStore.folder.path))
        history.removeAll(for: "fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try history.attachments(for: records[1]).folder.path))
    }
}
