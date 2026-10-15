import Darwin

/// A failed pipe or socket write must return an error instead of terminating Rota.
enum FileDescriptorIO {
    static func suppressBrokenPipe(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
}
