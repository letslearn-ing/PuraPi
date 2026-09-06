import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi

@MainActor
final class WorkPiSubagentTests: XCTestCase {
    func testSubagentPanelPayloadParsesTasksAndDates() throws {
        let record = panelRecord(
            sequence: 7,
            tasks: [
                [
                    "id": "child-1",
                    "sessionFile": "/tmp/sessions/child-1.jsonl",
                    "agent": "scout",
                    "task": "检查认证代码",
                    "status": "running",
                    "model": "openai-codex/gpt-5.6-terra",
                    "fallbackUsed": false,
                    "detail": "正在执行 grep",
                    "outputPreview": "已找到认证入口",
                    "startedAt": 1_700_000_000_000,
                    "updatedAt": 1_700_000_001_000,
                    "step": 1,
                ],
            ]
        )

        let request = try XCTUnwrap(record.extensionUIRequest)
        let payload = try XCTUnwrap(request.subagentPanelPayload)
        let task = try XCTUnwrap(payload.tasks.first)

        XCTAssertEqual(payload.sequence, 7)
        XCTAssertEqual(payload.parentSessionID, "parent-1")
        XCTAssertEqual(task.id, "child-1")
        XCTAssertEqual(task.agentName, "scout")
        XCTAssertEqual(task.status, .running)
        XCTAssertEqual(task.model, "openai-codex/gpt-5.6-terra")
        XCTAssertNil(task.sessionRootPath)
        XCTAssertEqual(task.step, 1)
        XCTAssertEqual(task.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testStaleSubagentPanelPayloadCannotOverwriteNewerState() throws {
        let session = PiSessionController()
        let newer = try XCTUnwrap(
            panelRecord(sequence: 3, tasks: [[
                "id": "new",
                "sessionFile": "/tmp/sessions/new.jsonl",
                "agent": "worker",
                "task": "新任务",
                "status": "completed",
            ]]).extensionUIRequest
        )
        let older = try XCTUnwrap(
            panelRecord(sequence: 2, tasks: [[
                "id": "old",
                "sessionFile": "/tmp/sessions/old.jsonl",
                "agent": "scout",
                "task": "旧任务",
                "status": "running",
            ]]).extensionUIRequest
        )

        XCTAssertTrue(session.consumeSubagentPanelRequest(newer))
        XCTAssertTrue(session.consumeSubagentPanelRequest(older))
        XCTAssertEqual(session.subagentTasks.map(\.id), ["new"])
    }

    func testMalformedSubagentPanelKeepsLastValidSnapshotAndClearRemovesIt() throws {
        let session = PiSessionController()
        let valid = try XCTUnwrap(
            panelRecord(sequence: 1, tasks: [[
                "id": "child",
                "sessionFile": "/tmp/sessions/child.jsonl",
                "agent": "worker",
                "task": "有效任务",
                "status": "queued",
            ]]).extensionUIRequest
        )
        let malformed = PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("malformed"),
            "method": .string("setWidget"),
            "widgetKey": .string(PiSubagentPanelPayload.widgetKey),
            "widgetLines": .array([.string("不是合法载荷")]),
        ])
        let clear = PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("clear"),
            "method": .string("setWidget"),
            "widgetKey": .string(PiSubagentPanelPayload.widgetKey),
        ])

        XCTAssertTrue(session.consumeSubagentPanelRequest(valid))
        XCTAssertTrue(session.consumeSubagentPanelRequest(try XCTUnwrap(malformed.extensionUIRequest)))
        XCTAssertEqual(session.subagentTasks.map(\.id), ["child"])
        XCTAssertTrue(session.consumeSubagentPanelRequest(try XCTUnwrap(clear.extensionUIRequest)))
        XCTAssertTrue(session.subagentTasks.isEmpty)
    }

    func testOpeningSubagentTaskSelectsReadOnlyViewerWithoutChangingRuntime() {
        let session = PiSessionController()
        let task = SubagentTaskSnapshot(
            id: "child",
            sessionFilePath: "/tmp/sessions/child.jsonl",
            agentName: "worker",
            task: "查看子会话",
            status: .running,
            sessionRootPath: "/tmp/sessions"
        )

        session.openSubagentTask(task)

        XCTAssertEqual(session.selectedSubagentTask, task)
        XCTAssertNil(session.transport)
        XCTAssertFalse(session.isAgentBusy)
    }

    func testSubagentSessionReaderMapsPersistedMessages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-subagent-reader-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = sessionsRoot.appendingPathComponent("child.jsonl")
        let content = #"""
        {"type":"session","version":3,"id":"child","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"检查文件","timestamp":1700000001000}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"已检查"}],"stopReason":"stop","timestamp":1700000002000}}
        {"type":"message","id":"broken","parentId":"a1","timestamp":""}
        """#
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        .joined(separator: "\n") + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let items = WorkPiSubagentSessionReader.conversation(
            from: file,
            sessionsRoot: sessionsRoot
        )

        XCTAssertEqual(items.map(\.kind), [.user, .assistant])
        XCTAssertEqual(items.map(\.text), ["检查文件", "已检查"])
    }

    func testSubagentSessionReaderRejectsPathOutsideSessionRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-subagent-reader-boundary-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside.jsonl")
        try "not a session".write(to: outside, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            WorkPiSubagentSessionReader.conversation(
                from: outside,
                sessionsRoot: sessionsRoot
            ).isEmpty
        )
    }

    private func panelRecord(
        sequence: Int,
        tasks: [[String: Any]]
    ) -> PiRPCRecord {
        let object: [String: Any] = [
            "version": 1,
            "sequence": sequence,
            "parentSessionId": "parent-1",
            "tasks": tasks,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        let line = PiSubagentPanelPayload.linePrefix + String(decoding: data, as: UTF8.self)
        return PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("panel-\(sequence)"),
            "method": .string("setWidget"),
            "widgetKey": .string(PiSubagentPanelPayload.widgetKey),
            "widgetLines": .array([.string(line)]),
        ])
    }
}
