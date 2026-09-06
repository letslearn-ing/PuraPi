import AppKit
import Combine
import Foundation

/// 账号认证的主线程状态协调器。
///
/// 认证协议、令牌刷新和 `auth.json` 写入全部由 Pi 官方 ModelRuntime 完成；
/// 这个对象只管理 UI 状态、用户交互回调和非敏感的模型目录。
@MainActor
final class WorkPiAuthCoordinator: ObservableObject {
    @Published private(set) var snapshot: WorkPiAuthSnapshot = .empty
    @Published private(set) var phase: WorkPiAuthPhase = .idle
    @Published private(set) var currentEvent: WorkPiAuthEvent?
    @Published private(set) var pendingPrompt: WorkPiAuthPrompt?
    @Published private(set) var operationMessage: String?
    @Published private(set) var refreshWarnings: [String] = []
    @Published private(set) var runtimeRestartRequired = false
    @Published private(set) var lastChangedProviderID: String?
    @Published var promptValidationMessage: String?

    private let selection: WorkPiRuntimeSelection
    private let locations: WorkPiRuntimeLocations
    private let homeDirectory: URL
    /// 生产环境不缓存完整环境字典，避免把 ambient API Key 长期留在 Swift 状态。
    private let environmentOverride: [String: String]?
    private let bridgeClient: any WorkPiAuthBridgeClient
    private let configurationOverride: WorkPiAuthBridgeConfiguration?
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var cancelledOperationID: UUID?
    /// 登录/退出/远程刷新中途取消时，sidecar 可能已经写入 auth.json；
    /// 在操作结束前保留这个标记，避免把不确定状态当成“没有变化”。
    private var activeCredentialMutation = false
    private var hasLoadedSnapshot = false
    private var lastAuthStorageRevision: String?

    /// 是否至少完成过一次认证状态读取。首次启动向导用它区分“尚未检查”
    /// 和“已经确认没有可用认证”，不能仅凭空的初始 snapshot 判断。
    var hasLoadedStatus: Bool { hasLoadedSnapshot }
    private var promptContinuation: CheckedContinuation<String, Error>?
    private var promptID: String?
    private var openedEventURLs = Set<String>()

    init(
        selection: WorkPiRuntimeSelection = WorkPiRuntimeSelection(),
        locations: WorkPiRuntimeLocations = WorkPiRuntimeLocations(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String]? = nil,
        bridgeClient: (any WorkPiAuthBridgeClient)? = nil,
        configurationOverride: WorkPiAuthBridgeConfiguration? = nil,
        refreshOnInit: Bool = false
    ) {
        self.selection = selection
        self.locations = locations
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.environmentOverride = environment
        self.bridgeClient = bridgeClient ?? WorkPiDefaultAuthBridgeClient()
        self.configurationOverride = configurationOverride
        if refreshOnInit {
            refreshStatus()
        }
    }

    deinit {
        operationTask?.cancel()
    }

    var isBusy: Bool { phase.isBusy }

    private var currentEnvironment: [String: String] {
        environmentOverride ?? ProcessInfo.processInfo.environment
    }

    var authStorageDisplayPath: String {
        guard let configured = currentEnvironment["PI_CODING_AGENT_DIR"],
              !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "~/.pi/agent/auth.json"
        }
        let expanded = (configured as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.path.hasPrefix("/") else { return "~/.pi/agent/auth.json" }
        return url.appendingPathComponent("auth.json").path
    }

