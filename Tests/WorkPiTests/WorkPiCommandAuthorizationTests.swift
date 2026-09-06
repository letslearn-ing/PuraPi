import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi
import WorkspaceKit

@MainActor
final class WorkPiCommandAuthorizationTests: XCTestCase {
    func testCommandCatalogLocalizesFiltersAndHandlesSlashQueries() {
        let piCommands = [
            PiRPCCommandInfo(
                name: "/workpi-ui-demo",
                description: "演示原生面板",
                source: "extension"
            ),
            PiRPCCommandInfo(
                name: "skill:search",
                description: nil,
                source: "skill"
            ),
            PiRPCCommandInfo(
                name: "prompt:review",
                description: nil,
                source: "prompt"
            ),
            PiRPCCommandInfo(
                name: "/new",
                description: "重复的扩展命令",
                source: "extension"
            ),
        ]

        let chinese = WorkPiCommandCatalog.items(
            piCommands: piCommands,
            language: .chinese
        )
        XCTAssertEqual(
            Array(chinese.prefix(6)).map(\.name),
            ["new", "status", "continue", "compact", "abort", "trust"]
        )
        XCTAssertEqual(chinese.first(where: { $0.name == "new" })?.description, "新建会话")
        XCTAssertEqual(
            chinese.first(where: { $0.name == "workpi-ui-demo" })?.sourceLabel(language: .chinese),
            "扩展"
        )
        XCTAssertEqual(
            chinese.first(where: { $0.name == "skill:search" })?.description,
            "运行这个技能"
        )
        XCTAssertEqual(
            chinese.first(where: { $0.name == "prompt:review" })?.description,
            "运行这个提示模板"
        )
        XCTAssertEqual(
            WorkPiCommandCatalog.filtered(chinese, query: "面板").map(\.name),
            ["workpi-ui-demo"]
        )

        let english = WorkPiCommandCatalog.items(
            piCommands: piCommands,
            language: .english
        )
        XCTAssertEqual(english.first(where: { $0.name == "new" })?.description, "New session")
        XCTAssertEqual(
            english.first(where: { $0.name == "skill:search" })?.sourceLabel(language: .english),
            "Skill"
        )
        XCTAssertEqual(
            english.first(where: { $0.name == "prompt:review" })?.description,
            "Run this prompt template"
        )
        XCTAssertEqual(
            english.filter { $0.name == "new" }.count,
            1,
            "Pi 命令发现不能覆盖 WorkPi 内置命令"
        )

        XCTAssertEqual(WorkPiCommandCatalog.slashQuery(for: "/"), "")
        XCTAssertEqual(WorkPiCommandCatalog.slashQuery(for: "/con"), "con")
        XCTAssertEqual(WorkPiCommandCatalog.slashQuery(for: "/compact 关注上下文"), "compact")
        XCTAssertNil(WorkPiCommandCatalog.slashQuery(for: "普通文本"))
        XCTAssertFalse(WorkPiCommandCatalog.hasCommandArgument("/con"))
        XCTAssertTrue(WorkPiCommandCatalog.hasCommandArgument("/compact 关注上下文"))
        XCTAssertEqual(WorkPiCommandCatalog.action(for: "/NEW"), .newSession)
        XCTAssertEqual(WorkPiCommandCatalog.action(for: "/compact 关注上下文"), .compact)
        XCTAssertNil(WorkPiCommandCatalog.action(for: "普通文本"))
        XCTAssertEqual(
            WorkPiCommandCatalog.customInstructions(from: "/compact 关注上下文"),
            "关注上下文"
        )
        XCTAssertNil(WorkPiCommandCatalog.customInstructions(from: "/compact"))
        XCTAssertEqual(
            WorkPiCommandCatalog.movedSelection(
                currentIndex: 99,
                direction: .down,
                resultCount: 2
            ),
            1
        )
        XCTAssertEqual(
            WorkPiCommandCatalog.movedSelection(
                currentIndex: 0,
                direction: .up,
                resultCount: 0
            ),
            0
        )
        XCTAssertEqual(
            WorkPiCommandCatalog.movedSelection(
                currentIndex: 4,
                direction: .down,
                resultCount: 9
            ),
            5,
            "超过第五项后，选择索引必须继续前进，面板再负责把目标行滚入可视区"
        )
        XCTAssertNil(
            WorkPiCommandPaletteScrollPolicy.targetFirstVisibleIndex(
                selectedIndex: 2,
                currentFirstVisibleIndex: 0,
                resultCount: 9
            ),
            "第三项仍在首屏时不应滚动"
        )
        XCTAssertEqual(
            WorkPiCommandPaletteScrollPolicy.targetFirstVisibleIndex(
                selectedIndex: 5,
                currentFirstVisibleIndex: 0,
                resultCount: 9
            ),
            1,
            "按到第六项时应只向下滚动一行"
        )
        XCTAssertEqual(
            WorkPiCommandPaletteScrollPolicy.targetFirstVisibleIndex(
                selectedIndex: 0,
                currentFirstVisibleIndex: 1,
                resultCount: 9
            ),
            0,
            "向上越过首行时应只回滚到目标项"
        )
        let discovered = PiRPCCommandInfo(
            name: "/workpi-ui-demo",
            description: "演示面板",
            source: "extension"
        )
        XCTAssertEqual(
            WorkPiCommandCatalog.discoveredCommand(
                for: "/workpi-ui-demo 参数",
                piCommands: [discovered]
            ),
            discovered
        )
    }

