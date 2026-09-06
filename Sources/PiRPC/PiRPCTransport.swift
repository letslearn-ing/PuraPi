import Foundation

public protocol PiRPCTransport: AnyObject, Sendable {
    func start(in workspaceURL: URL) async throws -> AsyncThrowingStream<PiRPCTransportEvent, Error>
    func send(_ command: PiRPCCommand) async throws
    func stop() async
}

public enum PiRPCError: LocalizedError, Equatable, Sendable {
    case executableNotFound(String)
    case invalidWorkspace(URL)
    case alreadyRunning
    case notRunning
    case stdinClosed
    case invalidUTF8
    case invalidRecord(String)
    case recordTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "找不到 Pi 可执行文件“\(name)”。请在 PuraPi 设置中检查 Runtime，或设置 PI_EXECUTABLE。"
        case .invalidWorkspace(let url):
            return "无法在无效工作区启动 Pi：\(url.path)"
        case .alreadyRunning:
            return "Pi Runtime 已经在运行。"
        case .notRunning:
            return "Pi Runtime 尚未启动。"
        case .stdinClosed:
            return "Pi Runtime 的 stdin 已关闭。"
        case .invalidUTF8:
            return "Pi RPC stdout 包含无效 UTF-8。"
        case .invalidRecord(let line):
            return "Pi RPC 返回了无效 JSONL：\(line.prefix(160))"
        case .recordTooLarge(let bytes):
            return "Pi RPC 单条未分隔记录超过安全上限（\(bytes) bytes）。"
        }
    }
}

public struct PiExecutableResolver: Sendable {
    public let executableName: String
    public let environment: [String: String]

    public init(
        executableName: String = "pi",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableName = executableName
        self.environment = environment
    }

    public func resolve() -> URL? {
        if let override = environment["PI_EXECUTABLE"], isExecutable(override) {
            return URL(fileURLWithPath: override)
        }

        if executableName.contains("/"), isExecutable(executableName) {
            return URL(fileURLWithPath: executableName)
        }

        let searchPath = environment["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = searchPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(executableName).path
        } + [
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "\(home)/.pi/agent/bin/\(executableName)",
            "\(home)/.local/bin/\(executableName)",
            "\(home)/.local/share/pi-node/current/bin/\(executableName)",
        ]

        for candidate in candidates where isExecutable(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
