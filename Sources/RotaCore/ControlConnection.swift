import Darwin
import Foundation

/// Owned by ControlServer's serial queue. Identity survives descriptor reuse.
final class ControlConnection: @unchecked Sendable {
    let descriptor: Int32
    let reader: DispatchSourceRead
    var writer: DispatchSourceWrite?
    var input = Data()
    var output = Data()
    var offset = 0

    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setCancelHandler { close(descriptor) }
    }

    func cancel() {
        writer?.cancel()
        writer = nil
        reader.cancel()
    }

    /// Keep pending output bounded even if a client sends requests without reading replies.
    func enqueue(_ data: Data) -> Bool {
        if offset > 0 {
            output.removeFirst(offset)
            offset = 0
        }
        guard output.count + data.count <= 32 * 1024 * 1024 else { return false }
        output.append(data)
        return true
    }

    func flush() -> Bool {
        while offset < output.count {
            let count = output.withUnsafeBytes {
                write(descriptor, $0.baseAddress! + offset, $0.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return true }
            guard count > 0 else { return false }
            offset += count
        }
        output = Data()
        offset = 0
        writer?.cancel()
        writer = nil
        return true
    }
}
