import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi
import WorkspaceKit

/// 活动指示的状态机与双语文案。
///
/// 活动只由 Pi 事件驱动，不从 phase 反推；回合结束或 Runtime 断开必须清空，
/// 否则指示器会一直转。
@MainActor
final class PuraPiActivityTests: XCTestCase {
    // MARK: - 文案

    func testChineseLabelsCoverAllActivities() {
        let cases: [(AgentActivity, String)] = [
            (.waitingForModel, "等待模型响应"),
            (.thinking, "思考中"),
            (.responding, "生成回答"),
            (.runningTool(name: "bash"), "执行 bash"),
            (.runningTool(name: nil), "执行工具"),
            (.runningCommand, "执行命令"),
            (.compacting(isAutomatic: false), "压缩上下文"),
            (.compacting(isAutomatic: true), "自动压缩上下文"),
            (.retrying(attempt: 2, maxAttempts: 3), "重试中（2/3）"),
            (.retrying(attempt: nil, maxAttempts: nil), "重试中"),
            (.summarizing, "生成上下文摘要"),
            (.restoringSession, "恢复会话"),
            (.stopping, "正在停止"),
        ]

        for (activity, expected) in cases {
            XCTAssertEqual(
                AgentActivityText.label(for: activity, language: .chinese),
                expected
            )
        }
    }

    func testEnglishLabelsCoverAllActivities() {
        let cases: [(AgentActivity, String)] = [
            (.waitingForModel, "Waiting for model"),
            (.thinking, "Thinking"),
            (.responding, "Responding"),
            (.runningTool(name: "read"), "Running read"),
            (.runningTool(name: nil), "Running tool"),
            (.runningCommand, "Running command"),
            (.compacting(isAutomatic: false), "Compacting context"),
            (.compacting(isAutomatic: true), "Auto-compacting"),
            (.retrying(attempt: 1, maxAttempts: 5), "Retrying (1/5)"),
            (.retrying(attempt: nil, maxAttempts: nil), "Retrying"),
            (.summarizing, "Summarizing context"),
            (.restoringSession, "Restoring session"),
            (.stopping, "Stopping"),
        ]

        for (activity, expected) in cases {
            XCTAssertEqual(
                AgentActivityText.label(for: activity, language: .english),
                expected
            )
        }
    }

    /// 指示器帧与节奏对齐 Pi TUI 的 Loader。
    func testIndicatorFramesMatchUpstreamLoader() {
        XCTAssertEqual(
            PuraPiActivityIndicator.frames,
            ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        )
        XCTAssertEqual(PuraPiActivityIndicator.frameInterval, 0.08, accuracy: 0.0001)
    }

    /// 指示器必须与对话行共用同一左边界。
    ///
    /// 行内容被限制到最大宽度后是居中的，所以左边界是动态值；
    /// 早先把指示器当成固定 `rowHorizontalInset` 左对齐，会让它跑到
    /// 正文左边界之外的空白区。
    func testIndicatorAlignsWithCenteredRowLeadingEdge() {
        // 宽窗口：行被 900 上限截断后居中，偏移大于固定内边距。
        let wide: CGFloat = 1_400
        XCTAssertEqual(PuraPiConversationLayout.rowWidth(availableWidth: wide), 900)
        XCTAssertEqual(
            PuraPiConversationLayout.rowLeadingOffset(availableWidth: wide),
            250
        )
        XCTAssertGreaterThan(
            PuraPiConversationLayout.rowLeadingOffset(availableWidth: wide),
            PuraPiConversationLayout.rowHorizontalInset
        )

        // 窄窗口：未达上限，偏移退回固定内边距。
        let narrow: CGFloat = 600
        XCTAssertEqual(
            PuraPiConversationLayout.rowWidth(availableWidth: narrow),
            narrow - PuraPiConversationLayout.rowHorizontalInset * 2
        )
        XCTAssertEqual(
            PuraPiConversationLayout.rowLeadingOffset(availableWidth: narrow),
            PuraPiConversationLayout.rowHorizontalInset
        )

        // 异常小宽度不能产生负偏移。
        XCTAssertGreaterThanOrEqual(
            PuraPiConversationLayout.rowLeadingOffset(availableWidth: 10),
            0
        )
    }