    var featuredProviders: [WorkPiAuthProvider] {
        snapshot.providers
            .filter { $0.displayPriority < 10 }
            .sorted { lhs, rhs in
                if lhs.displayPriority != rhs.displayPriority {
                    return lhs.displayPriority < rhs.displayPriority
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var otherProviders: [WorkPiAuthProvider] {
        snapshot.providers
            .filter { $0.displayPriority >= 10 && !$0.authTypes.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// auth.json 中存在、但当前 SDK 没有可用认证入口的凭据。
    /// 仍允许用户通过官方 logout 删除，避免旧 Provider 凭据永久残留。
    var orphanedCredentials: [WorkPiStoredCredential] {
        snapshot.credentials
            .filter { credential in
                guard let provider = snapshot.provider(id: credential.providerId) else { return true }
                return provider.authTypes.isEmpty
            }
            .sorted { $0.providerId.localizedCaseInsensitiveCompare($1.providerId) == .orderedAscending }
    }

    /// 只读取本地认证状态和缓存模型，不主动联网。
    func refreshStatus() {
        start(
            phase: .checking,
            request: WorkPiAuthBridgeRequest.status(id: UUID().uuidString),
            changedProviderID: nil,
            changedAuthType: nil
        )
    }

    /// 使用 Pi 官方 `getAuth` 检查并按需刷新过期 OAuth；不返回令牌内容。
    func validateCredentials() {
        start(
            phase: .checking,
            request: WorkPiAuthBridgeRequest.validate(id: UUID().uuidString),
            changedProviderID: nil,
            changedAuthType: nil
        )
    }

    /// 显式刷新 Pi 的远程模型目录。登录本身不会在用户不知情时发起额外网络请求。
    func refreshAvailableModels() {
        start(
            phase: .refreshing,
            request: WorkPiAuthBridgeRequest.refresh(
                id: UUID().uuidString,
                allowNetwork: true,
                force: true
            ),
            changedProviderID: nil,
            changedAuthType: nil
        )
    }

    func login(providerID: String, type: WorkPiAuthType) {
        guard let provider = snapshot.provider(id: providerID),
              provider.authTypes.contains(where: { $0.type == type })
        else {
            phase = .failed("当前 Provider 不支持所选认证方式。")
            return
        }
        start(
            phase: .loggingIn(providerID: providerID, type: type),
            request: WorkPiAuthBridgeRequest.login(
                id: UUID().uuidString,
                provider: providerID,
                type: type
            ),
            changedProviderID: providerID,
            changedAuthType: type
        )
    }

    func logout(providerID: String) {
        let hasKnownStoredCredential = snapshot.provider(id: providerID)?.isConfigured == true
            || snapshot.credentials.contains { $0.providerId == providerID }
        guard hasKnownStoredCredential else {
            phase = .failed("该 Provider 没有由 Pi 保存的认证凭据。")
            return
        }
        start(
            phase: .loggingOut(providerID: providerID),
            request: WorkPiAuthBridgeRequest.logout(
                id: UUID().uuidString,
                provider: providerID
            ),
            changedProviderID: providerID,
            changedAuthType: nil
        )
    }

    func cancelOperation() {
        guard operationTask != nil else { return }
        cancelledOperationID = operationID
        currentEvent = nil
        openedEventURLs.removeAll()
        cancelPendingPrompt()
        operationTask?.cancel()
    }

    /// 由提示 sheet 提交输入。秘密输入不会写入 coordinator 的任何属性。
    /// `expectedPromptID` 防止旧 sheet 的关闭/提交动作影响后续 Prompt。
    func submitPrompt(_ value: String, for expectedPromptID: String? = nil) {
        guard let prompt = pendingPrompt,
              let continuation = promptContinuation,
              expectedPromptID == nil || prompt.id == expectedPromptID
        else { return }
        guard value.utf8.count <= 64 * 1024 else {
            promptValidationMessage = "输入内容超过安全限制。"
            return
        }
        if prompt.kind == .secret && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptValidationMessage = "API Key 不能为空。"
            return
        }
        promptValidationMessage = nil
        promptContinuation = nil
        promptID = nil
        pendingPrompt = nil
        continuation.resume(returning: value)
    }

    func cancelPendingPrompt(for expectedPromptID: String? = nil) {
        if let expectedPromptID,
           promptID != expectedPromptID {
            return
        }
        guard let continuation = promptContinuation else {
            pendingPrompt = nil
            promptID = nil
            promptValidationMessage = nil
            return
        }
        promptContinuation = nil
        promptID = nil
        pendingPrompt = nil
        promptValidationMessage = nil
        continuation.resume(throwing: WorkPiAuthError.cancelled)
    }

    func cancelPendingPrompt() {
        cancelPendingPrompt(for: nil)
    }

    func clearMessage() {
        operationMessage = nil
        refreshWarnings.removeAll()
        if case .failed = phase { phase = .idle }
    }

    /// 这是一个跨标签的提醒；用户确认已经自行重连后可以关闭提示。
    /// 当前项目 Runtime 的认证门控仍由各自的 session 状态独立维护。
    func acknowledgeRuntimeRestartRequirement() {
        runtimeRestartRequired = false
        lastChangedProviderID = nil
    }

    private func start(
        phase newPhase: WorkPiAuthPhase,
        request: WorkPiAuthBridgeRequest,
        changedProviderID: String?,
        changedAuthType: WorkPiAuthType?
    ) {
        guard operationTask == nil else { return }
        guard let configuration = makeConfiguration() else { return }

        let id = UUID()
        operationID = id
        cancelledOperationID = nil
        phase = newPhase
        currentEvent = nil
        operationMessage = nil
        refreshWarnings.removeAll()
        promptValidationMessage = nil
        openedEventURLs.removeAll()
        lastChangedProviderID = changedProviderID
        activeCredentialMutation = request.type == "login"
            || request.type == "logout"
            || request.type == "refresh"
            || request.type == "validate"

        let client = bridgeClient
        operationTask = Task { [weak self, client, configuration, request, id, changedProviderID, changedAuthType] in
            do {
                let result = try await client.perform(
                    configuration: configuration,
                    request: request,
                    onPrompt: { [weak self] prompt in
                        guard let self else { throw WorkPiAuthError.cancelled }
                        return try await self.waitForPrompt(prompt)
                    },
                    onEvent: { [weak self] event in
                        await self?.receive(event: event, operationID: id)
                    }
                )
                guard !Task.isCancelled else { throw WorkPiAuthError.cancelled }
                await MainActor.run {
                    self?.finish(
                        operationID: id,
                        result: result,
                        changedProviderID: changedProviderID,
                        changedAuthType: changedAuthType
                    )
                }
            } catch {
                await MainActor.run {
                    self?.fail(operationID: id, error: error)
                }
            }
        }
    }

    private func makeConfiguration() -> WorkPiAuthBridgeConfiguration? {
        if let configurationOverride { return configurationOverride }
        switch WorkPiAuthBridgeLocator.locate(
            selection: selection.snapshot(),
            locations: locations,
            homeDirectory: homeDirectory,
            environment: currentEnvironment
        ) {
        case .success(let configuration):
            return configuration
        case .failure(let error):
            let safeError = WorkPiSensitiveText.redacted(error.localizedDescription)
            phase = .failed(safeError)
            operationMessage = safeError
            return nil
        }
    }

    private func waitForPrompt(_ prompt: WorkPiAuthPrompt) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                if promptContinuation != nil {
                    // 先结束旧 continuation，避免第二个 Prompt 到达时把第一个
                    // 挂起在内存中；新请求也立即失败，交由 sidecar 重试/结束。
                    cancelPendingPrompt()
                    continuation.resume(throwing: WorkPiAuthError.invalidMessage("同时收到多个认证输入请求。"))
                    return
                }
                promptID = prompt.id
                pendingPrompt = prompt
                promptValidationMessage = nil
                promptContinuation = continuation
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingPrompt(for: prompt.id)
            }
        })
    }

