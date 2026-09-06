import Foundation
import PiDomain

public struct PiRPCCommand: Encodable, Equatable, Sendable {
    public let fields: [String: JSONValue]
    /// Local, non-wire identity for the immutable send ticket. RPC ids can be
    /// reused by a caller, while this value remains unique for each command
    /// instance and therefore cannot be retargeted by a later registration.
    public let runtimeTicketID: UUID

    public var type: String { fields["type"]?.stringValue ?? "" }
    public var id: String? { fields["id"]?.stringValue }

    public init(fields: [String: JSONValue]) {
        self.fields = fields
        self.runtimeTicketID = UUID()
    }

    public static func == (lhs: PiRPCCommand, rhs: PiRPCCommand) -> Bool {
        lhs.fields == rhs.fields
    }

    public static func prompt(
        _ message: String,
        id: String = UUID().uuidString,
        streamingBehavior: String? = nil,
        images: [PiPromptImage] = []
    ) -> PiRPCCommand {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("prompt"),
            "message": .string(message),
        ]
        if let streamingBehavior {
            fields["streamingBehavior"] = .string(streamingBehavior)
        }
        if !images.isEmpty {
            fields["images"] = .array(images.map(\.jsonValue))
        }
        return PiRPCCommand(fields: fields)
    }

    public static func steer(
        _ message: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("steer"),
            "message": .string(message),
        ])
    }

    public static func followUp(
        _ message: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("follow_up"),
            "message": .string(message),
        ])
    }

    public static func abort(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("abort")])
    }

    public static func compact(
        customInstructions: String? = nil,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("compact"),
        ]
        if let customInstructions {
            fields["customInstructions"] = .string(customInstructions)
        }
        return PiRPCCommand(fields: fields)
    }

    public static func setAutoCompaction(
        enabled: Bool,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("set_auto_compaction"),
            "enabled": .bool(enabled),
        ])
    }

    public static func setAutoRetry(
        enabled: Bool,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("set_auto_retry"),
            "enabled": .bool(enabled),
        ])
    }

    public static func abortRetry(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("abort_retry")])
    }

    public static func bash(
        _ command: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("bash"),
            "command": .string(command),
        ])
    }

    /// 回应 Pi Extension UI（扩展界面）请求。对话型请求可传 value/confirmed，
    /// 用户取消时传 cancelled=true。请求 id 必须原样回传。
    public static func extensionUIResponse(
        requestID: String,
        value: String? = nil,
        confirmed: Bool? = nil,
        cancelled: Bool = false
    ) -> PiRPCCommand {
        var fields: [String: JSONValue] = [
            "id": .string(requestID),
            "type": .string("extension_ui_response"),
        ]
        if let value {
            fields["value"] = .string(value)
        }
        if let confirmed {
            fields["confirmed"] = .bool(confirmed)
        }
        if cancelled {
            fields["cancelled"] = .bool(true)
        }
        return PiRPCCommand(fields: fields)
    }

    public static func getState(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("get_state")])
    }

    public static func getMessages(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("get_messages")])
    }

    public static func getSessionStats(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("get_session_stats")])
    }

    public static func getCommands(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("get_commands")])
    }

    /// 切到指定模型。`provider` 和 `modelId` 必须成对使用，
    /// 因为同一个 `modelId` 可能存在于多个 provider。
    public static func setModel(
        provider: String,
        modelID: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("set_model"),
            "provider": .string(provider),
            "modelId": .string(modelID),
        ])
    }

    public static func cycleModel(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("cycle_model")])
    }

    public static func getAvailableModels(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("get_available_models")])
    }

    /// 设置推理强度。可用级别随模型变化，必须先读
    /// `get_available_thinking_levels`，不要在客户端写死全集。
    public static func setThinkingLevel(
        _ level: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("set_thinking_level"),
            "level": .string(level),
        ])
    }

    public static func cycleThinkingLevel(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("cycle_thinking_level")])
    }

    public static func getAvailableThinkingLevels(
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("get_available_thinking_levels"),
        ])
    }

    /// 控制 follow-up 消息的交付方式。
    ///
    /// `one-at-a-time`（Pi 默认）每次 Agent 完成只交付一条；`all` 一次全交。
    public static func setFollowUpMode(
        _ mode: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("set_follow_up_mode"),
            "mode": .string(mode),
        ])
    }

    public static func setSteeringMode(
        _ mode: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("set_steering_mode"),
            "mode": .string(mode),
        ])
    }

    /// 从活动分支上的某条用户消息分叉。
    ///
    /// 在同一会话文件内改变活动分支，不新建文件；旧分支仍保留在树里。
    public static func fork(
        entryID: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("fork"),
            "entryId": .string(entryID),
        ])
    }

    /// 把当前活动分支复制到一个新会话文件。
    public static func clone(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("clone")])
    }

    /// 可用于 fork 的用户消息列表。
    public static func getForkMessages(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("get_fork_messages")])
    }

    /// 会话条目树。返回 `{entry, children}` 嵌套结构与 `leafId`。
    public static func getTree(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("get_tree")])
    }

    /// 按追加顺序取会话条目。`since` 传入已看过的最后一个 entry id
    /// 可做增量拉取；与 `get_messages` 不同，它包含压缩前历史与废弃分支。
    public static func getEntries(
        since: String? = nil,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("get_entries"),
        ]
        if let since, !since.isEmpty {
            fields["since"] = .string(since)
        }
        return PiRPCCommand(fields: fields)
    }

    /// 把当前会话导出为自包含的 HTML 文件。
    ///
    /// 只能导出 Pi 当前会话，协议没有 session 参数；因此入口必须放在
    /// 「当前对话」语境里，否则用户无法判断导出的是哪个会话。
    /// 不传 `outputPath` 时由 Pi 决定默认位置，响应里回传实际路径。
    public static func exportHTML(
        outputPath: String? = nil,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("export_html"),
        ]
        if let outputPath {
            fields["outputPath"] = .string(outputPath)
        }
        return PiRPCCommand(fields: fields)
    }

    /// 设置会话显示名。当前 Pi RPC 版本要求名称非空；调用方应在发送前校验。
    public static func setSessionName(
        _ name: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("set_session_name"),
            "name": .string(name),
        ])
    }

    public static func switchSession(
        sessionPath: String,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        PiRPCCommand(fields: [
            "id": .string(id),
            "type": .string("switch_session"),
            "sessionPath": .string(sessionPath),
        ])
    }

    public static func newSession(
        parentSession: String? = nil,
        id: String = UUID().uuidString
    ) -> PiRPCCommand {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("new_session"),
        ]
        if let parentSession {
            fields["parentSession"] = .string(parentSession)
        }
        return PiRPCCommand(fields: fields)
    }

    public static func abortBash(id: String = UUID().uuidString) -> PiRPCCommand {
        PiRPCCommand(fields: ["id": .string(id), "type": .string("abort_bash")])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }

    public func jsonLine(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

/// Pi 可用模型的最小标识。
///
/// 只保留 WorkPi 选择器需要的字段；`provider` 与 `id` 共同构成唯一键，
/// 因为同一模型 id 可能同时出现在多个 provider 下。
public struct PiRPCModelInfo: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let reasoning: Bool
    public let contextWindow: Int64?

    /// 选择器使用的稳定唯一键。
    public var selectionKey: String { "\(provider)/\(id)" }

    public init(
        id: String,
        name: String,
        provider: String,
        reasoning: Bool = false,
        contextWindow: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.reasoning = reasoning
        self.contextWindow = contextWindow
    }

    /// 从 Pi 的 `Model` 对象解析。缺少 `id` 或 `provider` 的条目不可用于切模型，
    /// 因此直接丢弃而不是编造占位值。
    public init?(json: JSONValue?) {
        guard let object = json?.objectValue,
              let id = object["id"]?.stringValue,
              !id.isEmpty,
              let provider = object["provider"]?.stringValue,
              !provider.isEmpty
        else { return nil }

        self.id = id
        self.provider = provider
        let name = object["name"]?.stringValue
        self.name = (name?.isEmpty == false ? name : nil) ?? id
        self.reasoning = object["reasoning"]?.boolValue ?? false
        self.contextWindow = object["contextWindow"]?.intValue
    }
}

