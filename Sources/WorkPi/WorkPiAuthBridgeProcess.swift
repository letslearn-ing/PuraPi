import Darwin
import Foundation

/// 认证桥接客户端的可替换边界。测试使用 Fake 实现，生产实现只启动受控 Node sidecar。
protocol WorkPiAuthBridgeClient: Sendable {
    func perform(
        configuration: WorkPiAuthBridgeConfiguration,
        request: WorkPiAuthBridgeRequest,
        onPrompt: @escaping @Sendable (WorkPiAuthPrompt) async throws -> String,
        onEvent: @escaping @Sendable (WorkPiAuthEvent) async -> Void
    ) async throws -> WorkPiAuthBridgeResult
}

enum WorkPiAuthBridgeNodeValidator {
    static func validatedConfiguration(
        _ configuration: WorkPiAuthBridgeConfiguration,
        runner: any WorkPiProcessRunner = WorkPiDefaultProcessRunner()
    ) async throws -> WorkPiAuthBridgeConfiguration {
        var foundVersion: WorkPiRuntimeVersion?
        for candidate in configuration.nodeCandidates {
            guard WorkPiAuthFileSystem.isRegularFile(at: candidate),
                  FileManager.default.isExecutableFile(atPath: candidate.path)
            else { continue }
            var probeEnvironment: [String: String] = [:]
            if let path = configuration.environment["PATH"] {
                probeEnvironment["PATH"] = path
            }
            if let home = configuration.environment["HOME"] {
                probeEnvironment["HOME"] = home
            }
            probeEnvironment["PI_OFFLINE"] = "1"
            probeEnvironment["PI_SKIP_VERSION_CHECK"] = "1"
            probeEnvironment["PI_TELEMETRY"] = "0"
            do {
                let result = try await runner.run(WorkPiProcessRequest(
                    executableURL: candidate,
                    arguments: ["--version"],
                    environment: probeEnvironment,
                    currentDirectoryURL: configuration.currentDirectoryURL,
                    timeout: 8,
                    outputLimit: 8 * 1024
                ))
                guard result.succeeded,
                      let version = WorkPiRuntimeVersion(result.stdoutText)
                else { continue }
                if let currentVersion = foundVersion {
                    foundVersion = max(currentVersion, version)
                } else {
                    foundVersion = version
                }
                guard version >= WorkPiRuntimePolicy.minimumNodeVersion else { continue }
                var childEnvironment = configuration.environment
                childEnvironment["PATH"] = pathValue(
                    prepending: [candidate.deletingLastPathComponent().path],
                    to: childEnvironment["PATH"] ?? ""
                )
                return WorkPiAuthBridgeConfiguration(
                    nodeURL: candidate.standardizedFileURL,
                    nodeCandidates: configuration.nodeCandidates,
                    entryURL: configuration.entryURL,
                    authPath: configuration.authPath,
                    modelsPath: configuration.modelsPath,
                    agentDirectoryURL: configuration.agentDirectoryURL,
                    currentDirectoryURL: configuration.currentDirectoryURL,
                    environment: childEnvironment
                )
            } catch is CancellationError {
                throw WorkPiAuthError.cancelled
            } catch let error as WorkPiProcessError {
                if case .cancelled = error {
                    throw WorkPiAuthError.cancelled
                }
                continue
            } catch {
                continue
            }
        }
        if let foundVersion {
            throw WorkPiAuthError.unavailable(
                "认证需要 Node.js \(WorkPiRuntimePolicy.minimumNodeVersion) 或更高版本，当前为 \(foundVersion)。"
            )
        }
        throw WorkPiAuthError.unavailable("无法读取认证所需的 Node.js 版本。")
    }

    private static func pathValue(prepending prefixes: [String], to existing: String) -> String {
        var values: [String] = []
        for value in prefixes + existing.split(separator: ":").map(String.init)
        where !value.isEmpty && !values.contains(value) {
            values.append(value)
        }
        return values.joined(separator: ":")
    }
}

