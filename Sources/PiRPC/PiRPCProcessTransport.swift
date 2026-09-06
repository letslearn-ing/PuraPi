import Darwin
import Foundation

private final class PendingWrite: @unchecked Sendable {
    let id: UUID
    let data: Data
    let handle: FileHandle
    private var resumed = false

    init(id: UUID, data: Data, handle: FileHandle) {
        self.id = id
        self.data = data
        self.handle = handle
    }

    // All calls are serialized by the transport state queue.
    func resume() {
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
    }

    func resume(throwing error: Error) {
        guard !resumed else { return }
        resumed = true
        continuation?.resume(throwing: error)
    }

    var continuation: CheckedContinuation<Void, Error>?
}

/// 真实的 `pi --mode rpc` 子进程传输。
/// 所有可变状态都限制在 stateQueue，stdout 由单一阻塞读取循环按顺序送入 JSONL 分帧器。
public final class PiRPCProcessTransport: PiRPCTransport, @unchecked Sendable {
    private let resolver: PiExecutableResolver
    private let processArguments: [String]
    private let environmentOverrides: [String: String]
    private let stateQueue = DispatchQueue(label: "WorkPi.PiRPCProcessTransport.state")
    /// stdin writes are deliberately kept off stateQueue.  FileHandle.write can
    /// block when a child stops draining its stdin; stop must still be able to
    /// close the descriptor and terminate the child.
    private let writeQueue = DispatchQueue(label: "WorkPi.PiRPCProcessTransport.writes")
    private let readerQueue = DispatchQueue(label: "WorkPi.PiRPCProcessTransport.readers", attributes: .concurrent)

    private var process: Process?
    /// 进程清理后旧 reader/termination 回调仍可能排队；用生命周期 token
    /// 防止它们写入下一次复用的 transport 状态。
    private var lifecycleID = UUID()
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var continuation: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation?
    private var framer = JSONLFramer()
    private var processExitStatus: Int32?
    private var stdoutEnded = false
    private var stderrEnded = false
    private var streamFinished = false
    private var stopRequested = false
    private var stopGraceAttempts = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWrites: [UUID: PendingWrite] = [:]
    /// The serial write queue has at most one active blocking pipe write.
    /// Cancelling that write requires closing stdin and terminating the runtime;
    /// otherwise the queue cannot make progress.
    private var activeWriteID: UUID?
    private var cancelledWriteIDs: Set<UUID> = []
    /// stderr 只保留一个有界尾部；避免启动错误因等待 processExited 而丢失，
    /// 也避免把无限输出积存在 WorkPi 内存中。
    private var stderrDiagnostic = ""
    private var stderrDiagnosticEmitted = false
    private static let maximumDiagnosticBytes = 32 * 1024
    private static let blockedRuntimeEnvironmentKeys: Set<String> = [
        "BASH_ENV",
        "ENV",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_INSERT_LIBRARIES",
        "NODE_OPTIONS",
        "NODE_PATH",
        "AI_AGENT",
        "PI_CODING_AGENT",
        "PI_SESSION_ID",
        "PI_SESSION_FILE",
        "PI_PROVIDER",
        "PI_MODEL",
        "PI_REASONING_LEVEL",
    ]

    public init(
        executableURL: URL? = nil,
        processArguments: [String] = ["--mode", "rpc"],
        environmentOverrides: [String: String] = [:]
    ) {
        if let executableURL {
            self.resolver = PiExecutableResolver(executableName: executableURL.path)
        } else {
            self.resolver = PiExecutableResolver()
        }
        self.processArguments = processArguments
        self.environmentOverrides = environmentOverrides
    }

    public func start(in workspaceURL: URL) async throws -> AsyncThrowingStream<PiRPCTransportEvent, Error> {
        try await withCheckedThrowingContinuation { result in
            stateQueue.async {
                do {
                    result.resume(returning: try self.startLocked(in: workspaceURL))
                } catch {
                    result.resume(throwing: error)
                }
            }
        }
    }