    private func receive(event: WorkPiAuthEvent, operationID: UUID) {
        guard self.operationID == operationID,
              cancelledOperationID != operationID
        else { return }
        currentEvent = event
        let candidates = [event.url, event.verificationUri].compactMap { $0 }
        for url in candidates where shouldOpen(url) {
            guard openedEventURLs.insert(url.absoluteString).inserted else { continue }
            NSWorkspace.shared.open(url)
        }
    }

    private func shouldOpen(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host != nil
        else { return false }
        return true
    }

    private func finish(
        operationID: UUID,
        result: WorkPiAuthBridgeResult,
        changedProviderID: String?,
        changedAuthType: WorkPiAuthType?
    ) {
        guard self.operationID == operationID else { return }
        if cancelledOperationID == operationID {
            fail(operationID: operationID, error: WorkPiAuthError.cancelled)
            return
        }
        cancelledOperationID = nil
        let externalCredentialChanges = hasLoadedSnapshot
            ? changedCredentialProviderIDs(from: snapshot.credentials, to: result.snapshot.credentials)
            : []
        let authStorageRevisionChanged: Bool
        if hasLoadedSnapshot,
           let previousRevision = lastAuthStorageRevision,
           let currentRevision = result.authStorageRevision,
           previousRevision != currentRevision {
            authStorageRevisionChanged = true
        } else {
            authStorageRevisionChanged = false
        }
        let revisionAffectedProviderIDs: Set<String> = authStorageRevisionChanged
            ? Set(snapshot.credentials.map(\.providerId))
                .union(result.snapshot.credentials.map(\.providerId))
            : Set()
        lastAuthStorageRevision = result.authStorageRevision
        hasLoadedSnapshot = true
        snapshot = result.snapshot
        currentEvent = nil
        refreshWarnings = result.refreshWarnings.map { warning in
            let message = WorkPiSensitiveText.redacted(warning.message)
            return warning.providerId.isEmpty
                ? message
                : "\(warning.providerId)：\(message)"
        }
        if result.refreshAborted {
            refreshWarnings.append("模型目录刷新超时，当前仍使用已有缓存。")
        }
        operationTask = nil
        if promptContinuation != nil {
            cancelPendingPrompt()
        }
        pendingPrompt = nil
        promptContinuation = nil
        promptID = nil
        promptValidationMessage = nil
        phase = .idle
        activeCredentialMutation = false
        var changedProviderIDs = result.changedProviderIDs
        for providerID in externalCredentialChanges where !changedProviderIDs.contains(providerID) {
            changedProviderIDs.append(providerID)
        }
        for providerID in revisionAffectedProviderIDs.sorted()
            where !changedProviderIDs.contains(providerID) {
            changedProviderIDs.append(providerID)
        }
        if let changedProviderID, !changedProviderIDs.contains(changedProviderID) {
            changedProviderIDs.append(changedProviderID)
        }
        if !changedProviderIDs.isEmpty {
            lastChangedProviderID = changedProviderIDs.last
            publishAuthenticationChange(providerIDs: changedProviderIDs)
            if let changedProviderID {
                let providerName = result.snapshot.provider(id: changedProviderID)?.name ?? changedProviderID
                if let changedAuthType {
                    operationMessage = changedAuthType == .oauth
                        ? "已完成 \(providerName) 登录。正在运行的项目需要重新连接 Runtime 才会使用新凭据。"
                        : "已保存 \(providerName) 的 API Key。正在运行的项目需要重新连接 Runtime 才会使用新凭据。"
                } else {
                    operationMessage = "已退出 \(providerName)。正在运行的项目需要重新连接 Runtime。"
                }
            } else if (!externalCredentialChanges.isEmpty || authStorageRevisionChanged)
                        && result.changedProviderIDs.isEmpty {
                operationMessage = "检测到 Pi 认证存储已变化。正在运行的项目需要重新连接 Runtime。"
            } else {
                let names = changedProviderIDs.map { providerID in
                    result.snapshot.provider(id: providerID)?.name ?? providerID
                }
                operationMessage = "已刷新 \(names.joined(separator: "、")) 的官方认证。正在运行的项目需要重新连接 Runtime。"
            }
        } else if result.snapshot.models.isEmpty {
            operationMessage = "尚未发现已配置认证的可用模型。"
        } else {
            operationMessage = "认证状态已更新。"
        }
    }

