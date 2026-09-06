import Foundation

/// 无模型、无网络的测试传输。UI 测试可主动注入任意 Pi RPC 记录。
public actor FakePiRPCTransport: PiRPCTransport {
    private var continuation: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation?
    private var running = false
    public private(set) var sentCommands: [PiRPCCommand] = []
    public private(set) var workspaceURL: URL?

    public var isRunning: Bool { running }

    public init() {}

    public func start(in workspaceURL: URL) async throws -> AsyncThrowingStream<PiRPCTransportEvent, Error> {
        guard !running else { throw PiRPCError.alreadyRunning }
        running = true
        self.workspaceURL = workspaceURL.standardizedFileURL

        var captured: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<PiRPCTransportEvent, Error> { continuation in
            captured = continuation
        }
        guard let captured else {
            throw PiRPCError.invalidRecord("无法创建 Fake Pi RPC 事件流")
        }
        continuation = captured
        return stream
    }

    public func send(_ command: PiRPCCommand) async throws {
        guard running else { throw PiRPCError.notRunning }
        sentCommands.append(command)
    }

    public func emit(_ event: PiRPCTransportEvent) {
        continuation?.yield(event)
    }

    public func finish(throwing error: Error? = nil) {
        running = false
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    public func stop() async {
        finish()
    }
}
