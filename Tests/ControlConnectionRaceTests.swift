import Darwin
@testable import RotaCore
import XCTest

@MainActor
final class ControlConnectionRaceTests: XCTestCase {
    func testAReplyFromAClosedConnectionCannotReachItsReusedDescriptor() async throws {
        let path = URL(fileURLWithPath: "/tmp/rota-race-\(UUID().uuidString.prefix(8)).sock")
        let slowStarted = expectation(description: "slow handler suspended")
        let slowEnded = expectation(description: "slow handler released")
        let fastStarted = expectation(description: "replacement client accepted")
        var slow: CheckedContinuation<Void, Never>?
        var fast: CheckedContinuation<Void, Never>?
        let server = ControlServer(socket: path) { method, _ in
            await withCheckedContinuation { continuation in
                if method == "slow" {
                    slow = continuation
                    slowStarted.fulfill()
                } else {
                    fast = continuation
                    fastStarted.fulfill()
                }
            }
            if method == "slow" { slowEnded.fulfill() }
            return .success(method)
        }
        try server.start()
        defer {
            slow?.resume()
            fast?.resume()
            server.stop()
        }
        let first = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try ControlServer.address(path.path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(first, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { close(first); return XCTFail("fixture could not connect") }
        sendSlowRequest(first)
        await fulfillment(of: [slowStarted], timeout: 5)
        let descriptor = try XCTUnwrap(server.connectedDescriptors.first)
        close(first)
        while server.connectedDescriptors.contains(descriptor) { await Task.yield() }
        let replacement = Task.detached {
            try ControlClient.call("fast", socket: path, timeout: 5) as? String
        }
        await fulfillment(of: [fastStarted], timeout: 5)
        XCTAssertEqual(server.connectedDescriptors, [descriptor], "the fixture must actually reuse the descriptor")
        slow?.resume()
        slow = nil
        await fulfillment(of: [slowEnded], timeout: 5)
        fast?.resume()
        fast = nil
        let response = try await replacement.value
        XCTAssertEqual(response, "fast", "an old reply must not precede the replacement client's own response")
    }

    private func sendSlowRequest(_ descriptor: Int32) {
        let request = Data("{\"id\":41,\"method\":\"slow\"}\n".utf8)
        XCTAssertEqual(request.withUnsafeBytes { write(descriptor, $0.baseAddress!, $0.count) }, request.count)
    }
}