    private func changedCredentialProviderIDs(
        from previous: [WorkPiStoredCredential],
        to current: [WorkPiStoredCredential]
    ) -> [String] {
        var previousByProvider: [String: WorkPiAuthType] = [:]
        for credential in previous {
            previousByProvider[credential.providerId] = credential.type
        }
        var currentByProvider: [String: WorkPiAuthType] = [:]
        for credential in current {
            currentByProvider[credential.providerId] = credential.type
        }
        return Set(previousByProvider.keys)
            .union(currentByProvider.keys)
            .filter { previousByProvider[$0] != currentByProvider[$0] }
            .sorted()
    }

    private func mayHaveCommittedCredential(after error: Error) -> Bool {
        guard activeCredentialMutation else { return false }
        guard let authError = error as? WorkPiAuthError else { return true }
        switch authError {
        case .unavailable:
            // Node 版本/权限等前置检查失败时，sidecar 尚未启动，不可能提交凭据。
            return false
        default:
            // sidecar 已启动或操作已进入协议层；结果丢失时仍须保守标记。
            return true
        }
    }

    private func publishAuthenticationChange(providerIDs: [String]) {
        runtimeRestartRequired = true
        var uniqueProviderIDs: [String] = []
        for providerID in providerIDs where !providerID.isEmpty {
            if !uniqueProviderIDs.contains(providerID) {
                uniqueProviderIDs.append(providerID)
            }
        }
        var userInfo: [AnyHashable: Any] = ["providerIDs": uniqueProviderIDs]
        if uniqueProviderIDs.count == 1, let providerID = uniqueProviderIDs.first {
            userInfo["providerID"] = providerID
        }
        NotificationCenter.default.post(
            name: .workPiAuthenticationChanged,
            object: nil,
            userInfo: userInfo
        )
    }

