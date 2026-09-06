import Foundation
import PiDomain

/// Pi RPC Extension UI（扩展交互）中的四种需要等待用户结果的对话方法。
public enum PiExtensionUIDialogMethod: String, Equatable, Sendable {
    case select
    case confirm
    case input
    case editor
}

/// 从 `extension_ui_request` 记录提取出的协议模型。
///
/// 这个模型只属于 PiRPC：它保留协议字段，并把 WorkPi 需要的扩展载荷映射为
/// PiDomain 的稳定快照；它不复制 Pi 的完整私有消息 schema。
///
/// WorkPi SubAgent 面板的结构化 widget 载荷。
///
/// Pi Extension UI 目前只提供字符串数组 widget，因此扩展把版本化 JSON 放在
/// 保留前缀后。解析失败时返回 nil，调用方应保留上一份有效快照。
public struct PiSubagentPanelPayload: Equatable, Sendable {
    public static let widgetKey = "workpi.subagent.panel"
    public static let linePrefix = "WORKPI_SUBAGENT_PANEL_V1 "

    public let sequence: Int64
    public let parentSessionID: String
    public let tasks: [SubagentTaskSnapshot]

    private struct WirePanel: Decodable {
        let version: Int
        let sequence: Int64
        let parentSessionId: String
        let tasks: [WireTask]
    }

    private struct WireTask: Decodable {
        let id: String
        let sessionFile: String
        let sessionRoot: String?
        let agent: String
        let task: String
        let status: String
        let model: String?
        let fallbackUsed: Bool?
        let detail: String?
        let outputPreview: String?
        let startedAt: Int64?
        let updatedAt: Int64?
        let step: Int?
    }

    public init?(widgetKey: String?, lines: [String]?) {
        guard widgetKey == Self.widgetKey,
              let line = lines?.first(where: { $0.hasPrefix(Self.linePrefix) })
        else { return nil }

        let rawJSON = String(line.dropFirst(Self.linePrefix.count))
        guard let data = rawJSON.data(using: .utf8),
              let wire = try? JSONDecoder().decode(WirePanel.self, from: data),
              wire.version == 1,
              !wire.parentSessionId.isEmpty
        else { return nil }

        var seen = Set<String>()
        let tasks = wire.tasks.compactMap { item -> SubagentTaskSnapshot? in
            guard !item.id.isEmpty,
                  !item.sessionFile.isEmpty,
                  !item.agent.isEmpty,
                  !item.task.isEmpty,
                  let status = SubagentTaskStatus(rawValue: item.status),
                  seen.insert(item.id).inserted
            else { return nil }
            return SubagentTaskSnapshot(
                id: item.id,
                sessionFilePath: item.sessionFile,
                agentName: item.agent,
                task: item.task,
                status: status,
                sessionRootPath: item.sessionRoot,
                model: item.model,
                fallbackUsed: item.fallbackUsed ?? false,
                detail: item.detail,
                outputPreview: item.outputPreview,
                startedAt: Self.date(milliseconds: item.startedAt),
                updatedAt: Self.date(milliseconds: item.updatedAt),
                step: item.step
            )
        }

        // 非空载荷若没有任何可验证任务，视为损坏而不是把有效面板清空；
        // 合法的空任务数组仍用于扩展主动清除/重置面板。
        guard wire.tasks.isEmpty || !tasks.isEmpty else { return nil }
        self.sequence = wire.sequence
        self.parentSessionID = wire.parentSessionId
        self.tasks = tasks
    }

    private static func date(milliseconds: Int64?) -> Date? {
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

public struct PiExtensionUIRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let method: String
    public let title: String?
    public let options: [String]
    public let message: String?
    public let placeholder: String?
    public let prefill: String?
    public let timeoutMilliseconds: Int?
    public let notifyType: String?
    public let statusKey: String?
    public let statusText: String?
    public let widgetKey: String?
    public let widgetLines: [String]?
    public let widgetPlacement: String?
    public let text: String?

    public var dialogMethod: PiExtensionUIDialogMethod? {
        PiExtensionUIDialogMethod(rawValue: method)
    }

    /// 仅对保留的 SubAgent widget key 解析结构化任务状态。
    public var subagentPanelPayload: PiSubagentPanelPayload? {
        PiSubagentPanelPayload(widgetKey: widgetKey, lines: widgetLines)
    }

    public init?(record: PiRPCRecord) {
        guard record.type == "extension_ui_request",
              let id = record.id,
              !id.isEmpty,
              let method = record.string(at: "method"),
              !method.isEmpty
        else { return nil }

        self.id = id
        self.method = method
        self.title = record.string(at: "title")
        self.options = record.value(at: "options")?.arrayValue?.compactMap(\.stringValue) ?? []
        self.message = record.string(at: "message")
        self.placeholder = record.string(at: "placeholder")
        self.prefill = record.string(at: "prefill")
        if let timeout = record.value(at: "timeout")?.intValue, timeout > 0 {
            self.timeoutMilliseconds = Int(timeout)
        } else {
            self.timeoutMilliseconds = nil
        }
        self.notifyType = record.string(at: "notifyType")
        self.statusKey = record.string(at: "statusKey")
        self.statusText = record.string(at: "statusText")
        self.widgetKey = record.string(at: "widgetKey")
        self.widgetLines = record.value(at: "widgetLines")?.arrayValue?.compactMap(\.stringValue)
        self.widgetPlacement = record.string(at: "widgetPlacement")
        self.text = record.string(at: "text")
    }
}

public extension PiRPCRecord {
    /// 只有带有合法 id 和 method 的 Extension UI 记录才会生成模型。
    var extensionUIRequest: PiExtensionUIRequest? {
        PiExtensionUIRequest(record: self)
    }
}
