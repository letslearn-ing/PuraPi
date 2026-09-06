import Foundation
import PiDomain
import PiRPC

/// 历史消息的 UI 显示预算（display budget，限制界面一次渲染的数据量）。
///
/// 这只限制 WorkPi 的显示快照，不修改 Pi Session 文件，也不减少 Pi Runtime
/// 继续推理时使用的上下文。历史工具输出通常比普通回答大很多，必须在进入
/// SwiftUI 布局前截断，否则一个旧 Session 就可能让主线程长时间测量 CoreText。
struct PiSessionHistoryDisplayBudget: Sendable {
    /// 不再限制条目数量或总字符数：用户需要能一直往上翻找历史，
    /// 丢弃早期消息等于让内容消失。只对单条超长内容截断，因为一次几十万字符的
    /// 工具输出会让 CoreText 测量阻塞主线程，而那种内容用户也读不完——
    /// 截断的是单条体积，不是会话完整性。
    let maximumToolCharacters: Int
    let maximumAssistantCharacters: Int
    let maximumThinkingCharacters: Int
    let maximumSystemCharacters: Int
    let maximumUserCharacters: Int

    static let restoredSession = PiSessionHistoryDisplayBudget(
        // 单条上限放宽：原值（工具 1800、助手 7000）会把正常长度的回答也切掉。
        maximumToolCharacters: 12_000,
        maximumAssistantCharacters: 60_000,
        maximumThinkingCharacters: 30_000,
        maximumSystemCharacters: 20_000,
        maximumUserCharacters: 30_000
    )
}

/// 将 Pi `get_messages` 返回的 AgentMessage 快照映射为 WorkPi 的显示模型。
///
/// 这是只读显示适配器：它不写 Session、不改变 Runtime 上下文，也不把 Pi 的
/// 私有完整 Schema 泄漏到 `PiDomain`。未知 role/content block 会被安全忽略。
enum PiSessionHistoryMapper {
    static func conversation(
        from responseData: JSONValue?,
        budget: PiSessionHistoryDisplayBudget = .restoredSession
    ) -> [ConversationItem] {
        guard let messages = responseData?.value(at: "messages")?.arrayValue else { return [] }

        // 保留全部条目：会话必须完整可回溯。只对单条超长内容做截断。
        return messages.flatMap(messageItems).map { cap($0, budget: budget) }
    }

    private static func cap(
        _ item: ConversationItem,
        budget: PiSessionHistoryDisplayBudget
    ) -> ConversationItem {
        var result = item
        let limit: Int
        switch item.kind {
        case .tool:
            limit = budget.maximumToolCharacters
        case .assistant:
            limit = budget.maximumAssistantCharacters
        case .thinking:
            limit = budget.maximumThinkingCharacters
        case .command:
            limit = budget.maximumUserCharacters
        case .system, .error:
            limit = budget.maximumSystemCharacters
        case .user:
            limit = budget.maximumUserCharacters
        }
        result.text = truncate(item.text, to: limit)
        if let detail = item.detail {
            result.detail = truncate(detail, to: min(limit, 1_200))
        }
        return result
    }

    private static func truncate(_ value: String, to maximumCharacters: Int) -> String {
        guard maximumCharacters > 0, value.count > maximumCharacters else { return value }
        let end = value.index(value.startIndex, offsetBy: maximumCharacters)
        return String(value[..<end]) + "\n…（历史内容已截断）"
    }

    /// Pi 用毫秒时间戳；缺失时退回当前时间，不让界面显示 1970。
    private static func createdAt(_ message: JSONValue) -> Date {
        guard let millis = message["timestamp"]?.intValue else { return Date() }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    private static func messageItems(_ message: JSONValue) -> [ConversationItem] {
        guard let role = message["role"]?.stringValue else { return [] }
        switch role {
        case "user":
            let text = textContent(message["content"])
            return text.map {
                [ConversationItem(kind: .user, text: $0, createdAt: createdAt(message))]
            } ?? []
        case "assistant":
            return assistantItems(message)
        case "toolResult":
            let text = textContent(message["content"]) ?? ""
            return [ConversationItem(
                kind: .tool,
                title: message["toolName"]?.stringValue ?? "工具",
                text: text,
                status: message["isError"]?.boolValue == true ? .failed : .completed
            )]
        case "bashExecution":
            let command = message["command"]?.stringValue
            let output = message["output"]?.stringValue ?? ""
            return [ConversationItem(
                kind: .tool,
                title: "bash",
                text: output,
                detail: command,
                status: message["cancelled"]?.boolValue == true
                    ? .cancelled
                    : (message["exitCode"]?.intValue == 0 ? .completed : .failed)
            )]
        case "compactionSummary", "branchSummary":
            let summary = message["summary"]?.stringValue ?? ""
            return summary.isEmpty ? [] : [ConversationItem(kind: .system, text: summary)]
        default:
            return []
        }
    }

    private static func assistantItems(_ message: JSONValue) -> [ConversationItem] {
        guard let blocks = message["content"]?.arrayValue else { return [] }
        var result: [ConversationItem] = []
        var text = ""
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "thinking":
                if let thinking = block["thinking"]?.stringValue, !thinking.isEmpty {
                    result.append(ConversationItem(
                        kind: .thinking,
                        title: "Thinking",
                        text: thinking,
                        status: .completed
                    ))
                }
            default:
                break
            }
        }
        if !text.isEmpty {
            result.append(ConversationItem(kind: .assistant, text: text, status: .completed))
        }
        return result
    }

    private static func textContent(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue { return string }
        guard let blocks = value.arrayValue else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined()
        return text.isEmpty ? nil : text
    }
}