    private func fail(operationID: UUID, error: Error) {
        guard self.operationID == operationID else { return }
        cancelledOperationID = nil
        operationTask = nil
        currentEvent = nil
        openedEventURLs.removeAll()
        if promptContinuation != nil {
            cancelPendingPrompt()
        }
        pendingPrompt = nil
        promptContinuation = nil
        promptID = nil
        promptValidationMessage = nil
        let mutationWasActive = mayHaveCommittedCredential(after: error)
        if error is CancellationError || (error as? WorkPiAuthError) == .cancelled {
            phase = .idle
            operationMessage = mutationWasActive
                ? "认证操作已取消；凭据状态可能已经改变，请刷新状态确认。"
                : "认证操作已取消。"
            if mutationWasActive {
                publishAuthenticationChange(
                    providerIDs: lastChangedProviderID.map { [$0] } ?? []
                )
            }
            activeCredentialMutation = false
        } else {
            let message = WorkPiSensitiveText.redacted(error.localizedDescription)
            var didPublishMutation = false
            phase = .failed(message)
            operationMessage = message
            if let authError = error as? WorkPiAuthError,
               case .requestFailed(_, let credentialMayHaveBeenSaved, let committedProviderIDs) = authError,
               credentialMayHaveBeenSaved {
                // 凭据可能已经写入但本地同步失败；即使没有明确 Provider ID，
                // 也必须通知所有活动 Runtime 停止发送，避免继续使用旧状态。
                var providerIDs = committedProviderIDs
                if let providerID = lastChangedProviderID,
                   !providerIDs.contains(providerID) {
                    providerIDs.append(providerID)
                }
                lastChangedProviderID = providerIDs.last ?? lastChangedProviderID
                publishAuthenticationChange(providerIDs: providerIDs)
                didPublishMutation = true
            }
            if mutationWasActive && !didPublishMutation {
                operationMessage = "\(message) 凭据状态可能已经改变，请刷新认证状态确认。"
                publishAuthenticationChange(
                    providerIDs: lastChangedProviderID.map { [$0] } ?? []
                )
            }
            activeCredentialMutation = false
        }
    }
}