    // MARK: - 状态机

    func testActivityFollowsStreamingAndClearsWhenSettled() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        XCTAssertNil(session.activity)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ])))
        try await waitUntil { session.activity == .waitingForModel }

        await transport.emit(.record(Self.thinkingDeltaRecord("推理")))
        try await waitUntil { session.activity == .thinking }

        await transport.emit(.record(Self.textDeltaRecord("正文")))
        try await waitUntil { session.activity == .responding }

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_settled"),
        ])))
        try await waitUntil { session.activity == nil }
    }

    func testToolActivityCarriesToolName() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("tool_execution_start"),
            "toolCallId": .string("call-1"),
            "toolName": .string("bash"),
        ])))

        try await waitUntil { session.activity == .runningTool(name: "bash") }
    }

    /// 压缩、重试、摘要在 phase 上都是 .settling，必须靠独立活动区分。
    func testCompactionRetryAndSummarizationAreDistinguishable() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("compaction_start"),
            "reason": .string("overflow"),
        ])))
        try await waitUntil { session.activity == .compacting(isAutomatic: true) }
        XCTAssertEqual(session.phase, .settling)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("auto_retry_start"),
            "attempt": .integer(2),
            "maxAttempts": .integer(3),
        ])))
        try await waitUntil { session.activity == .retrying(attempt: 2, maxAttempts: 3) }
        XCTAssertEqual(session.phase, .settling)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("summarization_retry_scheduled"),
        ])))
        try await waitUntil { session.activity == .summarizing }
        XCTAssertEqual(session.phase, .settling)
    }

    func testManualCompactionIsNotReportedAsAutomatic() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("compaction_start"),
            "reason": .string("manual"),
        ])))

        try await waitUntil { session.activity == .compacting(isAutomatic: false) }
    }

    /// Runtime 断开时必须停止指示，否则界面上会永久转圈。
    func testActivityClearsOnTransportEOF() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ])))
        try await waitUntil { session.activity != nil }

        await transport.finish()
        try await waitUntil { session.activity == nil }
        XCTAssertEqual(session.phase, .failed)
    }

    func testActivityClearsOnProcessExit() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("agent_start"),
        ])))
        try await waitUntil { session.activity != nil }

        await transport.emit(.processExited(status: 1))
        try await waitUntil { session.activity == nil }
    }

    /// 同一活动内的重复事件不应重置计时，否则耗时永远显示 0s。
    func testRepeatedSameActivityKeepsStartTimestamp() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.textDeltaRecord("第一段")))
        try await waitUntil { session.activity == .responding }
        let firstStart = session.activityStartedAt

        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(.record(Self.textDeltaRecord("第二段")))
        try await waitUntil { session.activity == .responding }

        XCTAssertEqual(session.activityStartedAt, firstStart)
    }

    func testActivityStartTimestampResetsWhenActivityChanges() async throws {
        let (session, transport, root) = try makeSession()
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.thinkingDeltaRecord("推理")))
        try await waitUntil { session.activity == .thinking }
        let thinkingStart = session.activityStartedAt

        try await Task.sleep(for: .milliseconds(60))
        await transport.emit(.record(Self.textDeltaRecord("正文")))
        try await waitUntil { session.activity == .responding }

        XCTAssertGreaterThan(session.activityStartedAt, thinkingStart)
    }

    // MARK: - 辅助

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-activity-\(UUID().uuidString)", isDirectory: true)
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
        XCTFail("Timed out waiting for PuraPi activity state")
    }

    private static func textDeltaRecord(_ delta: String) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "contentIndex": .integer(0),
                "delta": .string(delta),
            ]),
        ])
    }

    private static func thinkingDeltaRecord(_ delta: String) -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("thinking_delta"),
                "contentIndex": .integer(0),
                "delta": .string(delta),
            ]),
        ])
    }

    private static func stateRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "id": .string("gpt-5.6"),
                    "provider": .string("openai"),
                    "name": .string("GPT-5.6"),
                    "contextWindow": .integer(272_000),
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
}