struct WorkPiDefaultAuthBridgeClient: WorkPiAuthBridgeClient {
    func perform(
        configuration: WorkPiAuthBridgeConfiguration,
        request: WorkPiAuthBridgeRequest,
        onPrompt: @escaping @Sendable (WorkPiAuthPrompt) async throws -> String,
        onEvent: @escaping @Sendable (WorkPiAuthEvent) async -> Void
    ) async throws -> WorkPiAuthBridgeResult {
        let timeout: Duration?
        switch request.type {
        case "login": timeout = .seconds(15 * 60)
        case "refresh": timeout = .seconds(120)
        case "validate": timeout = .seconds(60)
        default: timeout = .seconds(30)
        }

        guard let timeout else {
            return try await performWithoutTimeout(
                configuration: configuration,
                request: request,
                onPrompt: onPrompt,
                onEvent: onEvent
            )
        }

        return try await withThrowingTaskGroup(of: WorkPiAuthBridgeResult.self) { group in
            group.addTask {
                try await self.performWithoutTimeout(
                    configuration: configuration,
                    request: request,
                    onPrompt: onPrompt,
                    onEvent: onEvent
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WorkPiAuthError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WorkPiAuthError.timedOut
            }
            return result
        }
    }

    private func performWithoutTimeout(
        configuration: WorkPiAuthBridgeConfiguration,
        request: WorkPiAuthBridgeRequest,
        onPrompt: @escaping @Sendable (WorkPiAuthPrompt) async throws -> String,
        onEvent: @escaping @Sendable (WorkPiAuthEvent) async -> Void
    ) async throws -> WorkPiAuthBridgeResult {
        // 在启动任何用户提供的 Node 之前先保护 auth.json；版本探测本身也不应
        // 在发现权限问题前接触凭据文件。
        try WorkPiAuthStorageSecurity.ensureUserOnlyPermissions(at: configuration.authPath)
        let validatedConfiguration = try await WorkPiAuthBridgeNodeValidator.validatedConfiguration(configuration)
        let process = WorkPiAuthBridgeProcess(
            configuration: validatedConfiguration,
            readOnlyAuth: request.type == "status" || request.type == "models"
        )
        return try await withTaskCancellationHandler(operation: {
            do {
                let messages = try process.start()
                try await process.send(request)
                for try await message in messages {
                    switch message.type {
                    case "ready":
                        guard message.protocolVersion == 1 else {
                            throw WorkPiAuthError.invalidMessage("认证桥接协议版本不受支持。")
                        }
                        continue

                    case "auth_event":
                        guard message.operationId == request.id,
                              let payload = message.event,
                              let event = payload.materialize()
                        else {
                            throw WorkPiAuthError.invalidMessage("认证事件字段无效。")
                        }
                        await onEvent(event)

                    case "prompt":
                        guard message.operationId == request.id,
                              let prompt = message.prompt,
                              prompt.isWithinSafetyBounds else {
                            throw WorkPiAuthError.invalidMessage("认证输入请求缺少或超出限制。")
                        }
                        let value = try await onPrompt(prompt)
                        try await process.send(WorkPiAuthBridgePromptResponse(
                            id: prompt.id,
                            value: value
                        ))

                    case "result":
                        guard message.id == request.id,
                              let result = message.operationResult() else {
                            throw WorkPiAuthError.invalidMessage("认证结果缺少完整状态快照。")
                        }
                        await process.stop()
                        return result

                    case "error":
                        guard message.id == request.id else {
                            throw WorkPiAuthError.invalidMessage("认证错误的 request id 不匹配。")
                        }
                        let errorMessage = WorkPiSensitiveText.redacted(
                            message.message ?? "认证操作失败。"
                        )
                        let credentialCommitted = message.credentialCommitted ?? false
                        let changedProviderIDs = message.changedProviderIds ?? []
                        await process.stop()
                        if message.cancelled == true && !credentialCommitted {
                            throw WorkPiAuthError.cancelled
                        }
                        if errorMessage == "Login cancelled" || errorMessage == "认证操作已取消。"
                            || errorMessage == "认证桥接输入已关闭。" {
                            if !credentialCommitted {
                                throw WorkPiAuthError.cancelled
                            }
                        }
                        throw WorkPiAuthError.requestFailed(
                            errorMessage,
                            credentialMayHaveBeenSaved: credentialCommitted,
                            changedProviderIDs: changedProviderIDs
                        )

                    case "fatal_error", "protocol_error":
                        await process.stop()
                        throw WorkPiAuthError.requestFailed(
                            WorkPiSensitiveText.redacted(
                                message.message ?? "认证桥接初始化失败。"
                            ),
                            credentialMayHaveBeenSaved: false
                        )

                    default:
                        throw WorkPiAuthError.invalidMessage(
                            "未知消息类型：\(WorkPiSensitiveText.redacted(message.type, limit: 80))"
                        )
                    }
                }
                let diagnostic = await process.diagnostic()
                throw WorkPiAuthError.launchFailed(
                    diagnostic.isEmpty ? "认证桥接提前退出。" : diagnostic
                )
            } catch is CancellationError {
                await process.stop()
                throw WorkPiAuthError.cancelled
            } catch let error as WorkPiAuthError {
                await process.stop()
                throw error
            } catch {
                await process.stop()
                if Task.isCancelled { throw WorkPiAuthError.cancelled }
                throw WorkPiAuthError.launchFailed(
                    WorkPiSensitiveText.redacted(error.localizedDescription)
                )
            }
        }, onCancel: {
            process.cancel()
        })
    }
}

private final class WorkPiAuthPendingWrite: @unchecked Sendable {
    let id: UUID
    let data: Data
    let handle: FileHandle
    var continuation: CheckedContinuation<Void, Error>?
    private var resumed = false

