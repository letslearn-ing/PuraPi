import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import PuraPi

/// `/status` 统计与对话内搜索。
@MainActor
final class PuraPiStatsSearchTests: XCTestCase {
    // MARK: - 统计解析

    /// 字段形状取自真实 Pi 0.84.1 的 `get_session_stats` 响应。
    func testSessionStatsParsing() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "id": .string("s1"),
            "success": .bool(true),
            "data": .object([
                "sessionId": .string("abc123"),
                "userMessages": .integer(5),
                "assistantMessages": .integer(5),
                "toolCalls": .integer(12),
                "toolResults": .integer(12),
                "totalMessages": .integer(22),
                "tokens": .object([
                    "input": .integer(50_000),
                    "output": .integer(10_000),
                    "cacheRead": .integer(40_000),
                    "cacheWrite": .integer(5_000),
                    "total": .integer(105_000),
                ]),
                "cost": .number(0.45),
                "contextUsage": .object([
                    "tokens": .integer(60_000),
                    "contextWindow": .integer(200_000),
                    "percent": .integer(30),
                ]),
            ]),
        ])

        let stats = try? XCTUnwrap(record.sessionStats)
        XCTAssertEqual(stats?.sessionID, "abc123")
        XCTAssertEqual(stats?.totalTokens, 105_000)
        XCTAssertEqual(stats?.cost ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(stats?.contextPercent ?? 0, 30, accuracy: 0.01)
    }

    /// 压缩刚结束时 Pi 把 tokens/percent 报成 null，不能崩也不能当成 0。
    func testNullContextUsageAfterCompaction() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
            "data": .object([
                "tokens": .object(["total": .integer(1_000)]),
                "cost": .number(0),
                "contextUsage": .object([
                    "tokens": .null,
                    "contextWindow": .integer(200_000),
                    "percent": .null,
                ]),
            ]),
        ])
        let stats = try? XCTUnwrap(record.sessionStats)
        XCTAssertNil(stats?.contextTokens)
        XCTAssertNil(stats?.contextPercent)
        XCTAssertEqual(stats?.contextWindow, 200_000)
    }

    /// 缓存命中率解释「为什么这次花了这么多钱」。
    func testCacheHitRatio() {
        let stats = PiSessionStats(inputTokens: 10_000, cacheReadTokens: 40_000)
        XCTAssertEqual(stats.cacheHitRatio ?? 0, 0.8, accuracy: 0.001)
        // 全新会话没有任何输入时不该返回 0%，那会误导成"缓存完全没命中"。
        XCTAssertNil(PiSessionStats().cacheHitRatio)
    }

    /// HUD 的上下文刷新也用 get_session_stats，不能被 /status 拦截。
    func testUnrelatedStatsResponseIsNotConsumed() {
        let session = PiSessionController()
        session.activeStatsCommandID = "mine"
        let consumed = session.consumeSessionStatsResponse(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "id": .string("someone-else"),
            "success": .bool(true),
        ]))
        XCTAssertFalse(consumed)
        XCTAssertEqual(session.activeStatsCommandID, "mine")
    }

    func testStatusCommandIsRegistered() {
        XCTAssertEqual(PuraPiCommandCatalog.action(for: "/status"), .status)
    }

    // MARK: - 对话内搜索

    private func makeItems() -> [ConversationItem] {
        [
            ConversationItem(kind: .user, text: "如何配置 Swift 包"),
            ConversationItem(kind: .assistant, text: "用 Package.swift 描述依赖"),
            ConversationItem(kind: .tool, text: "swift build 输出"),
            ConversationItem(kind: .assistant, text: "完成"),
        ]
    }

    func testSearchMatchesAreCaseInsensitive() {
        let state = PuraPiConversationSearchState()
        state.query = "SWIFT"
        state.update(items: makeItems())
        XCTAssertEqual(state.matches.count, 3)
        XCTAssertEqual(state.matchSummary, "1/3")
    }

    func testEmptyQueryClearsMatches() {
        let state = PuraPiConversationSearchState()
        state.query = "swift"
        state.update(items: makeItems())
        state.query = "   "
        state.update(items: makeItems())
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertEqual(state.matchSummary, "")
    }

    func testNavigationWrapsAround() {
        let state = PuraPiConversationSearchState()
        state.query = "swift"
        state.update(items: makeItems())

        state.moveToNext()
        XCTAssertEqual(state.matchSummary, "2/3")
        state.moveToNext()
        state.moveToNext()
        // 循环回到第一条，而不是停在末尾。
        XCTAssertEqual(state.matchSummary, "1/3")
        state.moveToPrevious()
        XCTAssertEqual(state.matchSummary, "3/3")
    }

    /// 输入过程中命中集合会变，应尽量保持当前位置而不是跳回第一条。
    func testCurrentMatchIsPreservedWhenStillPresent() {
        let state = PuraPiConversationSearchState()
        let items = makeItems()
        state.query = "swift"
        state.update(items: items)
        state.moveToNext()
        let current = state.currentMatch

        state.update(items: items)
        XCTAssertEqual(state.currentMatch, current)
    }

    func testDismissResetsEverything() {
        let state = PuraPiConversationSearchState()
        state.isPresented = true
        state.query = "swift"
        state.update(items: makeItems())

        state.dismiss()

        XCTAssertFalse(state.isPresented)
        XCTAssertTrue(state.query.isEmpty)
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertNil(state.currentMatch)
    }
}
