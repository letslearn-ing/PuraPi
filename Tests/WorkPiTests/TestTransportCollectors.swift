import Foundation
import PiRPC
@testable import WorkPi

final class ModeTransportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(PiRuntimeLaunchMode, FakePiRPCTransport)] = []

    func make(_ mode: PiRuntimeLaunchMode) -> any PiRPCTransport {
        let transport = FakePiRPCTransport()
        lock.lock()
        entries.append((mode, transport))
        lock.unlock()
        return transport
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func transport(at index: Int) -> FakePiRPCTransport? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(index) else { return nil }
        return entries[index].1
    }

    func mode(at index: Int) -> PiRuntimeLaunchMode? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(index) else { return nil }
        return entries[index].0
    }
}

final class TestTransportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakePiRPCTransport] = []

    func make() -> any PiRPCTransport {
        let transport = FakePiRPCTransport()
        lock.lock()
        transports.append(transport)
        lock.unlock()
        return transport
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return transports.count
    }

    func runningCount() async -> Int {
        let snapshot = lock.withLock { transports }
        var count = 0
        for transport in snapshot where await transport.isRunning {
            count += 1
        }
        return count
    }

    func allStopped() async -> Bool {
        await runningCount() == 0
    }
}