    init(id: UUID, data: Data, handle: FileHandle) {
        self.id = id
        self.data = data
        self.handle = handle
    }

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
}

/// 受控 Node sidecar 的进程和 JSONL 事件流。
///
/// stdout 只允许协议消息；stderr 只读取并丢弃，绝不把 provider 错误文本返回给 UI。
/// 该对象不把任何凭据存入 Swift 状态。
final class WorkPiAuthBridgeProcess: @unchecked Sendable {
    private static let maximumRecordBytes = 1024 * 1024

    private let configuration: WorkPiAuthBridgeConfiguration
    private let readOnlyAuth: Bool
    private let stateQueue = DispatchQueue(label: "WorkPi.AuthBridgeProcess.state")
    private let writeQueue = DispatchQueue(label: "WorkPi.AuthBridgeProcess.write")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var continuation: AsyncThrowingStream<WorkPiAuthBridgeMessage, Error>.Continuation?
    private var stdoutBuffer = Data()
    private var streamFinished = false
    private var stdoutEnded = false
    private var stopRequested = false
    /// 与 stopRequested 区分：取消可能在 launchLocked 前到达，不能被启动流程清除。
    private var cancellationRequested = false
    private var processExitStatus: Int32?
    private var temporaryModelsStoreDirectory: URL?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWrites: [UUID: WorkPiAuthPendingWrite] = [:]
    private var activeWriteID: UUID?
    private var cancelledWriteIDs: Set<UUID> = []
    private var lifecycleID = UUID()

    init(configuration: WorkPiAuthBridgeConfiguration, readOnlyAuth: Bool = false) {
        self.configuration = configuration
        self.readOnlyAuth = readOnlyAuth
        WorkPiAuthBridgeProcessRegistry.shared.insert(self)
    }

    deinit {
        WorkPiAuthBridgeProcessRegistry.shared.remove(self)
    }

    /// 应用退出时使用；不等待异步 Task，直接杀掉当前 sidecar 并清理管道。
    static func terminateAllImmediately() {
        WorkPiAuthBridgeProcessRegistry.shared.terminateAll()
    }

    func start() throws -> AsyncThrowingStream<WorkPiAuthBridgeMessage, Error> {
        let stream = AsyncThrowingStream<WorkPiAuthBridgeMessage, Error> { continuation in
            self.stateQueue.sync {
                self.continuation = continuation
            }
        }

        var launchError: Error?
        stateQueue.sync {
            do {
                guard !cancellationRequested else {
                    throw WorkPiAuthError.cancelled
                }
                try launchLocked()
            } catch {
                launchError = error
            }
        }
        if let launchError { throw launchError }
        return stream
    }