    func testProjectAuthorizationDetectsScopedResourcesAndStopsAtFilesystemRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-auth-detection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(WorkPiProjectAuthorization.requiresAuthorization(for: root))

        let projectExtensionDirectory = root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectExtensionDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(WorkPiProjectAuthorization.requiresAuthorization(for: root))

        try FileManager.default.removeItem(at: root.appendingPathComponent(".pi"))
        let projectSkillsDirectory = root
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectSkillsDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(WorkPiProjectAuthorization.requiresAuthorization(for: root))

        try FileManager.default.removeItem(at: root.appendingPathComponent(".agents"))
        XCTAssertFalse(WorkPiProjectAuthorization.requiresAuthorization(for: root))
    }

    func testRuntimeLaunchModesKeepApprovalSeparateFromSessionRestore() {
        XCTAssertEqual(PiRuntimeLaunchMode.fresh.processArguments, ["--mode", "rpc"])
        XCTAssertEqual(
            PiRuntimeLaunchMode.continueRecent.processArguments,
            ["--mode", "rpc", "--continue"]
        )
        XCTAssertEqual(
            PiRuntimeLaunchMode.freshApproved.processArguments,
            ["--mode", "rpc", "--approve"]
        )
        XCTAssertEqual(
            PiRuntimeLaunchMode.continueRecentApproved.processArguments,
            ["--mode", "rpc", "--continue", "--approve"]
        )
        XCTAssertFalse(PiRuntimeLaunchMode.freshApproved.requiresMessageRestore)
        XCTAssertTrue(PiRuntimeLaunchMode.continueRecentApproved.requiresMessageRestore)
    }

    func testProjectAuthorizationBlocksRuntimeUntilApprovedAndUsesApprovedLaunchMode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-auth-flow-\(UUID().uuidString)", isDirectory: true)
        let extensionDirectory = root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = CommandAuthorizationModeTransportCollector()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { mode in collector.make(mode) }
        )
        session.openWorkspace(root)
        try await waitUntil { session.fileTree != nil }

        XCTAssertEqual(session.projectAuthorizationState, .needsDecision)
        XCTAssertEqual(collector.count, 0)
        XCTAssertFalse(session.runtimeReady)

        session.denyProjectAuthorization()
        XCTAssertEqual(session.projectAuthorizationState, .denied)
        XCTAssertEqual(session.runtimeStatus, "项目未授权，扩展未加载")
        session.continueRecentSession()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(collector.count, 0, "拒绝授权不能通过 /continue 绕过项目门控")

        session.approveProjectAuthorization()
        try await waitUntil { collector.count == 1 }
        XCTAssertEqual(collector.mode(at: 0), .freshApproved)
        let transport = try XCTUnwrap(collector.transport(at: 0))
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        await emitHandshake(transport)
        try await waitUntil { session.runtimeReady }
    }

    func testInitialAuthorizationDenialKeepsLoadedWorkspaceWithoutStartingRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-auth-deny-\(UUID().uuidString)", isDirectory: true)
        let extensionDirectory = root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = CommandAuthorizationModeTransportCollector()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { mode in collector.make(mode) }
        )
        session.openWorkspace(root)
        session.denyProjectAuthorization()

        try await waitUntil { session.fileTree != nil }
        XCTAssertEqual(session.fileTree?.url, root.standardizedFileURL)
        XCTAssertEqual(session.projectAuthorizationState, .denied)
        XCTAssertEqual(session.runtimeStatus, "项目未授权，扩展未加载")
        XCTAssertEqual(collector.count, 0)
        XCTAssertFalse(session.runtimeReady)
    }

    func testSlashBuiltInCommandsUseNativeRuntimeActions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-slash-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = CommandAuthorizationModeTransportCollector()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { mode in collector.make(mode) }
        )
        session.openWorkspace(root)
        try await waitUntil { collector.count == 1 }
        let fresh = try XCTUnwrap(collector.transport(at: 0))
        try await waitUntil {
            let types = await fresh.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        await emitHandshake(fresh)
        try await waitUntil { session.runtimeReady }

        session.draftPrompt = "/compact 只保留关键决策"
        session.submitPrompt()
        try await waitUntil {
            await fresh.sentCommands.contains(where: {
                $0.type == "compact"
                    && $0.fields["customInstructions"]?.stringValue == "只保留关键决策"
            })
        }
        let compactCommands = await fresh.sentCommands.filter { $0.type == "compact" }
        let commandsAfterCompact = await fresh.sentCommands
        XCTAssertEqual(compactCommands.count, 1)
        XCTAssertFalse(commandsAfterCompact.contains(where: { $0.type == "prompt" }))

        await fresh.emit(.record(PiRPCRecord(fields: [
            "type": .string("compaction_end"),
        ])))
        await fresh.emit(.record(PiRPCRecord(fields: ["type": .string("agent_settled")])))
        try await waitUntil { session.phase == .idle }

        session.draftPrompt = "/new"
        session.submitPrompt()
        try await waitUntil { collector.count == 2 }
        XCTAssertEqual(collector.mode(at: 1), .fresh)
        let newTransport = try XCTUnwrap(collector.transport(at: 1))
        try await waitUntil {
            let types = await newTransport.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        let commandsAfterNew = await fresh.sentCommands
        XCTAssertFalse(commandsAfterNew.contains(where: { $0.type == "prompt" }))
    }

    func testAlreadyCompactedIsVisibleNoOpNotRuntimeError() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.submitCommand("/compact")
        let compact = try await waitForCommand(type: "compact", in: transport)
        let commandID = try XCTUnwrap(compact.id)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("compaction_start"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("compaction_end"),
            "errorMessage": .string("Compaction failed: Already compacted"),
            "aborted": .bool(false),
        ])))
        try await waitUntil {
            session.phase == .idle
                && session.conversation.last?.kind == .command
                && session.conversation.last?.status == .completed
        }

        XCTAssertNil(session.lastError)
        XCTAssertEqual(
            session.conversation.last?.detail,
            "当前会话已经压缩，无需重复操作"
        )

        // Pi RPC 还会为同一个 compact 请求返回 success=false；迟到的 response
        // 不能把已经处理的幂等结果重新变成 Runtime 错误。
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(commandID),
            "command": .string("compact"),
            "success": .bool(false),
            "error": .string("Already compacted"),
        ])))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(session.lastError)
        XCTAssertEqual(session.phase, .idle)
    }

    func testDiscoveredCommandExecutesWhileAgentIsBusyAndLeavesCommandActivity() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.piCommands = [PiRPCCommandInfo(
            name: "workpi-ui-demo",
            description: "演示面板",
            source: "extension"
        )]

        session.draftPrompt = "先执行一个普通任务"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "prompt" }.count == 1
        }

        session.submitCommand("/workpi-ui-demo")
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "prompt" }.count == 2
                && session.conversation.contains {
                    $0.kind == .command && $0.text == "/workpi-ui-demo"
                }
        }

        let prompts = await transport.sentCommands.filter { $0.type == "prompt" }
        let commandPrompt = try XCTUnwrap(prompts.last)
        let commandItem = try XCTUnwrap(
            session.conversation.first(where: {
                $0.kind == .command && $0.text == "/workpi-ui-demo"
            })
        )
        XCTAssertEqual(commandItem.status, .streaming)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": .string(commandPrompt.id ?? ""),
            "command": .string("prompt"),
            "success": .bool(true),
        ])))
        try await waitUntil {
            session.conversation.first(where: {
                $0.kind == .command && $0.text == "/workpi-ui-demo"
            })?.status == .completed
        }
        XCTAssertEqual(
            session.conversation.first(where: {
                $0.kind == .command && $0.text == "/workpi-ui-demo"
            })?.detail,
            "Pi 已接受命令"
        )
    }

    func testCommandsResponsePopulatesPickerWithoutChangingRuntimeError() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let commandsRequest = try await waitForCommand(
            type: "get_commands",
            in: transport
        )
        XCTAssertNotNil(commandsRequest.fields["id"]?.stringValue)
        session.lastError = "保留错误"
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("response"),
            "id": commandsRequest.fields["id"] ?? .null,
            "command": .string("get_commands"),
            "success": .bool(true),
            "data": .object([
                "commands": .array([
                    .object([
                        "name": .string("workpi-ui-demo"),
                        "description": .string("演示面板"),
                        "source": .string("extension"),
                    ]),
                ]),
            ]),
        ])))

        try await waitUntil {
            session.piCommands.map(\.name) == ["workpi-ui-demo"]
        }
        XCTAssertEqual(session.lastError, "保留错误")
        XCTAssertEqual(
            WorkPiCommandCatalog.items(piCommands: session.piCommands, language: .chinese)
                .first(where: { $0.name == "workpi-ui-demo" })?.description,
            "演示面板"
        )
    }

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        await emitHandshake(transport)
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }
    }

    private func emitHandshake(_ transport: FakePiRPCTransport) async {
        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
    }

    private func waitForCommand(
        type: String,
        in transport: FakePiRPCTransport
    ) async throws -> PiRPCCommand {
        try await waitUntil {
            await transport.sentCommands.contains(where: { $0.type == type })
        }
        let commands = await transport.sentCommands
        return try XCTUnwrap(commands.last(where: { $0.type == type }))
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
        XCTFail("Timed out waiting for WorkPi command/authorization state")
    }

    private static func stateRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "name": .string("Test Model"),
                    "contextWindow": .integer(100_000),
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
                    "contextWindow": .integer(100_000),
                    "percent": .integer(0),
                ]),
            ]),
        ])
    }
}

private final class CommandAuthorizationModeTransportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(PiRuntimeLaunchMode, FakePiRPCTransport)] = []

    func make(_ mode: PiRuntimeLaunchMode) -> any PiRPCTransport {
        let transport = FakePiRPCTransport()
        lock.lock()
        entries.append((mode, transport))
        lock.unlock()
        return transport
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func transport(at index: Int) -> FakePiRPCTransport? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(index) else { return nil }
        return entries[index].1
    }

    func mode(at index: Int) -> PiRuntimeLaunchMode? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(index) else { return nil }
        return entries[index].0
    }
}
