import Foundation
import PiRPC

/// 可阻塞停止的测试 transport，用于制造重复生命周期竞态。
actor BlockingStopTransport: PiRPCTransport {
    private var continuation: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var running = false
    private var stopIsBlocked = true
    private var stopWasReleased = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopStarted = false
    private(set) var startedWhileStopping = false
    private(set) var sentCommands: [PiRPCCommand] = []
    private(set) var workspaceURL: URL?

    var isRunning: Bool { running }

    func start(in workspaceURL: URL) async throws -> AsyncThrowingStream<PiRPCTransportEvent, Error> {
        guard !running else {
            startedWhileStopping = true
            throw PiRPCError.alreadyRunning
        }
        running = true
        startCount += 1
        self.workspaceURL = workspaceURL.standardizedFileURL
        var captured: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<PiRPCTransportEvent, Error> { continuation in
            captured = continuation
        }
        guard let captured else { throw PiRPCError.invalidRecord("测试流创建失败") }
        continuation = captured
        return stream
    }

    func send(_ command: PiRPCCommand) async throws {
        guard running else { throw PiRPCError.notRunning }
        sentCommands.append(command)
    }

    func emit(_ event: PiRPCTransportEvent) {
        continuation?.yield(event)
    }

    func stop() async {
        stopCount += 1
        stopStarted = true
        if stopIsBlocked && !stopWasReleased {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        running = false
        continuation?.finish()
        continuation = nil
    }

    func releaseStop() {
        stopWasReleased = true
        stopIsBlocked = false
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

extension RuntimeBoundaryAuditTests {
    static func stateRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "id": .string("test-model"),
                    "provider": .string("test"),
                    "name": .string("Test model"),
                    "reasoning": .bool(true),
                ]),
                "thinkingLevel": .string("medium"),
                "messageCount": .integer(0),
            ]),
        ])
    }

    static func statsRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
            "data": .object([
                "contextUsage": .object([
                    "tokens": .integer(0),
                    "contextWindow": .integer(100_000),
                    "percent": .integer(0),
                ]),
            ]),
        ])
    }
}
