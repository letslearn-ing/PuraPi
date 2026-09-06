import Foundation

/// 一个 Pi 会话的列表级摘要。
///
/// 只包含渲染 Sidebar 会话列表所需的信息；完整消息按需再读。
public struct PiSessionSummary: Identifiable, Equatable, Sendable {
    public let fileURL: URL
    public let sessionID: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let cwd: String
    /// 由 fork/clone 派生时指向来源会话文件，可用来在列表中体现派生关系。
    public let parentSessionPath: String?
    /// 用户通过 `set_session_name` 设置的显示名；未设置时为 nil。
    public let name: String?
    public let messageCount: Int
    /// 首条用户消息，用作没有名字时的标题回退。
    public let firstUserText: String?

    public var id: String { fileURL.path }

    public init(
        fileURL: URL,
        sessionID: String,
        createdAt: Date,
        modifiedAt: Date,
        cwd: String,
        parentSessionPath: String? = nil,
        name: String? = nil,
        messageCount: Int = 0,
        firstUserText: String? = nil
    ) {
        self.fileURL = fileURL
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.cwd = cwd
        self.parentSessionPath = parentSessionPath
        self.name = name
        self.messageCount = messageCount
        self.firstUserText = firstUserText
    }

    /// 列表中显示的标题。
    ///
    /// 优先级：用户设置的名字 → 首条用户消息摘要 → 创建时间。
    /// 不返回空字符串，避免列表出现看不见的行。
    public func displayTitle(dateFormatter: DateFormatter) -> String {
        if let name, !name.isEmpty { return name }
        if let firstUserText, !firstUserText.isEmpty {
            return String(firstUserText.prefix(60))
        }
        return dateFormatter.string(from: createdAt)
    }
}

/// 会话内的一轮对话。
///
/// Pi 的会话是 entry 树：一轮通常是「一条用户消息 + 其后的助手回复与工具调用」。
/// Sidebar 只需要按轮次导航，因此把连续的助手/工具条目折叠进所属的用户轮次。
public struct PiSessionTurn: Identifiable, Equatable, Sendable {
    /// 该轮起始用户消息的 entry id；`fork` 需要这个 id。
    public let entryID: String
    public let text: String
    public let timestamp: Date
    /// 这一轮包含的助手与工具条目数量，用于显示规模。
    public let responseCount: Int
    /// 是否位于当前活动分支上。fork 会让旧分支变为非活动。
    public let isOnActiveBranch: Bool

    public var id: String { entryID }

    public init(
        entryID: String,
        text: String,
        timestamp: Date,
        responseCount: Int = 0,
        isOnActiveBranch: Bool = true
    ) {
        self.entryID = entryID
        self.text = text
        self.timestamp = timestamp
        self.responseCount = responseCount
        self.isOnActiveBranch = isOnActiveBranch
    }
}
