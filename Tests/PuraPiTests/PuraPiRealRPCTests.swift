import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi
import WorkspaceKit

/// 显式开启后才运行真实 Pi 的 RPC 闭环。
@MainActor
final class PuraPiRealRPCTests: XCTestCase {
    func testRealPiRPC01ToolAndFileLoop() async throws {
        guard ProcessInfo.processInfo.environment["PURAPI_REAL_RPC_TEST"] == "1" else {
            throw XCTSkip("Set PURAPI_REAL_RPC_TEST=1 to run the real Pi integration test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-real-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: {
                PiRPCProcessTransport(
                    processArguments: [
                        "--mode", "rpc",
                        "--no-session",
                        "--no-extensions",
                        "--no-skills",
                        "--no-prompt-templates",
                    ],
                    environmentOverrides: ["PI_SKIP_VERSION_CHECK": "1"]
                )
            }
        )
        defer { session.closeWorkspace() }

        session.openWorkspace(root)
        try await waitUntil(timeout: 30) { session.runtimeStatus == "Pi Runtime 已连接" }
        session.draftPrompt = """
        In this empty temporary workspace, complete every step and use each named tool at least once:
        1. Use write to create rpc-smoke.txt containing alpha.
        2. Use edit to replace alpha with beta.
        3. Use read to verify rpc-smoke.txt.
        4. Use bash to verify the file content equals beta without changing files.
        Finally reply with exactly PURAPI_RPC_01_OK.
        """
        session.submitPrompt()
        try await waitUntil(timeout: 180) {
            session.phase == .idle || session.phase == .failed
        }

        XCTAssertNil(session.lastError)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("rpc-smoke.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "beta"
        )
        let toolNames = Set(
            session.conversation
                .filter { $0.kind == .tool }
                .compactMap(\.title)
        )
        XCTAssertTrue(Set(["write", "edit", "read", "bash"]).isSubset(of: toolNames))
        XCTAssertTrue(
            session.conversation.contains(where: {
                $0.kind == .assistant && $0.text.contains("PURAPI_RPC_01_OK")
            })
        )
        try await waitUntil(timeout: 5) {
            Self.tree(session.fileTree, contains: root.appendingPathComponent("rpc-smoke.txt"))
        }

        session.closeWorkspace()
        try await Task.sleep(for: .milliseconds(300))
    }

    func testRealPiRPC03SubagentCreatesPersistentChildAndPublishesPanel() async throws {
        guard ProcessInfo.processInfo.environment["PURAPI_REAL_RPC_TEST"] == "1" else {
            throw XCTSkip("Set PURAPI_REAL_RPC_TEST=1 to run the real Pi SubAgent integration test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-real-subagent-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: {
                PiRPCProcessTransport(
                    processArguments: [
                        "--mode", "rpc",
                        "--model", "openai-codex/gpt-5.6-sol",
                        "--thinking", "low",
                        "--tools", "read,bash,subagent",
                        "--no-context-files",
                        "--no-skills",
                    ],
                    environmentOverrides: [
                        "PI_SKIP_VERSION_CHECK": "1",
                        "PI_TELEMETRY": "0",
                        "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
                    ]
                )
            }
        )
        defer { session.closeWorkspace() }

        session.openWorkspace(root)
        try await waitUntil(timeout: 30) { session.runtimeStatus == "Pi Runtime 已连接" }
        session.draftPrompt = """
        必须使用 subagent 工具调用 worker，委派它只读检查当前目录的 marker.txt；不要自己执行这项检查，也不要修改任何文件。收到子 Agent 结果后核对并回复一行总结。
        """
        try "subagent-smoke".write(
            to: root.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        session.submitPrompt()

        try await waitUntil(timeout: 180) {
            session.phase == .idle && !session.subagentTasks.isEmpty
        }
        let task = try XCTUnwrap(session.subagentTasks.first)
        XCTAssertEqual(task.agentName, "worker")
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.model, "openai-codex/gpt-5.6-terra")
        XCTAssertEqual(task.sessionRootPath, sessionsRoot.path)
        XCTAssertFalse(task.fallbackUsed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.sessionFilePath))

        let childItems = PuraPiSubagentSessionReader.conversation(
            from: URL(fileURLWithPath: task.sessionFilePath),
            sessionsRoot: sessionsRoot
        )
        XCTAssertTrue(childItems.contains(where: { $0.kind == .assistant && $0.text.contains("subagent-smoke") }))

        session.closeWorkspace()
        try await Task.sleep(for: .milliseconds(300))
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for real Pi RPC state")
    }

    private static func tree(_ node: FileNode?, contains url: URL) -> Bool {
        guard let node else { return false }
        let target = url.standardizedFileURL
        if node.url == target { return true }
        return node.children?.contains(where: { tree($0, contains: target) }) == true
    }
}