    public func send(_ command: PiRPCCommand) async throws {
        let data = try command.jsonLine()
        let writeID = UUID()
        let transport = self
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                stateQueue.async {
                    if self.cancelledWriteIDs.remove(writeID) != nil {
                        result.resume(throwing: CancellationError())
                        return
                    }
                    guard let process = self.process, process.isRunning else {
                        result.resume(throwing: PiRPCError.notRunning)
                        return
                    }
                    guard let stdinHandle = self.stdinHandle else {
                        result.resume(throwing: PiRPCError.stdinClosed)
                        return
                    }

                    let pending = PendingWrite(id: writeID, data: data, handle: stdinHandle)
                    pending.continuation = result
                    self.pendingWrites[writeID] = pending
                    self.writeQueue.async { [weak self, pending] in
                        guard let self,
                              self.stateQueue.sync(execute: {
                                  self.beginWriteLocked(pending.id)
                              })
                        else { return }
                        do {
                            // This is the only potentially blocking operation. It
                            // never runs on stateQueue. If cancellation reaches an
                            // active write, cancelWriteLocked closes stdin and
                            // terminates the child so this call cannot strand the
                            // serial write queue forever.
                            try pending.handle.write(contentsOf: pending.data)
                            self.stateQueue.sync {
                                self.finishWriteLocked(pending, error: nil)
                            }
                        } catch {
                            self.stateQueue.sync {
                                if let process = self.process, process.isRunning {
                                    process.terminate()
                                }
                                self.finishWriteLocked(pending, error: PiRPCError.stdinClosed)
                            }
                        }
                    }
                }
            }
        }, onCancel: {
            transport.stateQueue.async {
                if !transport.cancelWriteLocked(writeID) {
                    // The write already completed before cancellation reached
                    // stateQueue; no tombstone is needed for a finished ID.
                    transport.cancelledWriteIDs.insert(writeID)
                    if transport.cancelledWriteIDs.count > 1_024,
                       let oldest = transport.cancelledWriteIDs.first {
                        transport.cancelledWriteIDs.remove(oldest)
                    }
                }
            }
        })
    }

    public func stop() async {
        await withCheckedContinuation { (result: CheckedContinuation<Void, Never>) in
            stateQueue.async {
                self.stopWaiters.append(result)
                self.stopLocked()
                self.resumeStopWaitersIfStoppedLocked()
            }
        }
    }

    private func startLocked(in workspaceURL: URL) throws -> AsyncThrowingStream<PiRPCTransportEvent, Error> {
        guard process == nil else { throw PiRPCError.alreadyRunning }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PiRPCError.invalidWorkspace(workspaceURL)
        }
        guard let executableURL = resolver.resolve() else {
            throw PiRPCError.executableNotFound("pi")
        }

        resetStateLocked()
        let lifecycleID = self.lifecycleID

        var streamContinuation: AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<PiRPCTransportEvent, Error> { continuation in
            streamContinuation = continuation
        }
        guard let streamContinuation else {
            throw PiRPCError.invalidRecord("无法创建 Pi RPC 事件流")
        }
        continuation = streamContinuation
        let terminationHandler: @Sendable (AsyncThrowingStream<PiRPCTransportEvent, Error>.Continuation.Termination) -> Void = { [weak self] termination in
            guard case .cancelled = termination else { return }
            guard let self else { return }
            self.stateQueue.async {
                guard self.lifecycleID == lifecycleID else { return }
                self.stopLocked()
            }
        }
        continuation?.onTermination = terminationHandler

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = processArguments
        process.currentDirectoryURL = workspaceURL.standardizedFileURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = runtimeEnvironment(for: executableURL)

        process.terminationHandler = { [weak self] terminatedProcess in
            guard let owner = self else { return }
            let status = terminatedProcess.terminationStatus
            owner.stateQueue.async { [weak owner] in
                guard let owner, owner.lifecycleID == lifecycleID else { return }
                owner.processDidExitLocked(status: status, lifecycleID: lifecycleID)
            }
        }

        do {
            try process.run()
        } catch {
            continuation?.finish(throwing: error)
            continuation = nil
            throw error
        }

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        startStdoutReader(stdoutPipe.fileHandleForReading, lifecycleID: lifecycleID)
        startStderrReader(stderrPipe.fileHandleForReading, lifecycleID: lifecycleID)
        return stream
    }

    private func startStdoutReader(_ handle: FileHandle, lifecycleID: UUID) {
        readerQueue.async { [weak self] in
            guard let owner = self else { return }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                owner.stateQueue.async { [weak owner] in
                    guard let owner, owner.lifecycleID == lifecycleID else { return }
                    owner.consumeStdoutLocked(data, lifecycleID: lifecycleID)
                }
            }
            owner.stateQueue.async { [weak owner] in
                guard let owner, owner.lifecycleID == lifecycleID else { return }
                owner.stdoutDidEndLocked(lifecycleID: lifecycleID)
            }
        }
    }

    private func startStderrReader(_ handle: FileHandle, lifecycleID: UUID) {
        readerQueue.async { [weak self] in
            guard let owner = self else { return }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                owner.stateQueue.async { [weak owner] in
                    guard let owner, owner.lifecycleID == lifecycleID else { return }
                    owner.consumeStderrLocked(data, lifecycleID: lifecycleID)
                }
            }
            owner.stateQueue.async { [weak owner] in
                guard let owner, owner.lifecycleID == lifecycleID else { return }
                owner.stderrDidEndLocked(lifecycleID: lifecycleID)
            }
        }
    }

    private func consumeStdoutLocked(_ data: Data, lifecycleID: UUID) {
        guard self.lifecycleID == lifecycleID, !streamFinished else { return }
        do {
            for line in try framer.append(data) {
                try decodeAndYieldLocked(line)
            }
        } catch {
            failStreamLocked(error)
            process?.terminate()
        }
    }

    private func consumeStderrLocked(_ data: Data, lifecycleID: UUID) {
        guard self.lifecycleID == lifecycleID,
              !streamFinished,
              !data.isEmpty
        else { return }
        stderrDiagnostic.append(String(decoding: data, as: UTF8.self))
        if stderrDiagnostic.count > Self.maximumDiagnosticBytes {
            stderrDiagnostic = String(stderrDiagnostic.suffix(Self.maximumDiagnosticBytes))
        }
        // 不按 chunk 逐条发送 stderr：RPC stdout 事件流必须保证有界，
        // 否则消费者暂时繁忙时诊断文本会无限堆积。退出时统一附加尾部摘要。
    }

    private func decodeAndYieldLocked(_ line: Data) throws {
        guard let text = String(data: line, encoding: .utf8) else {
            throw PiRPCError.invalidUTF8
        }
        do {
            let record = try JSONDecoder().decode(PiRPCRecord.self, from: line)
            continuation?.yield(.record(record))
        } catch {
            throw PiRPCError.invalidRecord(text)
        }
    }

    private func stdoutDidEndLocked(lifecycleID: UUID) {
        guard self.lifecycleID == lifecycleID, !stdoutEnded else { return }
        stdoutEnded = true
        if let trailing = framer.finish() {
            do {
                try decodeAndYieldLocked(trailing)
            } catch {
                failStreamLocked(error)
                process?.terminate()
                return
            }
        }
        finishIfCompleteLocked()
    }

    private func stderrDidEndLocked(lifecycleID: UUID) {
        guard self.lifecycleID == lifecycleID else { return }
        stderrEnded = true
        finishIfCompleteLocked()
    }

    private func processDidExitLocked(status: Int32, lifecycleID: UUID) {
        guard self.lifecycleID == lifecycleID else { return }
        processExitStatus = status
        cancelAllPendingWritesLocked()
        stdinHandle?.closeFile()
        stdinHandle = nil
        if stopRequested || streamFinished {
            cleanupLocked()
            return
        }
        finishIfCompleteLocked()
        guard !streamFinished else { return }
        // 子进程可能派生出仍持有 stderr/stdout pipe 的子进程；如果无限等待
        // 这些句柄，Runtime 会永远没有终态。给已退出主进程一个短暂的排空窗口，
        // 然后由同一 stateQueue 强制结束流。
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self, self.lifecycleID == lifecycleID else { return }
            self.finishAfterProcessExitGraceLocked(lifecycleID: lifecycleID)
        }
    }

    private func finishAfterProcessExitGraceLocked(lifecycleID: UUID) {
        guard self.lifecycleID == lifecycleID,
              processExitStatus != nil,
              !streamFinished
        else { return }
        stdoutEnded = true
        stderrEnded = true
        finishIfCompleteLocked()
    }

    private func scheduleStopGraceLocked(lifecycleID: UUID) {
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self, self.lifecycleID == lifecycleID else { return }
            self.finishStopAfterGraceLocked(lifecycleID: lifecycleID)
        }
    }

    private func finishStopAfterGraceLocked(lifecycleID: UUID) {
        guard self.lifecycleID == lifecycleID, stopRequested else { return }
        guard let process else {
            cleanupLocked()
            return
        }
        if process.isRunning {
            stopGraceAttempts += 1
            if stopGraceAttempts >= 2 {
                // Escalate, but keep the process and stop waiters alive until the
                // terminationHandler confirms the exit.  Clearing them here would
                // allow a new Runtime to race the old PID and its pipe readers.
                _ = kill(process.processIdentifier, SIGKILL)
            }
            scheduleStopGraceLocked(lifecycleID: lifecycleID)
            return
        }
        // isRunning == false is only a hint; the termination handler is the
        // authoritative cleanup point.  Keep polling until it arrives.
        scheduleStopGraceLocked(lifecycleID: lifecycleID)
    }

    private func finishIfCompleteLocked() {
        guard !streamFinished,
              let status = processExitStatus,
              stdoutEnded,
              stderrEnded
        else { return }

        streamFinished = true
        let diagnostic = stderrDiagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        if diagnostic.isEmpty {
            continuation?.yield(.processExited(status: status))
        } else {
            // 诊断事件必须先于 stream 完成，控制器才能把真实启动原因展示给用户。
            continuation?.yield(
                .processExitedWithDiagnostic(status: status, diagnostic: diagnostic)
            )
        }
        continuation?.finish()
        cleanupLocked()
    }

    private func failStreamLocked(_ error: Error) {
        guard !streamFinished else { return }
        emitFinalDiagnosticLocked()
        streamFinished = true
        continuation?.finish(throwing: error)
        stopRequested = true
        cancelAllPendingWritesLocked()
        stdinHandle = nil
        if let process, process.isRunning {
            process.terminate()
            scheduleStopGraceLocked(lifecycleID: lifecycleID)
        } else {
            cleanupLocked()
        }
    }

    private func stopLocked() {
        guard !stopRequested else { return }
        stopRequested = true
        guard let process else {
            if !streamFinished {
                streamFinished = true
                continuation?.finish()
            }
            cleanupLocked()
            return
        }

        cancelAllPendingWritesLocked()
        stdinHandle?.closeFile()
        stdinHandle = nil
        if !streamFinished {
            streamFinished = true
            continuation?.finish()
        }
        if process.isRunning {
            process.terminate()
        }
        // cleanupLocked (and the stop waiters) is reached only from the
        // termination handler.  A grace timeout may escalate to SIGKILL, but
        // it must not pretend that Process has exited before that callback.
        scheduleStopGraceLocked(lifecycleID: lifecycleID)
    }

    private func resetStateLocked() {
        lifecycleID = UUID()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        continuation = nil
        framer = JSONLFramer()
        processExitStatus = nil
        stdoutEnded = false
        stderrEnded = false
        streamFinished = false
        stopRequested = false
        stopGraceAttempts = 0
        pendingWrites.removeAll()
        activeWriteID = nil
        cancelledWriteIDs.removeAll()
        stderrDiagnostic.removeAll(keepingCapacity: false)
        stderrDiagnosticEmitted = false
    }

    private func emitFinalDiagnosticLocked() {
        guard !stderrDiagnosticEmitted else { return }
        let diagnostic = stderrDiagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !diagnostic.isEmpty else { return }
        stderrDiagnosticEmitted = true
        continuation?.yield(.diagnostic(diagnostic))
    }

    private func beginWriteLocked(_ id: UUID) -> Bool {
        guard activeWriteID == nil, pendingWrites[id] != nil else { return false }
        activeWriteID = id
        return true
    }

    private func finishWriteLocked(_ pending: PendingWrite, error: Error?) {
        if activeWriteID == pending.id { activeWriteID = nil }
        guard pendingWrites.removeValue(forKey: pending.id) != nil else { return }
        if let error {
            pending.resume(throwing: error)
        } else if stopRequested || process == nil || !(process?.isRunning ?? false) {
            pending.resume(throwing: PiRPCError.stdinClosed)
        } else {
            pending.resume()
        }
    }

    @discardableResult
    private func cancelWriteLocked(_ id: UUID) -> Bool {
        guard let pending = pendingWrites.removeValue(forKey: id) else { return false }
        if activeWriteID == id {
            activeWriteID = nil
            abortForCancelledActiveWriteLocked()
        }
        pending.resume(throwing: CancellationError())
        return true
    }

    private func abortForCancelledActiveWriteLocked() {
        cancelAllPendingWritesLocked()
        stdinHandle?.closeFile()
        stdinHandle = nil
        stopRequested = true
        if !streamFinished {
            streamFinished = true
            continuation?.finish()
        }
        if let process, process.isRunning {
            process.terminate()
            scheduleStopGraceLocked(lifecycleID: lifecycleID)
        } else {
            cleanupLocked()
        }
    }

    private func cancelAllPendingWritesLocked() {
        let writes = pendingWrites.values
        pendingWrites.removeAll()
        activeWriteID = nil
        // Closing the shared pipe handle is the only reliable way to interrupt
        // FileHandle.write on a pipe after the child has stopped draining it.
        stdinHandle?.closeFile()
        for pending in writes {
            pending.resume(throwing: CancellationError())
        }
    }

    private func cleanupLocked(keepProcess: Bool = false) {
        cancelAllPendingWritesLocked()
        continuation = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        if !keepProcess {
            process = nil
        }
        resumeStopWaitersIfStoppedLocked()
    }

    private func resumeStopWaitersIfStoppedLocked() {
        guard process == nil, !stopWaiters.isEmpty else { return }
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func runtimeEnvironment(for executableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(environmentOverrides) { _, override in override }

        // WorkPi 可能由 Xcode、调试器或另一个 Agent 启动；这些父进程会注入
        // DYLD/LD/NODE_OPTIONS 等变量。它们会把调试器动态库带进 Node/Pi，
        // 造成“退出状态码 1”而没有可读的 RPC 错误。Runtime 是独立子进程，
        // 保留用户配置（包括 PI_CODING_AGENT_DIR）和认证所需变量，
        // 但不继承宿主的代码注入或父 Agent 会话元数据。
        environment = environment.filter { key, _ in
            let uppercased = key.uppercased()
            return !Self.blockedRuntimeEnvironmentKeys.contains(uppercased)
                && !uppercased.hasPrefix("DYLD_")
                && !uppercased.hasPrefix("__XPC_DYLD_")
                && !uppercased.hasPrefix("NPM_CONFIG_")
        }

        // GUI 从 Finder 启动时通常没有 Homebrew PATH；Pi 当前是 Node shebang，
        // 因此不仅要找到 pi，还要让 `/usr/bin/env node` 找到 node。
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolvedExecutableDirectory = executableURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .path
        let required = [
            executableURL.deletingLastPathComponent().path,
            resolvedExecutableDirectory,
            "\(home)/.pi/agent/bin",
            "\(home)/.local/bin",
            "\(home)/.local/share/pi-node/current/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.mise/shims",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ]
        var paths: [String] = []
        // 选定的 Node/Pi 目录必须优先于宿主 PATH；否则 Xcode、系统或旧版本
        // Node 可能被 `/usr/bin/env node` 误选。
        for path in required + existing where !path.isEmpty && !paths.contains(path) {
            paths.append(path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        if environment["HOME"]?.isEmpty != false {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return environment
    }
}
