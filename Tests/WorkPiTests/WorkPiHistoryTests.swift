import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi

/// 历史映射：完整性与成本。
@MainActor
final class WorkPiHistoryTests: XCTestCase {
    /// 会话必须完整保留，用户要能一直往上翻。
    func testAllMessagesArePreserved() {
        let count = 400
        var messages: [JSONValue] = []
        for index in 0..<count {
            let role: String = index % 2 == 0 ? "user" : "assistant"
            let timestamp: Int64 = 1_733_234_567_890 + Int64(index)
            let content: JSONValue = role == "user"
                ? .string("消息 \(index)")
                : .array([.object(["type": .string("text"), "text": .string("消息 \(index)")])])
            let fields: [String: JSONValue] = [
                "role": .string(role),
                "content": content,
                "timestamp": .integer(timestamp),
            ]
            messages.append(.object(fields))
        }
        let items = PiSessionHistoryMapper.conversation(
            from: .object(["messages": .array(messages)])
        )

        // 助手消息可能拆成多条（文本/工具），因此只断言不少于原始条数。
        XCTAssertGreaterThanOrEqual(items.count, count)
        // 首条必须还在——原先会被条目上限丢弃。
        XCTAssertTrue(items.first?.text.contains("消息 0") ?? false)
        XCTAssertTrue(items.contains { $0.text.contains("消息 399") })
        // 不应再插入「仅显示最近部分」的提示。
        XCTAssertFalse(items.contains { $0.text.contains("仅显示最近部分") })
    }

    /// 单条超长内容仍要截断：一次几十万字符会让 CoreText 阻塞主线程。
    func testOversizedSingleMessageIsTruncated() {
        let huge = String(repeating: "A", count: 200_000)
        let items = PiSessionHistoryMapper.conversation(
            from: .object([
                "messages": .array([
                    .object(["role": .string("user"), "content": .string(huge)]),
                ]),
            ])
        )
        let user = try? XCTUnwrap(items.first)
        XCTAssertLessThan(user?.text.count ?? .max, huge.count)
    }

    /// 大会话的映射必须在后台可接受的时间内完成。
    func testLargeSessionMappingCost() {
        var messages: [JSONValue] = []
        let body = String(repeating: "内容", count: 60)
        for index in 0..<2_000 {
            let role: String = index % 2 == 0 ? "user" : "assistant"
            let content: JSONValue = role == "user"
                ? .string(body)
                : .array([.object(["type": .string("text"), "text": .string(body)])])
            let fields: [String: JSONValue] = [
                "role": .string(role),
                "content": content,
            ]
            messages.append(.object(fields))
        }
        let payload = JSONValue.object(["messages": .array(messages)])

        let start = Date()
        let items = PiSessionHistoryMapper.conversation(from: payload)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(items.count, 2_000)
        print("HISTORY COST items=\(items.count) ms=\(String(format: "%.1f", elapsed * 1000))")
        // 映射在后台线程执行；留出宽裕上限，只用于捕捉数量级退化。
        XCTAssertLessThan(elapsed, 3.0)
    }
}
