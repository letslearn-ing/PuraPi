import Foundation
import PiDomain
import XCTest
@testable import WorkspaceKit

/// 会话文件的扫描与轮次解析。
///
/// 全部用例使用临时目录构造的会话文件，不依赖本机真实会话。
final class PiSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 目录名规则必须与上游一致：cwd 已以 / 开头，不能重复补前导 -。
    func testDirectoryNameMatchesUpstreamLayout() {
        XCTAssertEqual(
            PiSessionStore.directoryName(for: "/Users/limiao/work/PC/researchDSH"),
            "--Users-limiao-work-PC-researchDSH--"
        )
    }

    func testListSessionsSortsByModificationDescending() throws {
        let workspace = URL(fileURLWithPath: "/tmp/project-a")
        let store = PiSessionStore(sessionsRoot: root)
        let directory = store.sessionsDirectory(for: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try write(
            session: "old",
            cwd: "/tmp/project-a",
            lines: [userMessage(id: "a1", parent: nil, text: "旧会话")],
            to: directory.appendingPathComponent("old.jsonl"),
            modified: Date(timeIntervalSince1970: 1_000)
        )
        try write(
            session: "new",
            cwd: "/tmp/project-a",
            lines: [userMessage(id: "b1", parent: nil, text: "新会话")],
            to: directory.appendingPathComponent("new.jsonl"),
            modified: Date(timeIntervalSince1970: 9_000)
        )

        let sessions = store.listSessions(for: workspace)
        XCTAssertEqual(sessions.map(\.sessionID), ["new", "old"])
    }

    /// 名字取最后一条 session_info；空字符串表示显式清除标题。
    func testCollidingDirectoryNamesCannotMixWorkspaceSessions() throws {
        let workspaceA = root.appendingPathComponent("a-b", isDirectory: true)
        let workspaceB = root.appendingPathComponent("a/b", isDirectory: true)
        let store = PiSessionStore(sessionsRoot: root)
        let directory = store.sessionsDirectory(for: workspaceA)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try write(
            session: "only-a",
            cwd: workspaceA.path,
            lines: [userMessage(id: "a1", parent: nil, text: "A")],
            to: directory.appendingPathComponent("a.jsonl")
        )
        try write(
            session: "only-b",
            cwd: workspaceB.path,
            lines: [userMessage(id: "b1", parent: nil, text: "B")],
            to: directory.appendingPathComponent("b.jsonl")
        )

        XCTAssertEqual(store.listSessions(for: workspaceA).map(\.sessionID), ["only-a"])
        XCTAssertEqual(store.listSessions(for: workspaceB).map(\.sessionID), ["only-b"])
    }

    func testSessionNameUsesLatestSessionInfoAndEmptyClearsIt() throws {
        let workspace = URL(fileURLWithPath: "/tmp/project-b")
        let store = PiSessionStore(sessionsRoot: root)
        let directory = store.sessionsDirectory(for: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let named = directory.appendingPathComponent("named.jsonl")
        try write(
            session: "named",
            cwd: "/tmp/project-b",
            lines: [
                sessionInfo(id: "i1", parent: nil, name: "第一个名字"),
                userMessage(id: "m1", parent: "i1", text: "问题"),
                sessionInfo(id: "i2", parent: "m1", name: "最终名字"),
            ],
            to: named
        )
        let cleared = directory.appendingPathComponent("cleared.jsonl")
        try write(
            session: "cleared",
            cwd: "/tmp/project-b",
            lines: [
                sessionInfo(id: "i1", parent: nil, name: "临时名字"),
                sessionInfo(id: "i2", parent: "i1", name: "   "),
            ],
            to: cleared
        )

        XCTAssertEqual(store.summary(of: named)?.name, "最终名字")
        XCTAssertNil(store.summary(of: cleared)?.name)
    }

    func testSummaryCapturesParentSessionAndFirstUserText() throws {
        let file = root.appendingPathComponent("forked.jsonl")
        try write(
            session: "forked",
            cwd: "/tmp/project-c",
            parentSession: "/tmp/original.jsonl",
            lines: [
                userMessage(id: "m1", parent: nil, text: "第一句\n第二句"),
                assistantMessage(id: "m2", parent: "m1", text: "回答"),
            ],
            to: file
        )

        let summary = try XCTUnwrap(PiSessionStore(sessionsRoot: root).summary(of: file))
        XCTAssertEqual(summary.parentSessionPath, "/tmp/original.jsonl")
        // 预览压成一行，便于列表显示。
        XCTAssertEqual(summary.firstUserText, "第一句 第二句")
        XCTAssertEqual(summary.messageCount, 2)
    }

    /// 标题回退顺序：名字 → 首条用户消息 → 创建时间。
    func testDisplayTitleFallbackOrder() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let created = Date(timeIntervalSince1970: 0)

        let named = PiSessionSummary(
            fileURL: URL(fileURLWithPath: "/tmp/a.jsonl"),
            sessionID: "a", createdAt: created, modifiedAt: created,
            cwd: "/tmp", name: "我的名字", firstUserText: "首句"
        )
        XCTAssertEqual(named.displayTitle(dateFormatter: formatter), "我的名字")

        let unnamed = PiSessionSummary(
            fileURL: URL(fileURLWithPath: "/tmp/b.jsonl"),
            sessionID: "b", createdAt: created, modifiedAt: created,
            cwd: "/tmp", name: nil, firstUserText: "首句"
        )
        XCTAssertEqual(unnamed.displayTitle(dateFormatter: formatter), "首句")

        let bare = PiSessionSummary(
            fileURL: URL(fileURLWithPath: "/tmp/c.jsonl"),
            sessionID: "c", createdAt: created, modifiedAt: created, cwd: "/tmp"
        )
        XCTAssertEqual(
            bare.displayTitle(dateFormatter: formatter),
            formatter.string(from: created)
        )
    }

    func testTurnsCountResponsesPerUserTurn() throws {
        let file = root.appendingPathComponent("turns.jsonl")
        try write(
            session: "turns",
            cwd: "/tmp/project-d",
            lines: [
                userMessage(id: "u1", parent: nil, text: "第一问"),
                assistantMessage(id: "a1", parent: "u1", text: "答一"),
                toolResult(id: "t1", parent: "a1"),
                userMessage(id: "u2", parent: "t1", text: "第二问"),
                assistantMessage(id: "a2", parent: "u2", text: "答二"),
            ],
            to: file
        )

        let turns = PiSessionTurnParser.turns(in: file)
        XCTAssertEqual(turns.map(\.text), ["第一问", "第二问"])
        XCTAssertEqual(turns.map(\.responseCount), [2, 1])
        XCTAssertTrue(turns.allSatisfy(\.isOnActiveBranch))
    }

    /// fork 在同一文件里留下废弃分支；只有回溯到最后 entry 的路径才是活动分支。
    func testForkedBranchIsMarkedInactive() throws {
        let file = root.appendingPathComponent("forked-tree.jsonl")
        try write(
            session: "forked-tree",
            cwd: "/tmp/project-e",
            lines: [
                userMessage(id: "u1", parent: nil, text: "共同起点"),
                assistantMessage(id: "a1", parent: "u1", text: "答"),
                // 被抛弃的分支
                userMessage(id: "u2", parent: "a1", text: "废弃分支的提问"),
                assistantMessage(id: "a2", parent: "u2", text: "废弃回答"),
                // fork 后的新分支：同样挂在 a1 下
                userMessage(id: "u3", parent: "a1", text: "重新提问"),
                assistantMessage(id: "a3", parent: "u3", text: "新回答"),
            ],
            to: file
        )

        let turns = PiSessionTurnParser.turns(in: file)
        let byText = Dictionary(uniqueKeysWithValues: turns.map { ($0.text, $0) })
        XCTAssertEqual(byText["共同起点"]?.isOnActiveBranch, true)
        XCTAssertEqual(byText["重新提问"]?.isOnActiveBranch, true)
        XCTAssertEqual(byText["废弃分支的提问"]?.isOnActiveBranch, false)
    }

    func testMalformedLinesAreSkippedWithoutFailingWholeFile() throws {
        let file = root.appendingPathComponent("broken.jsonl")
        let content = [
            header(session: "broken", cwd: "/tmp/project-f"),
            "{ this is not json",
            userMessage(id: "u1", parent: nil, text: "仍然可读"),
        ].joined(separator: "\n") + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let summary = PiSessionStore(sessionsRoot: root).summary(of: file)
        XCTAssertEqual(summary?.firstUserText, "仍然可读")
    }

    // MARK: - 构造辅助

    private func header(session: String, cwd: String, parentSession: String? = nil) -> String {
        var object: [String: Any] = [
            "type": "session",
            "version": 3,
            "id": session,
            "timestamp": "2026-08-21T12:00:00.000Z",
            "cwd": cwd,
        ]
        if let parentSession { object["parentSession"] = parentSession }
        return json(object)
    }

    private func userMessage(id: String, parent: String?, text: String) -> String {
        json([
            "type": "message", "id": id, "parentId": parent as Any,
            "timestamp": "2026-08-21T12:00:01.000Z",
            "message": ["role": "user", "content": text],
        ])
    }

    private func assistantMessage(id: String, parent: String?, text: String) -> String {
        json([
            "type": "message", "id": id, "parentId": parent as Any,
            "timestamp": "2026-08-21T12:00:02.000Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ])
    }

    private func toolResult(id: String, parent: String?) -> String {
        json([
            "type": "message", "id": id, "parentId": parent as Any,
            "timestamp": "2026-08-21T12:00:03.000Z",
            "message": ["role": "toolResult", "toolName": "bash", "content": []],
        ])
    }

    private func sessionInfo(id: String, parent: String?, name: String) -> String {
        json([
            "type": "session_info", "id": id, "parentId": parent as Any,
            "timestamp": "2026-08-21T12:00:04.000Z", "name": name,
        ])
    }

    private func json(_ object: [String: Any]) -> String {
        let sanitized = object.mapValues { $0 is NSNull ? NSNull() : $0 }
        let data = try! JSONSerialization.data(withJSONObject: sanitized)
        return String(data: data, encoding: .utf8)!
    }

    private func write(
        session: String,
        cwd: String,
        parentSession: String? = nil,
        lines: [String],
        to url: URL,
        modified: Date? = nil
    ) throws {
        let content = ([header(session: session, cwd: cwd, parentSession: parentSession)] + lines)
            .joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
        }
    }
}
