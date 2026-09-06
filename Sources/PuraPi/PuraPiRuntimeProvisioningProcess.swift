import Darwin
import Foundation

struct PuraPiProcessRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?
    let timeout: TimeInterval
    let outputLimit: Int

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 30,
        outputLimit: Int = PuraPiRuntimePolicy.maxProcessOutputBytes
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = max(0.1, timeout)
        self.outputLimit = max(1, outputLimit)
    }
}

struct PuraPiProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let stdoutWasTruncated: Bool
    let stderrWasTruncated: Bool

    var succeeded: Bool { status == 0 }

    var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var diagnosticText: String {
        [stdoutText, stderrText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum PuraPiProcessError: LocalizedError, Equatable, Sendable {
    case executableNotFound(URL)
    case launchFailed(String)
    case timedOut(URL)
    case cancelled(URL)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            return "找不到可执行文件：\(url.path)"
        case .launchFailed(let message):
            return "无法启动安装进程：\(message)"
        case .timedOut(let url):
            return "进程执行超时：\(url.lastPathComponent)"
        case .cancelled(let url):
            return "进程已取消：\(url.lastPathComponent)"
        }
    }
}

protocol PuraPiProcessRunner: Sendable {
    func run(_ request: PuraPiProcessRequest) async throws -> PuraPiProcessResult
}

/// 进程状态只在这个小对象中跨取消回调和后台执行线程共享。
private final class PuraPiProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { terminate(process) }
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = self.process
        lock.unlock()
        if let process { terminate(process) }
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }
}

private final class PuraPiOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            wasTruncated = true
        }
    }

    func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, wasTruncated)
    }
}

struct PuraPiDefaultProcessRunner: PuraPiProcessRunner {
    func run(_ request: PuraPiProcessRequest) async throws -> PuraPiProcessResult {
        let control = PuraPiProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try control.execute(request)
            }.value
        }, onCancel: {
            control.cancel()
        })
    }
}

private extension PuraPiProcessControl {
    func execute(_ request: PuraPiProcessRequest) throws -> PuraPiProcessResult {
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw PuraPiProcessError.executableNotFound(request.executableURL)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = PuraPiOutputBuffer(limit: request.outputLimit)
        let stderrBuffer = PuraPiOutputBuffer(limit: request.outputLimit)
        let readers = DispatchGroup()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw PuraPiProcessError.launchFailed(error.localizedDescription)
        }
        attach(process)

        startReader(
            stdoutPipe.fileHandleForReading,
            buffer: stdoutBuffer,
            group: readers
        )
        startReader(
            stderrPipe.fileHandleForReading,
            buffer: stderrBuffer,
            group: readers
        )

        let deadline = Date().addingTimeInterval(request.timeout)
        var timedOut = false
        while process.isRunning {
            if isCancelled() {
                terminateAndWait(process)
                detach()
                closeAndWait(
                    stdoutPipe.fileHandleForReading,
                    stderrPipe.fileHandleForReading,
                    readers: readers
                )
                throw PuraPiProcessError.cancelled(request.executableURL)
            }
            if Date() >= deadline {
                timedOut = true
                terminateAndWait(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            terminateAndWait(process)
        } else {
            process.waitUntilExit()
        }
        detach()
        closeAndWait(
            stdoutPipe.fileHandleForReading,
            stderrPipe.fileHandleForReading,
            readers: readers
        )

        if isCancelled() {
            throw PuraPiProcessError.cancelled(request.executableURL)
        }
        if timedOut {
            throw PuraPiProcessError.timedOut(request.executableURL)
        }

        let (stdout, stdoutWasTruncated) = stdoutBuffer.snapshot()
        let (stderr, stderrWasTruncated) = stderrBuffer.snapshot()
        return PuraPiProcessResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            stdoutWasTruncated: stdoutWasTruncated,
            stderrWasTruncated: stderrWasTruncated
        )
    }

    func startReader(
        _ handle: FileHandle,
        buffer: PuraPiOutputBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    guard let data = try handle.read(upToCount: 16 * 1024), !data.isEmpty else {
                        return
                    }
                    buffer.append(data)
                } catch {
                    return
                }
            }
        }
    }

    func terminateAndWait(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    func closeAndWait(
        _ stdout: FileHandle,
        _ stderr: FileHandle,
        readers: DispatchGroup
    ) {
        stdout.closeFile()
        stderr.closeFile()
        _ = readers.wait(timeout: .now() + 1)
    }
}

protocol PuraPiArtifactDownloader: Sendable {
    func download(url: URL, to destination: URL, maximumBytes: Int) async throws
}

