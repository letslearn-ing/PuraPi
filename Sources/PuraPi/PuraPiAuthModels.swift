import Foundation

/// Pi 官方认证方式。`oauth` 代表订阅账号登录，`api_key` 代表 API Key。
enum PuraPiAuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case oauth
    case apiKey = "api_key"

    var id: String { rawValue }

    func title(language: PuraPiInterfaceLanguage) -> String {
        switch self {
        case .oauth:
            return language == .english ? "Subscription account" : "订阅账号"
        case .apiKey:
            return language == .english ? "API key" : "API Key"
        }
    }

    var shortTitle: String {
        switch self {
        case .oauth: return "OAuth"
        case .apiKey: return "API key"
        }
    }
}

/// 认证状态只保存非敏感元数据，绝不保存令牌或 API Key。
struct PuraPiAuthStatus: Codable, Equatable, Sendable {
    let configured: Bool
    let type: PuraPiAuthType?
    let source: String?
    let subscription: Bool

    static let unconfigured = PuraPiAuthStatus(
        configured: false,
        type: nil,
        source: nil,
        subscription: false
    )

    func sourceLabel(language: PuraPiInterfaceLanguage) -> String? {
        guard configured else { return nil }
        if subscription || type == .oauth || source == "stored" || source == "stored credential" {
            return language == .english ? "Pi official auth storage" : "Pi 官方认证存储"
        }
        guard let source, !source.isEmpty else {
            return language == .english ? "Configured" : "已配置"
        }
        return source.hasPrefix("env:")
            ? source
            : (language == .english ? "Pi / environment" : "Pi / 环境配置")
    }
}

/// 一个 Provider 可用的认证入口。
struct PuraPiAuthMethod: Codable, Equatable, Identifiable, Sendable {
    let type: PuraPiAuthType
    let name: String
    let isSubscription: Bool
    let loginLabel: String?
    let canLogin: Bool

    var id: String { type.rawValue }
}

/// Provider（模型服务商）的认证元数据。
struct PuraPiAuthProvider: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let authTypes: [PuraPiAuthMethod]
    let status: PuraPiAuthStatus?

    var isConfigured: Bool { status?.configured == true }
    var configuredType: PuraPiAuthType? { status?.type }
    var hasStoredCredential: Bool {
        status?.source == "stored" || status?.source == "stored credential"
    }
    var supportsOAuth: Bool { authTypes.contains { $0.type == .oauth } }
    var supportsAPIKey: Bool { authTypes.contains { $0.type == .apiKey } }

    func method(_ type: PuraPiAuthType) -> PuraPiAuthMethod? {
        authTypes.first { $0.type == type }
    }

    var displayPriority: Int {
        switch id {
        case "openai-codex": return 0
        case "openai": return 1
        case "anthropic": return 2
        default: return 10
        }
    }
}

/// 可用模型的非敏感目录项。
struct PuraPiAuthModel: Codable, Equatable, Identifiable, Sendable {
    let providerId: String
    let id: String
    let name: String
    let api: String
    let reasoning: Bool
    let input: [String]
    let contextWindow: Int
    let maxTokens: Int

    var selectionKey: String { "\(providerId)/\(id)" }

    var stableID: String { selectionKey }
}

/// 认证桥接返回的完整快照。
struct PuraPiAuthSnapshot: Codable, Equatable, Sendable {
    var providers: [PuraPiAuthProvider]
    var credentials: [PuraPiStoredCredential]
    var models: [PuraPiAuthModel]
    var modelsTruncated: Bool

    static let empty = PuraPiAuthSnapshot(
        providers: [],
        credentials: [],
        models: [],
        modelsTruncated: false
    )

    var configuredProviderCount: Int {
        providers.filter(\.isConfigured).count
    }

    func provider(id: String) -> PuraPiAuthProvider? {
        providers.first { $0.id == id }
    }
}

/// `auth.json` 中的凭据列表只返回 provider 和类型，不返回秘密字段。
struct PuraPiStoredCredential: Codable, Equatable, Identifiable, Sendable {
    let providerId: String
    let type: PuraPiAuthType

    var id: String { "\(providerId):\(type.rawValue)" }
}

struct PuraPiAuthRefreshWarning: Equatable, Sendable {
    let providerId: String
    let message: String
}