    func send<T: Encodable & Sendable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value) + Data([0x0A])
        let writeID = UUID()
        let bridge = self
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateQueue.async {
                    if self.cancelledWriteIDs.remove(writeID) != nil {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let process = self.process, process.isRunning,
                          let stdin = self.stdin
                    else {
                        continuation.resume(throwing: WorkPiAuthError.launchFailed("sidecar 未运行。"))
                        return
                    }
                    // The potentially blocking write is isolated from stateQueue.
                    // stop() closes this handle and completes the pending operation.
                    let pending = WorkPiAuthPendingWrite(
                        id: writeID,
                        data: data,
                        handle: stdin
                    )
                    pending.continuation = continuation
                    self.pendingWrites[writeID] = pending
                    self.writeQueue.async { [weak self, pending] in
                        guard let self,
                              self.stateQueue.sync(execute: {
                                  self.beginWriteLocked(pending.id)
                              })
                        else { return }
                        do {
                            try pending.handle.write(contentsOf: pending.data)
                            self.stateQueue.sync {
                                self.finishWriteLocked(pending, error: nil)
                            }
                        } catch {
                            self.stateQueue.sync {
                                if let process = self.process, process.isRunning {
                                    process.terminate()
                                }
                                self.finishWriteLocked(
                                    pending,
                                    error: WorkPiAuthError.launchFailed(
                                        "无法向认证 sidecar 写入请求。"
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }, onCancel: {
            bridge.stateQueue.async {
                if !bridge.cancelWriteLocked(writeID) {
                    bridge.cancelledWriteIDs.insert(writeID)
                    if bridge.cancelledWriteIDs.count > 1_024,
                       let oldest = bridge.cancelledWriteIDs.first {
                        bridge.cancelledWriteIDs.remove(oldest)
                    }
                }
            }
        })
    }

    func cancel() {
        stateQueue.async {
            self.cancellationRequested = true
            self.stopLocked()
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                self.stopWaiters.append(continuation)
                self.stopLocked()
                self.resumeStopWaitersIfStoppedLocked()
            }
        }
    }

    func diagnostic() async -> String {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                guard let status = self.processExitStatus else {
                    continuation.resume(returning: "认证 sidecar 未返回有效协议消息。")
                    return
                }
                // stderr 可能包含 Provider 返回的令牌或 HTTP 响应体；只返回固定文本，
                // 不把原始诊断暴露给用户界面。
                continuation.resume(returning: "认证 sidecar 未返回有效协议消息（退出状态：\(status)）。")
            }
        }
    }

    private func launchLocked() throws {
        guard WorkPiAuthFileSystem.isRegularFile(at: configuration.nodeURL),
              FileManager.default.isExecutableFile(atPath: configuration.nodeURL.path)
        else {
            throw WorkPiAuthError.launchFailed("找不到 Node.js：\(configuration.nodeURL.path)")
        }
        guard WorkPiAuthFileSystem.isRegularFile(at: configuration.entryURL),
              FileManager.default.isReadableFile(atPath: configuration.entryURL.path)
        else {
            throw WorkPiAuthError.launchFailed("找不到 Pi 官方 SDK：\(configuration.entryURL.path)")
        }
        guard let bridgeURL = WorkPiAuthBridgeResources.scriptURL,
              FileManager.default.isReadableFile(atPath: bridgeURL.path) else {
            throw WorkPiAuthError.launchFailed("认证桥接脚本不可读。")
        }

        lifecycleID = UUID()
        let currentLifecycleID = lifecycleID
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPiAuth-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw WorkPiAuthError.launchFailed("无法创建认证缓存目录。")
        }
        temporaryModelsStoreDirectory = cacheDirectory

        process.executableURL = configuration.nodeURL
        process.arguments = [
            bridgeURL.path,
            "--entry", configuration.entryURL.path,
            "--auth-path", configuration.authPath.path,
            "--models-path", configuration.modelsPath.path,
            "--models-store-path", cacheDirectory.appendingPathComponent("models-store.json").path,
        ]
        if readOnlyAuth {
            process.arguments?.append("--read-only-auth")
        }
        var processEnvironment = configuration.environment
        if readOnlyAuth {
            // status/models 是严格离线读取；即使未来 Provider 在 getAvailable
            // 内部新增网络行为，也不能越过这个 sidecar 语义。
            processEnvironment["PI_OFFLINE"] = "1"
        }
        process.environment = processEnvironment
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.stateQueue.async {
                guard self.lifecycleID == currentLifecycleID else { return }
                self.processExitStatus = terminated.terminationStatus
                self.processDidExitLocked()
            }
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: cacheDirectory)
            temporaryModelsStoreDirectory = nil
            throw WorkPiAuthError.launchFailed(
                WorkPiSensitiveText.redacted(error.localizedDescription)
            )
        }

        self.process = process
        let stdinHandle = inputPipe.fileHandleForWriting
        let stdoutHandle = outputPipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading
        stdin = stdinHandle
        stdout = stdoutHandle
        stderr = stderrHandle
        streamFinished = false
        stdoutEnded = false
        stopRequested = false
        activeWriteID = nil
        processExitStatus = nil
        stdoutBuffer.removeAll(keepingCapacity: true)

        installReadSource(
            handle: stdoutHandle,
            isStdout: true,
            lifecycleID: currentLifecycleID
        )
        installReadSource(
            handle: stderrHandle,
            isStdout: false,
            lifecycleID: currentLifecycleID
        )
    }

    /// 使用非阻塞 DispatchSource 读取管道，避免为每个 sidecar 长时间占用阻塞线程。
    /// 这也保证连续登录/刷新操作不会因旧 reader 未退出而耗尽线程池。
    private func installReadSource(
        handle: FileHandle,
        isStdout: Bool,
        lifecycleID: UUID
    ) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: stateQueue
        )
        source.setEventHandler { [weak self] in
            guard let self,
                  self.lifecycleID == lifecycleID,
                  !self.streamFinished
            else {
                if isStdout { self?.stdoutSource?.cancel() } else { self?.stderrSource?.cancel() }
                return
            }

            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                if isStdout {
                    self.consumeStdoutLocked(Data(bytes.prefix(count)))
                }
                // stderr 只为避免子进程阻塞而排空，不保存在 Swift 内存中。
            } else if count == 0 {
                if isStdout {
                    self.stdoutSource?.cancel()
                    self.stdoutDidEndLocked()
                } else {
                    self.stderrSource?.cancel()
                }
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                if isStdout {
                    self.stdoutSource?.cancel()
                    self.failLocked(WorkPiAuthError.invalidMessage("无法读取认证 sidecar 输出。"))
                } else {
                    self.stderrSource?.cancel()
                }
            }
        }
        source.setCancelHandler {
            handle.closeFile()
        }
        if isStdout {
            stdoutSource = source
        } else {
            stderrSource = source
        }
        source.resume()
    }

    private func consumeStdoutLocked(_ data: Data) {
        guard !streamFinished else { return }
        stdoutBuffer.append(data)
        guard stdoutBuffer.count <= Self.maximumRecordBytes || stdoutBuffer.contains(0x0A) else {
            failLocked(WorkPiAuthError.invalidMessage("认证消息超过大小限制。"))
            return
        }

        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: 0..<newline)
            stdoutBuffer.removeSubrange(0...newline)
            guard line.count <= Self.maximumRecordBytes else {
                failLocked(WorkPiAuthError.invalidMessage("认证消息超过大小限制。"))
                return
            }
            var payload = line
            if payload.last == 0x0D { payload.removeLast() }
            guard !payload.isEmpty else { continue }
            do {
                let message = try JSONDecoder().decode(
                    WorkPiAuthBridgeMessage.self,
                    from: payload
                )
                continuation?.yield(message)
            } catch {
                failLocked(WorkPiAuthError.invalidMessage(
                    "无法解析认证 JSONL：\(String(describing: error).prefix(240))"
                ))
                return
            }
        }
        if stdoutBuffer.count > Self.maximumRecordBytes {
            failLocked(WorkPiAuthError.invalidMessage("认证消息超过大小限制。"))
        }
    }

    private func stdoutDidEndLocked() {
        guard !streamFinished, !stdoutEnded else { return }
        stdoutEnded = true
        if !stdoutBuffer.isEmpty {
            failLocked(WorkPiAuthError.invalidMessage("认证 sidecar 输出没有完整换行记录。"))
            return
        }
        finishStreamLocked()
    }

    private func processDidExitLocked() {
        cancelAllPendingWritesLocked()
        stdin?.closeFile()
        stdin = nil
        if stopRequested {
            finishStreamLocked()
            cleanupLocked()
            return
        }
        if streamFinished {
            // stdout 可能先收到 EOF；此时不会再有结果，退出处理仍必须清理
            // 临时 models-store 目录和文件描述符。
            cleanupLocked()
            return
        }
        // 结果通常先于进程退出；给 stdout 一个短暂排空窗口。
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, !self.streamFinished else { return }
            self.finishStreamLocked()
            self.cleanupLocked()
        }
    }

    private func failLocked(_ error: Error) {
        guard !streamFinished else { return }
        streamFinished = true
        continuation?.finish(throwing: error)
        stopRequested = true
        cancelAllPendingWritesLocked()
        stdin = nil
        if let process, process.isRunning {
            process.terminate()
        } else {
            cleanupLocked()
        }
    }

    private func finishStreamLocked() {
        guard !streamFinished else { return }
        streamFinished = true
        continuation?.finish()
    }

    private func stopLocked() {
        guard let process else {
            finishStreamLocked()
            cleanupLocked()
            return
        }
        if stopRequested {
            // failLocked() may have already sent SIGTERM.  A later stop() must
            // still install the escalation/exit barrier instead of returning
            // with an unresolvable waiter.
            scheduleStopEscalationLocked(lifecycleID: lifecycleID, attempt: 1)
            return
        }
        stopRequested = true
        cancelAllPendingWritesLocked()
        try? stdin?.close()
        stdin = nil
        stdoutSource?.cancel()
        stderrSource?.cancel()
        finishStreamLocked()
        if process.isRunning {
            process.terminate()
        }
        // Do not clean up merely because a grace timer elapsed.  The
        // terminationHandler is the only authoritative process-exit signal.
        scheduleStopEscalationLocked(lifecycleID: lifecycleID, attempt: 1)
    }

    private func scheduleStopEscalationLocked(lifecycleID: UUID, attempt: Int) {
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
            guard let self, self.lifecycleID == lifecycleID, self.stopRequested,
                  let process = self.process
            else { return }
            guard process.isRunning else {
                // Process may report not-running just before its termination
                // callback; keep the object until that callback arrives.
                self.scheduleStopEscalationLocked(lifecycleID: lifecycleID, attempt: attempt + 1)
                return
            }
            if attempt == 1 {
                process.interrupt()
            } else {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            self.scheduleStopEscalationLocked(lifecycleID: lifecycleID, attempt: attempt + 1)
        }
    }

    func terminateImmediately() {
        stateQueue.sync {
            cancellationRequested = true
            stopRequested = true
            try? stdin?.close()
            stdin = nil
            stdoutSource?.cancel()
            stderrSource?.cancel()
            finishStreamLocked()
            if let process, process.isRunning {
                // 先给 Node 一个很短的 SIGTERM 窗口，让官方 AuthStorage 释放锁；
                // 应用退出不能无限等待，超时后再强制结束。
                process.terminate()
                let deadline = Date().addingTimeInterval(0.2)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
            cleanupLocked()
        }
    }

    private func beginWriteLocked(_ id: UUID) -> Bool {
        guard activeWriteID == nil, pendingWrites[id] != nil else { return false }
        activeWriteID = id
        return true
    }

    private func finishWriteLocked(_ pending: WorkPiAuthPendingWrite, error: Error?) {
        if activeWriteID == pending.id { activeWriteID = nil }
        guard pendingWrites.removeValue(forKey: pending.id) != nil else { return }
        if let error {
            pending.resume(throwing: error)
        } else if stopRequested || process == nil || !(process?.isRunning ?? false) {
            pending.resume(throwing: WorkPiAuthError.cancelled)
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
        pending.resume(throwing: WorkPiAuthError.cancelled)
        return true
    }

    private func abortForCancelledActiveWriteLocked() {
        cancelAllPendingWritesLocked()
        stopRequested = true
        finishStreamLocked()
        if let process, process.isRunning {
            process.terminate()
            scheduleStopEscalationLocked(lifecycleID: lifecycleID, attempt: 1)
        } else {
            cleanupLocked()
        }
    }

    private func cancelAllPendingWritesLocked() {
        let writes = pendingWrites.values
        pendingWrites.removeAll()
        activeWriteID = nil
        stdin?.closeFile()
        for pending in writes {
            pending.resume(throwing: WorkPiAuthError.cancelled)
        }
    }

    private func cleanupLocked() {
        cancelAllPendingWritesLocked()
        WorkPiAuthBridgeProcessRegistry.shared.remove(self)
        stdoutSource?.cancel()
        stderrSource?.cancel()
        stdoutSource = nil
        stderrSource = nil
        if let temporaryModelsStoreDirectory {
            try? FileManager.default.removeItem(at: temporaryModelsStoreDirectory)
            self.temporaryModelsStoreDirectory = nil
        }
        try? stdout?.close()
        try? stderr?.close()
        stdout = nil
        stderr = nil
        stdin = nil
        process = nil
        resumeStopWaitersIfStoppedLocked()
    }

    private func resumeStopWaitersIfStoppedLocked() {
        guard process == nil else { return }
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// 认证 sidecar 的进程登记表。应用退出时需要同步终止所有仍存活的实例，
/// 不能只依赖即将被系统取消的 Swift Task。
private final class WorkPiAuthBridgeProcessRegistry: @unchecked Sendable {
    static let shared = WorkPiAuthBridgeProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: WorkPiAuthBridgeProcess] = [:]

    func insert(_ process: WorkPiAuthBridgeProcess) {
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    func remove(_ process: WorkPiAuthBridgeProcess) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let active = Array(processes.values)
        lock.unlock()
        for process in active {
            process.terminateImmediately()
        }
    }
}
