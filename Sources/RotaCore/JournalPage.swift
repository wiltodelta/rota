import Foundation

/// Reads complete entries backwards without scanning or retaining the preceding history.
/// Appends and completion records travel with the item that introduced their ID.
struct JournalPage {
    var records: [TranscriptRecord]
    var start: UInt64
    var partial: Data
    var bytesRead: Int

    static func read(_ url: URL, before: UInt64, count: Int, allowPartial: Bool = false) throws -> JournalPage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var cursor = ReverseLines(handle: handle, offset: before)
        var records: [TranscriptRecord] = []
        var partial = Data()
        var start: UInt64 = 0
        var remaining = count
        var first = true
        while let line = try cursor.previous() {
            if first {
                first = false
                // A terminating newline gives an empty first suffix. Without one the
                // first suffix is the writer's unfinished record, never a full entry.
                if line.data.isEmpty { continue }
                guard allowPartial else { throw JournalError.unsupported }
                partial = line.data
                continue
            }
            let record = try JSONDecoder().decode(TranscriptRecord.self, from: line.data)
            guard record.version == 1 else { throw JournalError.unsupported }
            records.append(record)
            if record.type == "header" {
                guard line.offset == 0 else { throw JournalError.unsupported }
                break
            }
            if record.type == "item" {
                remaining -= 1
                // The count is a target. Include the complete leading tool group
                // and its preceding boundary so prepending cannot regroup visible rows.
                let kind = TranscriptItem.Kind(rawValue: record.kind ?? "")
                if remaining <= 0, kind?.canJoinToolGroup != true {
                    start = line.offset
                    break
                }
            }
        }
        // The first item may directly follow the header. Let the next request consume
        // that header rather than reading backwards past a guessed byte length.
        return JournalPage(records: records.reversed(), start: start, partial: partial, bytesRead: cursor.bytesRead)
    }
}

private struct ReverseLines {
    let handle: FileHandle
    var offset: UInt64
    var buffer = Data()
    var bytesRead = 0
    var exhausted = false

    mutating func previous() throws -> (offset: UInt64, data: Data)? {
        guard !exhausted else { return nil }
        while true {
            if let newline = buffer.lastIndex(of: 10) {
                let result = Data(buffer[buffer.index(after: newline)...])
                let start = offset + UInt64(buffer.distance(from: buffer.startIndex, to: newline)) + 1
                buffer = Data(buffer[..<newline])
                return (start, result)
            }
            guard offset > 0 else {
                exhausted = true
                return buffer.isEmpty ? nil : (0, buffer)
            }
            let size = min(offset, 32_768)
            offset -= size
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(size)) ?? Data()
            guard data.count == Int(size) else { throw JournalError.unsupported }
            bytesRead += data.count
            buffer = data + buffer
        }
    }
}