/// 一次 sidecar 操作的结果。只携带状态和模型元数据，不携带凭据。
struct PuraPiAuthBridgeResult: Sendable {
    let snapshot: PuraPiAuthSnapshot
    let refreshAborted: Bool
    let refreshWarnings: [PuraPiAuthRefreshWarning]
    let changedProviderIDs: [String]
    /// 只包含 auth.json 的设备/文件元数据，不包含文件内容或凭据指纹。
    let authStorageRevision: String?

    init(
        snapshot: PuraPiAuthSnapshot,
        refreshAborted: Bool,
        refreshWarnings: [PuraPiAuthRefreshWarning],
        changedProviderIDs: [String] = [],
        authStorageRevision: String? = nil
    ) {
        self.snapshot = snapshot
        self.refreshAborted = refreshAborted
        self.refreshWarnings = refreshWarnings
        self.changedProviderIDs = changedProviderIDs
        self.authStorageRevision = authStorageRevision
    }
}

/// 官方 OAuth/API-key 交互过程中显示给用户的事件。
struct PuraPiAuthEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let type: String
    let message: String?
    let url: URL?
    let instructions: String?
    let userCode: String?
    let verificationUri: URL?
    let intervalSeconds: Double?
    let expiresInSeconds: Double?
    let links: [PuraPiAuthEventLink]

    init(
        id: UUID = UUID(),
        type: String,
        message: String? = nil,
        url: URL? = nil,
        instructions: String? = nil,
        userCode: String? = nil,
        verificationUri: URL? = nil,
        intervalSeconds: Double? = nil,
        expiresInSeconds: Double? = nil,
        links: [PuraPiAuthEventLink] = []
    ) {
        self.id = id
        self.type = type
        self.message = message
        self.url = url
        self.instructions = instructions
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.intervalSeconds = intervalSeconds
        self.expiresInSeconds = expiresInSeconds
        self.links = links
    }

    var isAuthURL: Bool { type == "auth_url" }
    var isDeviceCode: Bool { type == "device_code" }
    var isProgress: Bool { type == "progress" }
}

struct PuraPiAuthEventLink: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    let label: String?

    init(url: URL, label: String?) {
        self.id = UUID()
        self.url = url
        self.label = label
    }
}

/// Provider 提交给 Pi 官方交互回调的输入请求。
struct PuraPiAuthPrompt: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case secret
        case select
        case manualCode = "manual_code"
    }

    struct Option: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let description: String?
    }

    let id: String
    let kind: Kind
    let message: String
    let placeholder: String?
    let options: [Option]
}

enum PuraPiAuthPhase: Equatable, Sendable {
    case idle
    case checking
    case loggingIn(providerID: String, type: PuraPiAuthType)
    case loggingOut(providerID: String)
    case refreshing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed: return false
        case .checking, .loggingIn, .loggingOut, .refreshing: return true
        }
    }

    var title: String {
        switch self {
        case .idle: return ""
        case .checking: return "正在读取认证状态…"
        case .loggingIn: return "正在登录…"
        case .loggingOut: return "正在退出登录…"
        case .refreshing: return "正在刷新模型…"
        case .failed(let message): return message
        }
    }
}

/// 认证桥接的公开错误。错误文本经过桥接层限制和脱敏。
enum PuraPiAuthError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case launchFailed(String)
    case invalidMessage(String)
    case requestFailed(
        String,
        credentialMayHaveBeenSaved: Bool,
        changedProviderIDs: [String] = []
    )
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .launchFailed(let message): return "无法启动 Pi 认证桥接：\(message)"
        case .invalidMessage(let message): return "Pi 认证桥接返回了无效消息：\(message)"
        case .requestFailed(let message, let credentialMayHaveBeenSaved, _):
            return credentialMayHaveBeenSaved
                ? "\(message) 凭据可能已经保存，请刷新认证状态确认。"
                : message
        case .timedOut: return "认证操作超时。"
        case .cancelled: return "认证操作已取消。"
        }
    }
}

extension Notification.Name {
    /// 认证凭据改变后通知活动项目 Runtime；凭据本身不放进 userInfo。
    static let puraPiAuthenticationChanged = Notification.Name("PuraPi.authenticationChanged")
    /// 打开设置并切换到账号页，用于 Runtime 认证错误恢复。
    static let puraPiOpenAccountSettings = Notification.Name("PuraPi.openAccountSettings")
}
