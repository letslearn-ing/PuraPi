import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiAuthTests: XCTestCase {
    func testCoordinatorReadsNonSensitiveProviderSnapshot() async throws {
        let fake = FakeAuthBridgeClient()
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )

        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }

        XCTAssertEqual(fake.lastRequestType, "status")
        XCTAssertEqual(coordinator.snapshot.providers.first?.id, "anthropic")
        XCTAssertEqual(coordinator.snapshot.models.first?.selectionKey, "anthropic/claude-test")

        coordinator.validateCredentials()
        await waitUntil { coordinator.phase == .idle }
        XCTAssertEqual(fake.lastRequestType, "validate")
    }

    func testAPIKeyPromptDoesNotPersistSecretInCoordinatorState() async throws {
        let fake = FakeAuthBridgeClient()
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }

        coordinator.login(providerID: "anthropic", type: .apiKey)
        await waitUntil { coordinator.pendingPrompt != nil }
        XCTAssertEqual(coordinator.pendingPrompt?.kind, .secret)
        XCTAssertNil(coordinator.operationMessage)

        coordinator.submitPrompt("sk-test-only-value")
        await waitUntil { coordinator.phase == .idle && coordinator.pendingPrompt == nil }

        XCTAssertEqual(fake.receivedSecret, "sk-test-only-value")
        XCTAssertEqual(coordinator.snapshot.provider(id: "anthropic")?.configuredType, .apiKey)
        // 认证秘密只能经过回调传递，不能进入公开的 coordinator 状态快照。
        XCTAssertFalse(String(describing: coordinator.snapshot).contains("sk-test-only-value"))
        XCTAssertTrue(coordinator.runtimeRestartRequired)

        coordinator.logout(providerID: "anthropic")
        await waitUntil { coordinator.phase == .idle && coordinator.pendingPrompt == nil }
        XCTAssertFalse(coordinator.snapshot.provider(id: "anthropic")?.isConfigured == true)
    }

    func testEmptyAPIKeyStaysInPromptAndShowsValidation() async throws {
        let fake = FakeAuthBridgeClient()
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }

        coordinator.login(providerID: "anthropic", type: .apiKey)
        await waitUntil { coordinator.pendingPrompt != nil }
        coordinator.submitPrompt("   ")

        XCTAssertNotNil(coordinator.pendingPrompt)
        XCTAssertEqual(coordinator.promptValidationMessage, "API Key 不能为空。")
        XCTAssertNil(fake.receivedSecret)
        coordinator.cancelOperation()
        await waitUntil { coordinator.phase == .idle && coordinator.pendingPrompt == nil }
    }

    func testOAuthEventIsRetainedWithoutOpeningNonHTTPSURL() async throws {
        let fake = FakeAuthBridgeClient(sendEvent: true)
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }

        coordinator.login(providerID: "anthropic", type: .oauth)
        await waitUntil { coordinator.pendingPrompt != nil }
        XCTAssertEqual(coordinator.currentEvent?.type, "auth_url")
        XCTAssertEqual(coordinator.currentEvent?.url?.host, "localhost")

        coordinator.cancelOperation()
        await waitUntil { coordinator.phase == .idle && coordinator.pendingPrompt == nil }
    }

    func testLocatorFindsOfficialSDKForInstalledPiWhenAvailable() throws {
        let resolver = PiExecutableResolver()
        guard let piURL = resolver.resolve() else {
            throw XCTSkip("当前机器没有可发现的 Pi")
        }
        let result = WorkPiAuthBridgeLocator.locate()
        guard case .success(let configuration) = result else {
            XCTFail("无法从已发现的 Pi 定位官方 SDK：\(result)")
            return
        }
        XCTAssertTrue(configuration.entryURL.path.hasSuffix("dist/index.js"))
        XCTAssertTrue(configuration.authPath.path.hasSuffix(".pi/agent/auth.json"))
        XCTAssertNil(configuration.environment["NODE_OPTIONS"])
        XCTAssertNotEqual(configuration.nodeURL.path, piURL.path)
    }

    func testPromptIsRetainedUntilRuntimeReconnectedAfterAuthChange() {
        let session = PiSessionController()
        session.draftPrompt = "保留这条输入"
        session.runtimeAuthenticationChanged = true

        session.submitPrompt()

        XCTAssertEqual(session.draftPrompt, "保留这条输入")
        XCTAssertTrue(session.lastError?.contains("重新连接 Runtime") == true)
        XCTAssertTrue(session.canSubmitWhileAuthenticationChanged("/abort"))
        XCTAssertTrue(session.canSubmitWhileAuthenticationChanged("!git status"))
        XCTAssertFalse(session.canSubmitWhileAuthenticationChanged("普通问题"))
        XCTAssertFalse(session.canSubmitWhileAuthenticationChanged("/compact"))
    }

    func testLocatorHonorsConfiguredAgentDirectoryWithoutPassingNodeInjection() throws {
        guard PiExecutableResolver().resolve() != nil else {
            throw XCTSkip("当前机器没有可发现的 Pi")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = "/tmp/workpi-auth-agent"
        environment["NODE_OPTIONS"] = "--require=/tmp/untrusted.js"
        environment["NPM_CONFIG_USERCONFIG"] = "/tmp/untrusted-npmrc"
        environment["OPENAI_API_KEY"] = "test-key-placeholder"
        let result = WorkPiAuthBridgeLocator.locate(environment: environment)
        guard case .success(let configuration) = result else {
            XCTFail("无法定位认证桥接配置：\(result)")
            return
        }
        XCTAssertEqual(configuration.authPath.path, "/tmp/workpi-auth-agent/auth.json")
        XCTAssertNil(configuration.environment["NODE_OPTIONS"])
        XCTAssertNil(configuration.environment["NPM_CONFIG_USERCONFIG"])
        XCTAssertEqual(configuration.environment["PI_OAUTH_CALLBACK_HOST"], "127.0.0.1")
        XCTAssertEqual(configuration.environment["OPENAI_API_KEY"], "test-key-placeholder")
    }

    func testAuthenticationFailureProvidesRecoveryNotice() {
        let session = PiSessionController()
        session.runtimeMetadata.modelProvider = "anthropic"
        session.noteAuthenticationFailure("HTTP 401: invalid api key")

        XCTAssertTrue(session.runtimeNotice?.contains("设置 → 账号") == true)
        XCTAssertTrue(session.runtimeNotice?.contains("anthropic") == true)
    }

    func testRuntimeErrorSanitizerHidesStructuredAndBearerCredentials() {
        let message = "{\"ACCESS_TOKEN\":\"opaque-access-value\",\"refresh_token\":\"opaque-refresh-value\"} Authorization: Bearer opaque-bearer-value"
        let sanitized = WorkPiSensitiveText.redacted(message)
        XCTAssertFalse(sanitized.contains("opaque-access-value"))
        XCTAssertFalse(sanitized.contains("opaque-refresh-value"))
        XCTAssertFalse(sanitized.contains("opaque-bearer-value"))
    }

    func testAuthenticationFailureFreezesSteeringAndOffersReconnectWhenIdle() {
        let session = PiSessionController()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-auth-gate-\(UUID().uuidString)")
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.runtimeReady = true
        session.phase = .streaming
        session.noteAuthenticationFailure("HTTP 401: invalid api key")

        XCTAssertTrue(session.runtimeAuthenticationChanged)
        XCTAssertFalse(session.canReconnectRuntime)
        session.sendSteeringPrompt("使用新的认证继续")
        XCTAssertEqual(session.queuedPrompts.map(\.text), ["使用新的认证继续"])

        session.phase = .failed
        XCTAssertTrue(session.canReconnectRuntime)
    }

    func testCommittedAuthenticationFailureMarksRuntimeStale() async {
        let fake = FakeAuthBridgeClient(
            failure: .requestFailed(
                "本地同步失败",
                credentialMayHaveBeenSaved: true,
                changedProviderIDs: ["anthropic"]
            )
        )
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }
        coordinator.login(providerID: "anthropic", type: .apiKey)
        await waitUntil { coordinator.phase.isBusy == false && coordinator.operationMessage != nil }

        XCTAssertTrue(coordinator.runtimeRestartRequired)
        XCTAssertTrue(coordinator.operationMessage?.contains("凭据可能已经保存") == true)
    }

    func testSameTypeExternalCredentialReplacementMarksRuntimeStale() async {
        let fake = FakeAuthBridgeClient(
            includeOrphan: true,
            revisions: ["revision-a", "revision-b"]
        )
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }
        coordinator.refreshStatus()
        await waitUntil { coordinator.runtimeRestartRequired }
        XCTAssertTrue(coordinator.operationMessage?.contains("认证存储已变化") == true)
    }

    func testExternalCredentialChangeMarksRuntimeStale() async {
        let fake = FakeAuthBridgeClient(addOrphanAfterFirstStatus: true)
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }
        coordinator.refreshStatus()
        await waitUntil { coordinator.runtimeRestartRequired }
        XCTAssertTrue(coordinator.operationMessage?.contains("认证存储已变化") == true)
    }

    func testOrphanedCredentialIsVisibleAndCanBeRemoved() async {
        let fake = FakeAuthBridgeClient(includeOrphan: true)
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }

        XCTAssertEqual(coordinator.orphanedCredentials.map(\.providerId), ["legacy-provider"])
        coordinator.logout(providerID: "legacy-provider")
        await waitUntil { coordinator.phase == .idle && fake.lastRequestType == "logout" }
        XCTAssertTrue(coordinator.snapshot.credentials.isEmpty)
    }

    func testLoginEarlyExitStillMarksRuntimeStale() async {
        let fake = FakeAuthBridgeClient(failure: .launchFailed("sidecar 提前退出"))
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }
        coordinator.login(providerID: "anthropic", type: .apiKey)
        await waitUntil { coordinator.phase == .failed("无法启动 Pi 认证桥接：sidecar 提前退出") }
        XCTAssertTrue(coordinator.runtimeRestartRequired)
    }

    func testPromptActionsMustMatchCurrentPromptID() async {
        let fake = FakeAuthBridgeClient()
        let coordinator = WorkPiAuthCoordinator(
            bridgeClient: fake,
            configurationOverride: makeConfiguration()
        )
        coordinator.refreshStatus()
        await waitUntil { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }
        coordinator.login(providerID: "anthropic", type: .apiKey)
        await waitUntil { coordinator.pendingPrompt != nil }
        guard let promptID = coordinator.pendingPrompt?.id else {
            XCTFail("缺少测试 Prompt")
            return
        }

        coordinator.submitPrompt("错误输入", for: "stale-prompt")
        XCTAssertNotNil(coordinator.pendingPrompt)
        coordinator.submitPrompt("正确输入", for: promptID)
        await waitUntil { coordinator.phase == .idle && coordinator.pendingPrompt == nil }
        XCTAssertEqual(fake.receivedSecret, "正确输入")
    }

    func testAuthStoragePermissionsAreTightenedWithoutFollowingSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-auth-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: authURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: authURL.path
        )

        try WorkPiAuthStorageSecurity.ensureUserOnlyPermissions(at: authURL)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: Int16(0o600))
        )

        let targetURL = root.appendingPathComponent("target-auth.json")
        try Data("{}".utf8).write(to: targetURL)
        let linkURL = root.appendingPathComponent("auth-link.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        XCTAssertThrowsError(
            try WorkPiAuthStorageSecurity.ensureUserOnlyPermissions(at: linkURL)
        )
    }

    func testNodeValidatorFallsBackToCompatibleCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-auth-node-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldNode = root.appendingPathComponent("old-node")
        let newNode = root.appendingPathComponent("new-node")
        for node in [oldNode, newNode] {
            try Data().write(to: node)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: node.path
            )
        }
        let configuration = WorkPiAuthBridgeConfiguration(
            nodeURL: oldNode,
            nodeCandidates: [oldNode, newNode],
            entryURL: root.appendingPathComponent("dist/index.js"),
            authPath: root.appendingPathComponent("auth.json"),
            modelsPath: root.appendingPathComponent("models.json"),
            agentDirectoryURL: root,
            currentDirectoryURL: root,
            environment: [:]
        )
        let runner = ScriptedAuthProcessRunner(
            versions: [oldNode.path: "v20.11.0", newNode.path: "v22.19.0"]
        )

        let validated = try await WorkPiAuthBridgeNodeValidator.validatedConfiguration(
            configuration,
            runner: runner
        )
        XCTAssertEqual(validated.nodeURL.path, newNode.path)
        XCTAssertTrue(validated.environment["PATH"]?.hasPrefix(root.path) == true)
    }

    func testAuthenticationChangeAllowsReconnectOnlyWhenRuntimeIsIdle() {
        let session = PiSessionController()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-auth-session-\(UUID().uuidString)")
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.runtimeReady = true
        session.phase = .idle

        session.markRuntimeAuthenticationChanged()
        XCTAssertTrue(session.runtimeAuthenticationChanged)
        XCTAssertTrue(session.canReconnectRuntime)

        session.phase = .streaming
        session.markRuntimeAuthenticationChanged()
        XCTAssertFalse(session.canReconnectRuntime)

        session.phase = .failed
        XCTAssertTrue(session.canReconnectRuntime)
    }

    func testCoordinatorCompletesRealSidecarAPIKeyFlowInOptInIntegration() async throws {
        guard ProcessInfo.processInfo.environment["WORKPI_AUTH_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("设置 WORKPI_AUTH_BRIDGE_TEST=1 才运行真实 Pi SDK 认证桥接测试")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-auth-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .success(let discovered) = WorkPiAuthBridgeLocator.locate() else {
            throw XCTSkip("当前机器没有可用的 Pi SDK/Node 测试安装")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PI_OFFLINE"] = "1"
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        let configuration = WorkPiAuthBridgeConfiguration(
            nodeURL: discovered.nodeURL,
            entryURL: discovered.entryURL,
            authPath: root.appendingPathComponent("auth.json"),
            modelsPath: root.appendingPathComponent("models.json"),
            agentDirectoryURL: root,
            currentDirectoryURL: root,
            environment: environment
        )
        let coordinator = WorkPiAuthCoordinator(configurationOverride: configuration)
        coordinator.refreshStatus()
        await waitUntil(timeout: 500) { coordinator.phase == .idle && !coordinator.snapshot.providers.isEmpty }
        coordinator.login(providerID: "anthropic", type: .apiKey)
        await waitUntil(timeout: 500) { coordinator.pendingPrompt != nil }
        coordinator.submitPrompt("sk-coordinator-test-only")
        await waitUntil(timeout: 500) { coordinator.phase == .idle && coordinator.pendingPrompt == nil }

        XCTAssertEqual(coordinator.snapshot.provider(id: "anthropic")?.configuredType, .apiKey)
        XCTAssertTrue(coordinator.runtimeRestartRequired)
        coordinator.logout(providerID: "anthropic")
        await waitUntil(timeout: 500) { coordinator.phase == .idle && coordinator.pendingPrompt == nil && coordinator.snapshot.provider(id: "anthropic")?.isConfigured == false }
    }

    func testDefaultBridgeCanReadAndStoreAPIKeyInOptInIntegration() async throws {
        guard ProcessInfo.processInfo.environment["WORKPI_AUTH_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("设置 WORKPI_AUTH_BRIDGE_TEST=1 才运行真实 Pi SDK 认证桥接测试")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-auth-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let modelsURL = root.appendingPathComponent("models.json")
        let packageEntry = URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js")
        guard FileManager.default.isReadableFile(atPath: packageEntry.path),
              WorkPiAuthBridgeResources.scriptURL != nil,
              let nodeURL = WorkPiAuthTestSupport.findNode()
        else {
            throw XCTSkip("当前机器没有可用的 Pi SDK/Node 测试安装")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PI_OFFLINE"] = "1"
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        let configuration = WorkPiAuthBridgeConfiguration(
            nodeURL: nodeURL,
            entryURL: packageEntry,
            authPath: authURL,
            modelsPath: modelsURL,
            agentDirectoryURL: root,
            currentDirectoryURL: root,
            environment: environment
        )
        let client = WorkPiDefaultAuthBridgeClient()
        let status = try await client.perform(
            configuration: configuration,
            request: .status(id: UUID().uuidString),
            onPrompt: { _ in throw WorkPiAuthError.cancelled },
            onEvent: { _ in }
        )
        XCTAssertTrue(status.snapshot.providers.contains { $0.id == "anthropic" })

        let anthropicEvent = ThreadSafeString()
        do {
            _ = try await client.perform(
                configuration: configuration,
                request: .login(
                    id: UUID().uuidString,
                    provider: "anthropic",
                    type: .oauth
                ),
                onPrompt: { _ in throw WorkPiAuthError.cancelled },
                onEvent: { event in anthropicEvent.set(event.type) }
            )
            XCTFail("取消 Anthropic OAuth 登录不应返回成功")
        } catch let error as WorkPiAuthError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(anthropicEvent.value, "auth_url")

        do {
            _ = try await client.perform(
                configuration: configuration,
                request: .login(
                    id: UUID().uuidString,
                    provider: "openai-codex",
                    type: .oauth
                ),
                onPrompt: { prompt in
                    XCTAssertEqual(prompt.kind, .select)
                    throw WorkPiAuthError.cancelled
                },
                onEvent: { _ in }
            )
            XCTFail("取消 OAuth 登录不应返回成功")
        } catch let error as WorkPiAuthError {
            XCTAssertEqual(error, .cancelled)
        }

        let loggedIn = try await client.perform(
            configuration: configuration,
            request: .login(id: UUID().uuidString, provider: "anthropic", type: .apiKey),
            onPrompt: { prompt in
                XCTAssertEqual(prompt.kind, .secret)
                return "sk-integration-only"
            },
            onEvent: { _ in }
        )
        XCTAssertEqual(loggedIn.snapshot.provider(id: "anthropic")?.configuredType, .apiKey)
        let reread = try await client.perform(
            configuration: configuration,
            request: .status(id: UUID().uuidString),
            onPrompt: { _ in throw WorkPiAuthError.cancelled },
            onEvent: { _ in }
        )
        XCTAssertEqual(reread.snapshot.provider(id: "anthropic")?.configuredType, .apiKey)
        let saved = try String(contentsOf: authURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("sk-integration-only"))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: Int16(0o600))
        )

        let validated = try await client.perform(
            configuration: configuration,
            request: .validate(id: UUID().uuidString),
            onPrompt: { _ in throw WorkPiAuthError.cancelled },
            onEvent: { _ in }
        )
        XCTAssertTrue(validated.refreshWarnings.isEmpty)

        let loggedOut = try await client.perform(
            configuration: configuration,
            request: .logout(id: UUID().uuidString, provider: "anthropic"),
            onPrompt: { _ in throw WorkPiAuthError.cancelled },
            onEvent: { _ in }
        )
        XCTAssertFalse(loggedOut.snapshot.provider(id: "anthropic")?.isConfigured == true)
        XCTAssertEqual(try String(contentsOf: authURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "{}")
    }

    private func makeConfiguration() -> WorkPiAuthBridgeConfiguration {
        WorkPiAuthBridgeConfiguration(
            nodeURL: URL(fileURLWithPath: "/bin/true"),
            entryURL: URL(fileURLWithPath: "/tmp/pi-sdk-entry.js"),
            authPath: URL(fileURLWithPath: "/tmp/auth.json"),
            modelsPath: URL(fileURLWithPath: "/tmp/models.json"),
            agentDirectoryURL: URL(fileURLWithPath: "/tmp"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: [:]
        )
    }

    private func waitUntil(
        timeout: Int = 200,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("认证状态在预期时间内没有完成")
    }
}

private final class FakeAuthBridgeClient: WorkPiAuthBridgeClient, @unchecked Sendable {
    private let sendEvent: Bool
    private let failure: WorkPiAuthError?
    private let includeOrphan: Bool
    private let addOrphanAfterFirstStatus: Bool
    private let revisions: [String?]
    private let revisionCounter = ThreadSafeCounter()
    private let lock = NSLock()
    private var storedRequestType: String?
    private var storedSecret: String?
    private let statusRequestCounter = ThreadSafeCounter()

    var lastRequestType: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestType
    }

    var receivedSecret: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedSecret
    }

    init(
        sendEvent: Bool = false,
        failure: WorkPiAuthError? = nil,
        includeOrphan: Bool = false,
        addOrphanAfterFirstStatus: Bool = false,
        revisions: [String?] = []
    ) {
        self.sendEvent = sendEvent
        self.failure = failure
        self.includeOrphan = includeOrphan
        self.addOrphanAfterFirstStatus = addOrphanAfterFirstStatus
        self.revisions = revisions
    }

    private func recordRequest(_ type: String) {
        lock.lock()
        storedRequestType = type
        lock.unlock()
    }

    private func recordSecret(_ value: String) {
        lock.lock()
        storedSecret = value
        lock.unlock()
    }

    func perform(
        configuration: WorkPiAuthBridgeConfiguration,
        request: WorkPiAuthBridgeRequest,
        onPrompt: @escaping @Sendable (WorkPiAuthPrompt) async throws -> String,
        onEvent: @escaping @Sendable (WorkPiAuthEvent) async -> Void
    ) async throws -> WorkPiAuthBridgeResult {
        recordRequest(request.type)
        if request.type == "login", let failure {
            throw failure
        }

        if request.type == "login" {
            if sendEvent {
                await onEvent(WorkPiAuthEvent(
                    type: "auth_url",
                    url: URL(string: "http://localhost:53692/callback"),
                    instructions: "测试事件"
                ))
            }
            let prompt = WorkPiAuthPrompt(
                id: "prompt-1",
                kind: request.authType == .oauth ? .select : .secret,
                message: request.authType == .oauth ? "选择登录方式" : "输入 API Key",
                placeholder: nil,
                options: request.authType == .oauth
                    ? [WorkPiAuthPrompt.Option(id: "browser", label: "Browser", description: nil)]
                    : []
            )
            let value = try await onPrompt(prompt)
            recordSecret(value)
        }

        let configured = request.type == "login"
            ? WorkPiAuthStatus(configured: true, type: request.authType, source: "stored", subscription: request.authType == .oauth)
            : .unconfigured
        let provider = WorkPiAuthProvider(
            id: "anthropic",
            name: "Anthropic",
            authTypes: [
                WorkPiAuthMethod(type: .oauth, name: "Claude OAuth", isSubscription: true, loginLabel: nil, canLogin: true),
                WorkPiAuthMethod(type: .apiKey, name: "Anthropic API key", isSubscription: false, loginLabel: nil, canLogin: true),
            ],
            status: configured
        )
        var credentials: [WorkPiStoredCredential] = request.type == "login"
            ? [WorkPiStoredCredential(providerId: "anthropic", type: request.authType ?? .apiKey)]
            : []
        var shouldIncludeOrphan = includeOrphan && request.type == "status"
        if request.type == "status", addOrphanAfterFirstStatus {
            shouldIncludeOrphan = statusRequestCounter.next() > 1
        }
        if shouldIncludeOrphan {
            credentials.append(WorkPiStoredCredential(providerId: "legacy-provider", type: .apiKey))
        }
        let snapshot = WorkPiAuthSnapshot(
            providers: [provider],
            credentials: credentials,
            models: [WorkPiAuthModel(
                providerId: "anthropic",
                id: "claude-test",
                name: "Claude Test",
                api: "anthropic-messages",
                reasoning: true,
                input: ["text"],
                contextWindow: 100_000,
                maxTokens: 4_096
            )],
            modelsTruncated: false
        )
        let revisionIndex = revisionCounter.next() - 1
        return WorkPiAuthBridgeResult(
            snapshot: snapshot,
            refreshAborted: false,
            refreshWarnings: [],
            authStorageRevision: revisionIndex < revisions.count ? revisions[revisionIndex] : nil
        )
    }
}

private final class ScriptedAuthProcessRunner: WorkPiProcessRunner, @unchecked Sendable {
    private let versions: [String: String]

    init(versions: [String: String]) {
        self.versions = versions
    }

    func run(_ request: WorkPiProcessRequest) async throws -> WorkPiProcessResult {
        let version = versions[request.executableURL.path] ?? ""
        return WorkPiProcessResult(
            status: version.isEmpty ? 1 : 0,
            stdout: Data(version.utf8),
            stderr: Data(),
            stdoutWasTruncated: false,
            stderrWasTruncated: false
        )
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        value += 1
        let result = value
        lock.unlock()
        return result
    }
}

private final class ThreadSafeString: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: String) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private enum WorkPiAuthTestSupport {
    static func findNode() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
            + [
                URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                URL(fileURLWithPath: "/usr/local/bin/node"),
            ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
