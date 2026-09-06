import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi
import WorkspaceKit

/// 模型与推理强度的协议解析、可用列表拉取和切换行为。
///
/// 全部用例使用 `FakePiRPCTransport`，不调用真实模型。
@MainActor
final class PuraPiModelControlTests: XCTestCase {
    // MARK: - 协议解析

    func testAvailableModelsParsingSkipsEntriesWithoutIdentity() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_available_models"),
            "success": .bool(true),
            "data": .object([
                "models": .array([
                    .object([
                        "id": .string("claude-sonnet-4"),
                        "name": .string("Claude Sonnet 4"),
                        "provider": .string("anthropic"),
                        "reasoning": .bool(true),
                        "contextWindow": .integer(200_000),
                    ]),
                    // 缺 provider，无法用于 set_model，必须丢弃。
                    .object([
                        "id": .string("orphan-model"),
                        "name": .string("Orphan"),
                    ]),
                    // 缺 name 时回退到 id，而不是显示空白。
                    .object([
                        "id": .string("gpt-5.6"),
                        "provider": .string("openai"),
                    ]),
                ]),
            ]),
        ])

        let models = try? XCTUnwrap(record.availableModels)
        XCTAssertEqual(models?.count, 2)
        XCTAssertEqual(models?.first?.name, "Claude Sonnet 4")
        XCTAssertEqual(models?.first?.selectionKey, "anthropic/claude-sonnet-4")
        XCTAssertEqual(models?.first?.reasoning, true)
        XCTAssertEqual(models?.first?.contextWindow, 200_000)
        XCTAssertEqual(models?.last?.name, "gpt-5.6")
        XCTAssertEqual(models?.last?.selectionKey, "openai/gpt-5.6")
        XCTAssertEqual(models?.last?.reasoning, false)
    }

    func testAvailableThinkingLevelsParsing() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_available_thinking_levels"),
            "success": .bool(true),
            "data": .object([
                "levels": .array([
                    .string("off"),
                    .string("low"),
                    .string("high"),
                    .string("max"),
                ]),
            ]),
        ])

        XCTAssertEqual(record.availableThinkingLevels, ["off", "low", "high", "max"])
    }

    /// `set_model` 直接返回 Model；`cycle_model` 把 Model 包在 `data.model` 下。
    /// 两种形状都要能读出 provider/id。
    func testModelIdentityParsingCoversBothResponseShapes() {
        let setModel = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_model"),
            "success": .bool(true),
            "data": .object([
                "id": .string("gpt-5.6"),
                "provider": .string("openai"),
                "name": .string("GPT-5.6"),
                "reasoning": .bool(true),
            ]),
        ])
        XCTAssertEqual(setModel.modelIdentity?.provider, "openai")
        XCTAssertEqual(setModel.modelIdentity?.id, "gpt-5.6")
        XCTAssertEqual(setModel.modelSupportsReasoning, true)

        let cycleModel = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("cycle_model"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "id": .string("claude-sonnet-4"),
                    "provider": .string("anthropic"),
                    "name": .string("Claude Sonnet 4"),
                    "reasoning": .bool(false),
                ]),
                "thinkingLevel": .string("medium"),
            ]),
        ])
        XCTAssertEqual(cycleModel.modelIdentity?.provider, "anthropic")
        XCTAssertEqual(cycleModel.modelIdentity?.id, "claude-sonnet-4")
        XCTAssertEqual(cycleModel.modelSupportsReasoning, false)
    }

    func testCommandFactoriesEncodeUpstreamFields() {
        let setModel = PiRPCCommand.setModel(provider: "openai", modelID: "gpt-5.6")
        XCTAssertEqual(setModel.type, "set_model")
        XCTAssertEqual(setModel.fields["provider"]?.stringValue, "openai")
        XCTAssertEqual(setModel.fields["modelId"]?.stringValue, "gpt-5.6")

        let setLevel = PiRPCCommand.setThinkingLevel("high")
        XCTAssertEqual(setLevel.type, "set_thinking_level")
        XCTAssertEqual(setLevel.fields["level"]?.stringValue, "high")

        XCTAssertEqual(PiRPCCommand.cycleModel().type, "cycle_model")
        XCTAssertEqual(PiRPCCommand.getAvailableModels().type, "get_available_models")
        XCTAssertEqual(PiRPCCommand.cycleThinkingLevel().type, "cycle_thinking_level")
        XCTAssertEqual(
            PiRPCCommand.getAvailableThinkingLevels().type,
            "get_available_thinking_levels"
        )
    }

    // MARK: - 控制器行为

    /// Runtime 就绪后应自动拉取模型目录，HUD 才有可选项。
    func testRuntimeReadyRequestsModelCatalog() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.contains("get_available_models")
                && types.contains("get_available_thinking_levels")
        }

        await transport.emit(.record(Self.availableModelsRecord()))
        try await waitUntil { session.availableModels.count == 2 }
        await transport.emit(.record(Self.thinkingLevelsRecord(["off", "medium", "high"])))

        try await waitUntil { session.availableThinkingLevels.count == 3 }
        XCTAssertEqual(session.availableThinkingLevels, ["off", "medium", "high"])
        XCTAssertTrue(session.supportsThinkingLevelSelection)
        XCTAssertNil(session.lastError)
    }

    func testSelectModelSendsSetModelAndRefreshesStateFromPi() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        await transport.emit(.record(Self.availableModelsRecord()))
        try await waitUntil { session.availableModels.count == 2 }

        session.selectModel(provider: "anthropic", modelID: "claude-sonnet-4")
        XCTAssertTrue(session.modelSwitchInFlight)

        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "set_model" }
        }
        let sentModelCommands = await transport.sentCommands.filter { $0.type == "set_model" }
        let sent = try XCTUnwrap(sentModelCommands.first)
        XCTAssertEqual(sent.fields["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(sent.fields["modelId"]?.stringValue, "claude-sonnet-4")

        await transport.emit(.record(Self.setModelRecord(
            id: sent.id,
            provider: "anthropic",
            modelID: "claude-sonnet-4",
            name: "Claude Sonnet 4",
            reasoning: true
        )))

        try await waitUntil { session.modelSwitchInFlight == false }
        // set_model 直接返回 Model 对象（不包在 data.model 下），HUD 必须立即反映新名称。
        XCTAssertEqual(session.runtimeMetadata.modelName, "Claude Sonnet 4")
        XCTAssertEqual(session.runtimeMetadata.modelSelectionKey, "anthropic/claude-sonnet-4")

        // 切模型会改变上下文窗口与推理能力，必须重新拉级别并回读状态。
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            let levelRequests = types.filter { $0 == "get_available_thinking_levels" }.count
            let stateRequests = types.filter { $0 == "get_state" }.count
            return levelRequests >= 2 && stateRequests >= 2
        }

        // 回读的 get_state 已经反映新模型；HUD 应继续显示 Pi 的事实值。
        await transport.emit(.record(Self.stateRecord(
            provider: "anthropic",
            modelID: "claude-sonnet-4",
            name: "Claude Sonnet 4",
            contextWindow: 200_000
        )))
        try await waitUntil { session.runtimeMetadata.contextWindow == 200_000 }
        XCTAssertEqual(session.runtimeMetadata.modelName, "Claude Sonnet 4")
        XCTAssertEqual(session.runtimeMetadata.modelSelectionKey, "anthropic/claude-sonnet-4")
        XCTAssertNil(session.lastError)
    }

    func testSelectingCurrentModelDoesNotSendCommand() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        await transport.emit(.record(Self.setModelRecord(
            id: "seed",
            provider: "openai",
            modelID: "gpt-5.6",
            name: "GPT-5.6",
            reasoning: true
        )))
        try await waitUntil { session.runtimeMetadata.modelID == "gpt-5.6" }

        let before = await transport.sentCommands.filter { $0.type == "set_model" }.count
        session.selectModel(provider: "openai", modelID: "gpt-5.6")

        XCTAssertFalse(session.modelSwitchInFlight)
        let after = await transport.sentCommands.filter { $0.type == "set_model" }.count
        XCTAssertEqual(before, after)
    }

    func testSelectThinkingLevelSendsCommandAndAppliesResult() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        await transport.emit(.record(Self.thinkingLevelsRecord(["off", "medium", "high"])))
        try await waitUntil { session.availableThinkingLevels.count == 3 }

        session.selectThinkingLevel("high")
        XCTAssertTrue(session.thinkingLevelSwitchInFlight)

        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "set_thinking_level" }
        }
        let sentLevelCommands = await transport.sentCommands.filter {
            $0.type == "set_thinking_level"
        }
        let sent = try XCTUnwrap(sentLevelCommands.first)
        XCTAssertEqual(sent.fields["level"]?.stringValue, "high")

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_thinking_level"),
            "id": .string(sent.id ?? ""),
            "success": .bool(true),
        ])))

        try await waitUntil { session.thinkingLevelSwitchInFlight == false }
        XCTAssertNil(session.lastError)
    }

    /// 模型不支持推理时不发命令，避免无意义往返。
    func testThinkingLevelSelectionRejectedForNonReasoningModel() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        // 这是测试用的初始 Runtime 快照，不是一个待消费的 set_model 响应；
        // 直接注入元数据，避免伪造无 active request 的旧响应。
        session.updateRuntimeMetadata(from: Self.setModelRecord(
            id: "seed",
            provider: "openai",
            modelID: "plain",
            name: "Plain",
            reasoning: false
        ))
        try await waitUntil { session.runtimeMetadata.modelSupportsReasoning == false }

        XCTAssertFalse(session.supportsThinkingLevelSelection)
        session.selectThinkingLevel("high")

        XCTAssertFalse(session.thinkingLevelSwitchInFlight)
        XCTAssertEqual(session.lastError, "当前模型不支持切换推理强度。")
        let sentLevels = await transport.sentCommands.filter { $0.type == "set_thinking_level" }
        XCTAssertTrue(sentLevels.isEmpty)
    }

    /// 失败响应必须清掉 in-flight 标记，否则 HUD 永久卡在切换中。
    func testFailedSwitchClearsInFlightAndReportsError() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        await transport.emit(.record(Self.availableModelsRecord()))
        try await waitUntil { session.availableModels.count == 2 }

        session.selectModel(provider: "anthropic", modelID: "claude-sonnet-4")
        try await waitUntil {
            await transport.sentCommands.contains { $0.type == "set_model" }
        }
        let failedCandidates = await transport.sentCommands.filter { $0.type == "set_model" }
        let sent = try XCTUnwrap(failedCandidates.first)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_model"),
            "id": .string(sent.id ?? ""),
            "success": .bool(false),
            "error": .string("模型不可用"),
        ])))

        try await waitUntil { session.modelSwitchInFlight == false }
        XCTAssertEqual(session.lastError, "模型不可用")
    }

    /// 旧模型响应不能清掉新请求的 in-flight 状态或覆盖错误。
    func testStaleModelResponseIsIgnored() {
        let session = PiSessionController()
        session.modelSwitchInFlight = true
        session.activeModelCommandID = "model-new"
        session.consume(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_model"),
            "id": .string("model-old"),
            "success": .bool(false),
            "error": .string("旧请求失败"),
        ]))

        XCTAssertTrue(session.modelSwitchInFlight)
        XCTAssertEqual(session.activeModelCommandID, "model-new")
        XCTAssertNil(session.lastError)
    }

    func testSingleThinkingLevelIsNotSelectable() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)
        await transport.emit(.record(Self.thinkingLevelsRecord(["off"])))

        try await waitUntil { session.availableThinkingLevels == ["off"] }
        XCTAssertFalse(session.supportsThinkingLevelSelection)
    }

    // MARK: - 辅助

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-model-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transport = FakePiRPCTransport()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { transport }
        )
        return (session, transport, root)
    }

    private func startAndHandshake(
        _ session: PiSessionController,
        _ transport: FakePiRPCTransport,
        _ root: URL
    ) async throws {
        session.openWorkspace(root)
        try await waitUntil { await transport.workspaceURL != nil }
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for PuraPi model control state")
    }

    private static func stateRecord(
        provider: String = "openai",
        modelID: String = "gpt-5.6",
        name: String = "GPT-5.6",
        contextWindow: Int64 = 272_000
    ) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "id": .string(modelID),
                    "provider": .string(provider),
                    "name": .string(name),
                    "reasoning": .bool(true),
                    "contextWindow": .integer(contextWindow),
                ]),
                "thinkingLevel": .string("medium"),
                "messageCount": .integer(0),
            ]),
        ])
    }

    private static func statsRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
            "data": .object([
                "contextUsage": .object([
                    "tokens": .integer(0),
                    "contextWindow": .integer(272_000),
                    "percent": .integer(0),
                ]),
            ]),
        ])
    }

    private static func availableModelsRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_available_models"),
            "success": .bool(true),
            "data": .object([
                "models": .array([
                    .object([
                        "id": .string("gpt-5.6"),
                        "provider": .string("openai"),
                        "name": .string("GPT-5.6"),
                        "reasoning": .bool(true),
                    ]),
                    .object([
                        "id": .string("claude-sonnet-4"),
                        "provider": .string("anthropic"),
                        "name": .string("Claude Sonnet 4"),
                        "reasoning": .bool(true),
                    ]),
                ]),
            ]),
        ])
    }

    private static func thinkingLevelsRecord(_ levels: [String]) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_available_thinking_levels"),
            "success": .bool(true),
            "data": .object([
                "levels": .array(levels.map(JSONValue.string)),
            ]),
        ])
    }

    private static func setModelRecord(
        id: String?,
        provider: String,
        modelID: String,
        name: String,
        reasoning: Bool
    ) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_model"),
            "id": .string(id ?? ""),
            "success": .bool(true),
            "data": .object([
                "id": .string(modelID),
                "provider": .string(provider),
                "name": .string(name),
                "reasoning": .bool(reasoning),
            ]),
        ])
    }
}