/// 只允许 HTTPS 的固定官方主机，并通过系统 curl 直接下载；不经过 Shell。
struct PuraPiCurlArtifactDownloader: PuraPiArtifactDownloader {
    let runner: any PuraPiProcessRunner
    let environment: [String: String]

    init(
        runner: any PuraPiProcessRunner = PuraPiDefaultProcessRunner(),
        environment: [String: String] = PuraPiRuntimeEnvironment.safeEnvironment()
    ) {
        self.runner = runner
        self.environment = environment
    }

    func download(url: URL, to destination: URL, maximumBytes: Int) async throws {
        guard maximumBytes > 0,
              PuraPiRuntimeEnvironment.isAllowedArtifactURL(url)
        else {
            throw PuraPiRuntimeProvisioningError.network("下载地址不是受信任的 HTTPS 官方地址。")
        }
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        let request = PuraPiProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--proto", "=https",
                "--proto-redir", "=https",
                "--connect-timeout", "20",
                "--max-time", "300",
                "--max-filesize", String(maximumBytes),
                "--output", temporary.path,
                "--write-out", "\\n%{url_effective}\\n",
                url.absoluteString,
            ],
            environment: environment,
            timeout: 320,
            outputLimit: 16 * 1024
        )
        let result: PuraPiProcessResult
        do {
            result = try await runner.run(request)
        } catch let error as PuraPiRuntimeProvisioningError {
            throw error
        } catch {
            throw PuraPiRuntimeProvisioningError.network(error.localizedDescription)
        }
        guard result.succeeded else {
            throw PuraPiRuntimeProvisioningError.network(
                result.diagnosticText.isEmpty
                    ? "curl 返回状态码 \(result.status)。"
                    : String(result.diagnosticText.prefix(2_000))
            )
        }

        let effectiveURL = result.stdoutText
            .split(whereSeparator: \.isNewline)
            .last
            .flatMap { URL(string: String($0)) }
        guard let effectiveURL,
              PuraPiRuntimeEnvironment.isAllowedArtifactURL(effectiveURL)
        else {
            throw PuraPiRuntimeProvisioningError.network("下载重定向到了非官方地址。")
        }

        let attributes = try fileManager.attributesOfItem(atPath: temporary.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= Int64(maximumBytes) else {
            throw PuraPiRuntimeProvisioningError.network("下载文件超过安全大小上限。")
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }
}

enum PuraPiRuntimeEnvironment {
    static let knownExecutableDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
    ]

    static func safeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in base {
            let uppercased = key.uppercased()
            // 安装器/版本探测不需要 API 凭据，也不能把 Xcode/调试器的动态
            // 加载设置带进 Node/npm/curl 子进程。
            if uppercased.contains("KEY")
                || uppercased.contains("TOKEN")
                || uppercased.contains("SECRET")
                || uppercased.contains("PASSWORD")
                || uppercased.hasPrefix("NPM_CONFIG_")
                || uppercased.hasPrefix("DYLD_")
                || uppercased.hasPrefix("__XPC_DYLD_")
                || uppercased == "LD_PRELOAD"
                || uppercased == "LD_LIBRARY_PATH"
                || uppercased == "NODE_OPTIONS"
                || uppercased == "NODE_PATH" {
                continue
            }
            result[key] = value
        }
        let home = homeDirectory.standardizedFileURL.path
        let existing = result["PATH"]?.split(separator: ":").map(String.init) ?? []
        let extra = [
            "\(home)/.volta/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.asdf/shims",
            "\(home)/.mise/shims",
            "\(home)/.bun/bin",
            "\(home)/.pi/agent/bin",
            "\(home)/.local/share/pi-node/current/bin",
        ] + knownExecutableDirectories
        var paths: [String] = []
        for path in existing + extra where !path.isEmpty && !paths.contains(path) {
            paths.append(path)
        }
        result["PATH"] = paths.joined(separator: ":")
        result["HOME"] = home
        return result
    }

    static func environment(
        base: [String: String],
        homeDirectory: URL,
        prepend: [String]
    ) -> [String: String] {
        var result = base
        let home = homeDirectory.standardizedFileURL.path
        let existing = result["PATH"]?.split(separator: ":").map(String.init) ?? []
        let required = prepend + [
            "\(home)/.volta/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.asdf/shims",
            "\(home)/.mise/shims",
            "\(home)/.bun/bin",
            "\(home)/.pi/agent/bin",
            "\(home)/.local/share/pi-node/current/bin",
        ] + knownExecutableDirectories
        var paths: [String] = []
        for path in required + existing where !path.isEmpty && !paths.contains(path) {
            paths.append(path)
        }
        result["PATH"] = paths.joined(separator: ":")
        result["HOME"] = home
        return result
    }

    static func isAllowedArtifactURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "nodejs.org" || host == "www.nodejs.org"
    }
}
