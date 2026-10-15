import Darwin
import Foundation

/// Serial, nonblocking writes keep a provider that stops reading from blocking Stop or request deadlines.
final class PipeWriter: @unchecked Sendable {
    private let input: FileHandle
    private let queue: DispatchQueue
    private var bytes = Data()
    private var offset = 0
    private var source: DispatchSourceWrite?
    private var closed = false
    private struct Completion {
        var end: Int
        let work: () -> Void
    }
    private var completions: [Completion] = []
    var failed: (() -> Void)?

    init(_ input: FileHandle, queue: DispatchQueue = DispatchQueue(label: "com.wiltodelta.rota.pipe-writer")) {
        self.input = input
        self.queue = queue
        FileDescriptorIO.suppressBrokenPipe(input.fileDescriptor)
        _ = fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK)
    }

    func send(_ data: Data, completed: (() -> Void)? = nil) {
        let completed = UncheckedSendable(completed)
        queue.async {
            guard !self.closed else { return }
            if self.offset > 0 {
                self.bytes.removeFirst(self.offset)
                for index in self.completions.indices { self.completions[index].end -= self.offset }
                self.offset = 0
            }
            self.bytes.append(data)
            if let work = completed.value { self.completions.append(Completion(end: self.bytes.count, work: work)) }
            // Bound queued image requests, including their base64 expansion.
            guard self.bytes.count <= 320_000_000 else { return self.fail() }
            self.flush()
        }
    }

    func close() { queue.async { self.closeNow() } }

    private func flush() {
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.write(input.fileDescriptor, $0.baseAddress! + offset, $0.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                if source == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: input.fileDescriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    source.resume()
                    self.source = source
                }
                return
            }
            guard count > 0 else { return fail() }
            offset += count
            finishWrites()
        }
        finishWrites()
        bytes = Data()
        offset = 0
        source?.cancel()
        source = nil
    }

    private func finishWrites() {
        while let first = completions.first, first.end <= offset {
            completions.removeFirst().work()
        }
    }

    private func fail() {
        guard !closed else { return }
        closeNow()
        failed?()
    }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        bytes = Data()
        completions.removeAll()
        offset = 0
        try? input.close()
    }
}