/// 从 Pi stdout 解出的单条 JSONL 记录。未知字段和未知事件会被完整保留。
public struct PiRPCCommandInfo: Equatable, Identifiable, Sendable {
    public let name: String
    public let description: String?
    public let source: String

    public var id: String { name }

    public init(name: String, description: String? = nil, source: String = "unknown") {
        self.name = name.hasPrefix("/") ? String(name.dropFirst()) : name
        self.description = description
        self.source = source
    }
}

public struct PiRPCRecord: Decodable, Equatable, Sendable {
    public let fields: [String: JSONValue]

    public var type: String { fields["type"]?.stringValue ?? "unknown" }
    public var id: String? { fields["id"]?.stringValue }
    public var command: String? { fields["command"]?.stringValue }
    public var success: Bool? { fields["success"]?.boolValue }

    /// `response.data` 的通用载荷，供上层按命令读取状态字段。
    public var responseData: JSONValue? { value(at: "data") }

    public var commandInfos: [PiRPCCommandInfo]? {
        guard command == "get_commands",
              success == true,
              let values = value(at: "data", "commands")?.arrayValue
        else { return nil }

        return values.compactMap { value in
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue,
                  !name.isEmpty
            else { return nil }
            return PiRPCCommandInfo(
                name: name,
                description: object["description"]?.stringValue,
                source: object["source"]?.stringValue ?? "unknown"
            )
        }
    }

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.fields = try container.decode([String: JSONValue].self)
    }

    public func value(at path: String...) -> JSONValue? {
        value(at: path)
    }

    public func value(at path: [String]) -> JSONValue? {
        guard let first = path.first else { return .object(fields) }
        return path.dropFirst().reduce(fields[first]) { current, key in
            current?[key]
        }
    }

    public func string(at path: String...) -> String? {
        value(at: path)?.stringValue
    }

    public func bool(at path: String...) -> Bool? {
        value(at: path)?.boolValue
    }

    public var textDelta: String? {
        guard type == "message_update",
              string(at: "assistantMessageEvent", "type") == "text_delta"
        else { return nil }
        return string(at: "assistantMessageEvent", "delta")
    }

    public var thinkingDelta: String? {
        guard type == "message_update",
              string(at: "assistantMessageEvent", "type") == "thinking_delta"
        else { return nil }
        return string(at: "assistantMessageEvent", "delta")
    }

    public var messageRole: String? {
        string(at: "message", "role")
    }

    /// `message_end.message.stopReason` 是最终消息状态的权威来源。
    public var messageStopReason: String? {
        string(at: "message", "stopReason")
    }

    public var messageErrorMessage: String? {
        string(at: "message", "errorMessage")
            ?? string(at: "message", "error", "message")
            ?? string(at: "message", "error")
    }

    /// 最终 assistant 消息携带的 provider usage。Pi 的上下文统计同样以最后一个
    /// 有效 assistant usage 为基准；先读这个字段可让 HUD 在 `message_end` 时立即更新。
    public var messageContextTokens: Int64? {
        guard messageRole == "assistant",
              messageStopReason != "aborted",
              messageStopReason != "error"
        else { return nil }

        let usagePath = ["message", "usage"]
        if let total = value(at: usagePath + ["totalTokens"])?.intValue, total > 0 {
            return total
        }
        let components = ["input", "output", "cacheRead", "cacheWrite"]
        let total = components.reduce(Int64(0)) { partial, key in
            partial + (value(at: usagePath + [key])?.intValue ?? 0)
        }
        return total > 0 ? total : nil
    }

    public var assistantMessageEventType: String? {
        string(at: "assistantMessageEvent", "type")
    }

    /// 提取 `message.content` 中的文本块；最终内容仍以原始记录为权威。
    public var messageText: String? {
        Self.textContent(from: value(at: "message", "content"))
    }

    public var toolCallID: String? { string(at: "toolCallId") }
    public var toolName: String? { string(at: "toolName") }
    public var toolIsError: Bool { bool(at: "isError") ?? false }

    public var extensionUIRequestID: String? {
        guard type == "extension_ui_request" else { return nil }
        return id
    }

    public var extensionUIMethod: String? {
        guard type == "extension_ui_request" else { return nil }
        return string(at: "method")
    }

    public var extensionUIMessage: String? {
        string(at: "message")
    }

    public var retrySucceeded: Bool? {
        guard type == "auto_retry_end" else { return nil }
        return bool(at: "success")
    }

    public var retryErrorMessage: String? {
        string(at: "finalError") ?? string(at: "errorMessage")
    }

    public var compactionAborted: Bool {
        bool(at: "aborted") ?? false
    }

    public var compactionWillRetry: Bool {
        bool(at: "willRetry") ?? false
    }

    public var eventErrorMessage: String? {
        string(at: "errorMessage") ?? string(at: "error")
    }

    /// 模型显示名。
    ///
    /// `get_state` 与 `cycle_model` 把 Model 包在 `data.model` 下，而 `set_model`
    /// 直接把 Model 作为 `data`。两种形状都要读，否则切模型后 HUD 会留在
    /// 旧名称上。扁平回退只在模型类命令上启用：其他命令的 `data.name`
    /// 与 `data.id` 是完全不同的语义。回退到 id，不编造占位值。
    public var modelName: String? {
        if let nested = string(at: "data", "model", "name")
            ?? string(at: "data", "model", "id") {
            return nested
        }
        guard isModelMutationResponse else { return nil }
        return string(at: "data", "name") ?? string(at: "data", "id")
    }

    /// 直接以 Model 对象作为 `data` 返回的命令。
    private var isModelMutationResponse: Bool {
        command == "set_model" || command == "cycle_model"
    }

    /// 当前模型的 provider 与 id，用于在选择器中标记选中项。
    /// `set_model` 和 `cycle_model` 的响应形状不同：前者直接返回 Model，
    /// 后者把 Model 包在 `data.model` 里。
    public var modelIdentity: (provider: String, id: String)? {
        let provider = string(at: "data", "model", "provider")
            ?? (isModelMutationResponse ? string(at: "data", "provider") : nil)
        let modelID = string(at: "data", "model", "id")
            ?? (isModelMutationResponse ? string(at: "data", "id") : nil)
        guard let provider, !provider.isEmpty, let modelID, !modelID.isEmpty else { return nil }
        return (provider, modelID)
    }

    /// 当前模型是否支持推理；缺字段时返回 nil，由上层保持原值。
    public var modelSupportsReasoning: Bool? {
        bool(at: "data", "model", "reasoning")
            ?? (isModelMutationResponse ? bool(at: "data", "reasoning") : nil)
    }

    /// `get_available_models` 的模型列表。
    public var availableModels: [PiRPCModelInfo]? {
        guard command == "get_available_models",
              success == true,
              let values = value(at: "data", "models")?.arrayValue
        else { return nil }
        return values.compactMap { PiRPCModelInfo(json: $0) }
    }

    /// `get_available_thinking_levels` 的级别列表。
    public var availableThinkingLevels: [String]? {
        guard command == "get_available_thinking_levels",
              success == true,
              let values = value(at: "data", "levels")?.arrayValue
        else { return nil }
        let levels = values.compactMap(\.stringValue).filter { !$0.isEmpty }
        return levels.isEmpty ? nil : levels
    }

    /// `cycle_thinking_level` 以 `data.level` 返回新级别；
    /// 模型不支持推理时 `data` 为 null。
    public var cycledThinkingLevel: String? {
        string(at: "data", "level")
    }

    /// `queue_update` 报告的待执行队列。
    ///
    /// Pi 把 steering 与 follow-up 分两个队列；两边都可能为空数组，
    /// 空数组与字段缺失语义不同：前者表示队列已清空。
    public var queuedSteeringMessages: [String]? {
        guard type == "queue_update" else { return nil }
        return value(at: "steering")?.arrayValue?.compactMap(\.stringValue)
    }

    public var queuedFollowUpMessages: [String]? {
        guard type == "queue_update" else { return nil }
        return value(at: "followUp")?.arrayValue?.compactMap(\.stringValue)
    }

    /// `get_state` 报告的会话显示名与文件路径。
    public var sessionName: String? {
        guard let name = string(at: "data", "sessionName"), !name.isEmpty else { return nil }
        return name
    }

    public var sessionFilePath: String? {
        string(at: "data", "sessionFile")
    }

    /// `export_html` 实际写入的文件路径。
    public var exportedFilePath: String? {
        string(at: "data", "path")
    }

    /// `fork` / `clone` 可被扩展取消；取消时 `success` 仍为 true。
    public var operationWasCancelled: Bool {
        bool(at: "data", "cancelled") == true
    }

    /// `get_fork_messages` 返回的可分叉用户消息。
    public var forkMessages: [(entryID: String, text: String)]? {
        guard command == "get_fork_messages",
              success == true,
              let values = value(at: "data", "messages")?.arrayValue
        else { return nil }
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let entryID = object["entryId"]?.stringValue,
                  !entryID.isEmpty
            else { return nil }
            return (entryID, object["text"]?.stringValue ?? "")
        }
    }

    /// 当前叶节点 id。空会话时为 null，因此缺失与空串都视为 nil。
    public var leafEntryID: String? {
        guard let leaf = string(at: "data", "leafId"), !leaf.isEmpty else { return nil }
        return leaf
    }

    public var thinkingLevel: String? {
        string(at: "data", "thinkingLevel")
    }

    public var contextWindow: Int64? {
        value(at: "data", "model", "contextWindow")?.intValue
            ?? value(at: "data", "contextUsage", "contextWindow")?.intValue
    }

    public var messageCount: Int? {
        guard let value = value(at: "data", "messageCount")?.intValue
            ?? value(at: "data", "totalMessages")?.intValue
        else { return nil }
        return Int(value)
    }

    public var contextTokens: Int64? {
        value(at: "data", "contextUsage", "tokens")?.intValue
    }

    /// `get_session_stats` 的完整统计。
    /// `get_state` 的运行状态字段。Pi 0.84.4 不在这里返回 auto retry 设置，
    /// 因此自动重试状态由 WorkPi 在 `set_auto_retry` 成功后单独缓存。
    public var stateIsStreaming: Bool? {
        value(at: "data", "isStreaming")?.boolValue
    }

    public var stateIsCompacting: Bool? {
        value(at: "data", "isCompacting")?.boolValue
    }

    public var stateSteeringMode: String? {
        string(at: "data", "steeringMode")
    }

    public var stateFollowUpMode: String? {
        string(at: "data", "followUpMode")
    }

    public var stateSessionID: String? {
        string(at: "data", "sessionId")
    }

    public var statePendingMessageCount: Int? {
        value(at: "data", "pendingMessageCount")?.intValue.map(Int.init)
    }

    public var turnIndex: Int? {
        guard type == "turn_start" || type == "turn_end",
              let value = value(at: "turnIndex")?.intValue
        else { return nil }
        return Int(value)
    }

    public var turnTimestamp: Date? {
        guard let milliseconds = value(at: "timestamp")?.intValue else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    public var turnToolResultCount: Int? {
        guard type == "turn_end",
              let values = value(at: "toolResults")?.arrayValue
        else { return nil }
        return values.count
    }

    public var turnMessageStopReason: String? {
        guard type == "turn_end" else { return nil }
        return string(at: "message", "stopReason")
    }

    public var turnMessageErrorMessage: String? {
        guard type == "turn_end" else { return nil }
        return string(at: "message", "errorMessage")
            ?? string(at: "message", "error", "message")
            ?? string(at: "message", "error")
    }

    public var retryAttempt: Int? {
        guard type == "auto_retry_start" || type == "auto_retry_end",
              let value = value(at: "attempt")?.intValue
        else { return nil }
        return Int(value)
    }

    public var retryMaxAttempts: Int? {
        guard type == "auto_retry_start",
              let value = value(at: "maxAttempts")?.intValue
        else { return nil }
        return Int(value)
    }

    public var retryDelayMilliseconds: Int? {
        guard type == "auto_retry_start",
              let value = value(at: "delayMs")?.intValue
        else { return nil }
        return Int(value)
    }

    public var sessionStats: PiSessionStatsPayload? {
        guard command == "get_session_stats", let data = value(at: "data") else { return nil }
        return PiSessionStatsPayload(
            sessionID: data["sessionId"]?.stringValue,
            sessionFile: data["sessionFile"]?.stringValue,
            userMessages: Int(data["userMessages"]?.intValue ?? 0),
            assistantMessages: Int(data["assistantMessages"]?.intValue ?? 0),
            toolCalls: Int(data["toolCalls"]?.intValue ?? 0),
            toolResults: Int(data["toolResults"]?.intValue ?? 0),
            totalMessages: Int(data["totalMessages"]?.intValue ?? 0),
            inputTokens: data.value(at: "tokens", "input")?.intValue ?? 0,
            outputTokens: data.value(at: "tokens", "output")?.intValue ?? 0,
            cacheReadTokens: data.value(at: "tokens", "cacheRead")?.intValue ?? 0,
            cacheWriteTokens: data.value(at: "tokens", "cacheWrite")?.intValue ?? 0,
            totalTokens: data.value(at: "tokens", "total")?.intValue ?? 0,
            cost: data["cost"]?.doubleValue ?? 0,
            contextTokens: data.value(at: "contextUsage", "tokens")?.intValue,
            contextWindow: data.value(at: "contextUsage", "contextWindow")?.intValue,
            contextPercent: data.value(at: "contextUsage", "percent")?.doubleValue
        )
    }

    /// Pi 当前是否开启自动压缩；由 `get_state` 报告。
    public var autoCompactionEnabled: Bool? {
        value(at: "data", "autoCompactionEnabled")?.boolValue
    }

    public var contextPercent: Double? {
        switch value(at: "data", "contextUsage", "percent") {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public var toolResultText: String? {
        switch type {
        case "tool_execution_update":
            return Self.textContent(from: value(at: "partialResult", "content"))
        case "tool_execution_end":
            return Self.textContent(from: value(at: "result", "content"))
        default:
            return nil
        }
    }

    public static func textContent(from value: JSONValue?) -> String? {
        if let text = value?.stringValue {
            return text
        }
        guard let blocks = value?.arrayValue else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined()
        return text.isEmpty ? nil : text
    }
}

public enum PiRPCTransportEvent: Equatable, Sendable {
    case record(PiRPCRecord)
    case diagnostic(String)
    case processExited(status: Int32)
    /// 主进程退出前收集到的有界 stderr；用于区分无模型、扩展加载失败和环境错误。
    case processExitedWithDiagnostic(status: Int32, diagnostic: String)
}

/// 严格按 LF 分帧。U+2028/U+2029 只是 JSON 字符串内容，不是协议分隔符。
struct JSONLFramer: Sendable {
    private(set) var buffer = Data()
    let maximumBufferedBytes: Int

    init(maximumBufferedBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= maximumBufferedBytes else {
            throw PiRPCError.recordTooLarge(buffer.count)
        }

        var records: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                records.append(line)
            }
        }
        return records
    }

    mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll(keepingCapacity: false) }
        var line = buffer
        if line.last == 0x0D {
            line.removeLast()
        }
        return line.isEmpty ? nil : line
    }
}
