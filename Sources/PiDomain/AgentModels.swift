import Darwin
import Foundation

/// Agent 的生命周期阶段。UI 只消费这个稳定模型，不直接依赖 Pi 的 TUI 状态。
public enum AgentPhase: String, CaseIterable, Codable, Sendable {
    case idle
    case preparing
    case requesting
    case streaming
    case executingTool
    case settling
    case failed
    case cancelled
}

/// 当前 Agent 回合的终止结果。
///
/// 这个模型独立于 `AgentPhase`：phase 描述 Runtime 当前所在阶段，
/// outcome 描述已经结束或正在结束的这一回合是正常完成、用户取消还是失败。
/// 用户主动停止不能被 provider/RPC 的普通错误文本改写为失败。
public enum AgentRunOutcome: String, CaseIterable, Codable, Sendable {
    case running
    case completed
    case cancelled
    case failed
}

/// 当前 Agent Runtime 的可视化元数据。
/// 数值由 Pi RPC 的 `get_state` 和 `get_session_stats` 提供；缺失时保持 nil，UI 显示读取中。
public struct AgentRuntimeMetadata: Equatable, Sendable {
    public var modelName: String?
    /// 当前模型的 provider 与 id；用于在模型选择器中标记选中项。
    public var modelProvider: String?
    public var modelID: String?
    /// 当前模型是否支持推理。为 false 时推理级别不可切换。
    public var modelSupportsReasoning: Bool?
    public var thinkingLevel: String?
    public var contextTokens: Int64?
    public var contextWindow: Int64?
    public var contextPercent: Double?
    public var messageCount: Int?
    /// Pi 是否开启了自动压缩。nil 表示尚未从 `get_state` 读到。
    public var autoCompactionEnabled: Bool?

    /// 与 `PiRPCModelInfo.selectionKey` 对齐的稳定键。
    public var modelSelectionKey: String? {
        guard let modelProvider, let modelID else { return nil }
        return "\(modelProvider)/\(modelID)"
    }

    public init(
        modelName: String? = nil,
        modelProvider: String? = nil,
        modelID: String? = nil,
        modelSupportsReasoning: Bool? = nil,
        thinkingLevel: String? = nil,
        contextTokens: Int64? = nil,
        contextWindow: Int64? = nil,
        contextPercent: Double? = nil,
        messageCount: Int? = nil,
        autoCompactionEnabled: Bool? = nil
    ) {
        self.modelName = modelName
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.modelSupportsReasoning = modelSupportsReasoning
        self.thinkingLevel = thinkingLevel
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.messageCount = messageCount
        self.autoCompactionEnabled = autoCompactionEnabled
    }
}

/// 当前工作区的最小描述。
public struct WorkspaceDescriptor: Equatable, Hashable, Sendable {
    public let rootURL: URL
    public let displayName: String

    public init(rootURL: URL) {
        // Workspace identity is the resolved directory, not the spelling used by the
        // open panel.  Every consumer (tree, preview, editor and tab de-duplication)
        // must otherwise disagree when the project was opened through a symlink.
        let canonical = Self.canonicalDirectoryURL(rootURL)
        self.rootURL = canonical
        self.displayName = canonical.lastPathComponent.isEmpty ? canonical.path : canonical.lastPathComponent
    }

    private static func canonicalDirectoryURL(_ url: URL) -> URL {
        let resolvedPath: String? = url.path.withCString { path in
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        return URL(
            fileURLWithPath: resolvedPath ?? url.resolvingSymlinksInPath().path,
            isDirectory: true
        ).standardizedFileURL
    }
}

/// 文件树节点。文件和符号链接的 `children` 为 nil；目录在尚未展开读取时也可为 nil，
/// 通过 `childrenLoaded` 区分“未加载目录”和“已加载空目录”。
public struct FileNode: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case directory
        case file
        case symbolicLink
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    public let children: [FileNode]?
    /// 目录的子项是否已经从磁盘读取；文件和符号链接始终视为已加载。
    /// `children == nil` 对目录表示“尚未展开读取”，不再表示目录不存在。
    public let childrenLoaded: Bool

    public var id: URL { url }
    public var isDirectory: Bool { kind == .directory }
    public var isExpandable: Bool {
        isDirectory && (!childrenLoaded || !(children?.isEmpty ?? true))
    }

    public init(
        url: URL,
        name: String,
        kind: Kind,
        children: [FileNode]? = nil,
        childrenLoaded: Bool? = nil
    ) {
        self.url = url.standardizedFileURL
        self.name = name
        self.kind = kind
        self.children = children
        self.childrenLoaded = childrenLoaded ?? (kind != .directory || children != nil)
    }
}

public enum FilePreviewKind: String, Codable, Sendable {
    case markdown
    case text
    case image
    case binary
    case tooLarge
    case unreadable
}

/// 右侧文件检查器使用的只读快照。
public struct FilePreview: Identifiable, Equatable, Sendable {
    public let url: URL
    public let relativePath: String
    public let kind: FilePreviewKind
    public let text: String?
    public let byteCount: Int
    public let modificationDate: Date?

    public var id: URL { url }

    public init(
        url: URL,
        relativePath: String,
        kind: FilePreviewKind,
        text: String?,
        byteCount: Int,
        modificationDate: Date?
    ) {
        self.url = url.standardizedFileURL
        self.relativePath = relativePath
        self.kind = kind
        self.text = text
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

/// GUI 中显示的一条对话或工具活动。
public struct ConversationItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user
        case command
        case assistant
        case thinking
        case tool
        case system
        case error
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case streaming
        case completed
        case failed
        case cancelled
    }

    public let id: UUID
    public let kind: Kind
    public var title: String?
    public var text: String
    public var detail: String?
    public var status: Status
    /// 消息产生时间。
    ///
    /// 恢复历史时用 Pi 记录的时间，实时消息用本地时间。
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String? = nil,
        text: String = "",
        detail: String? = nil,
        status: Status = .completed,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.status = status
        self.createdAt = createdAt
    }
}
