import Foundation

/// 可比较的三段式版本号。Pi 和 Node 的命令行版本输出可能带有 `v` 或其它前缀，
/// 解析器只提取第一个完整的 `major.minor.patch`，不会把不完整版本当成可用版本。
struct WorkPiRuntimeVersion: Codable, Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    init?(_ text: String) {
        let candidates = text.split { character in
            !(character.isNumber || character == ".")
        }
        for candidate in candidates {
            let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3,
                  components.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  let major = Int(components[0]),
                  let minor = Int(components[1]),
                  let patch = Int(components[2])
            else { continue }
            self.init(major: major, minor: minor, patch: patch)
            return
        }
        return nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }
}

enum WorkPiRuntimeInstallationSource: String, Codable, Equatable, Sendable {
    case existing
    case workPiManaged

    var title: String {
        switch self {
        case .existing: return "已有安装"
        case .workPiManaged: return "Pura Pi 管理"
        }
    }
}

struct WorkPiRuntimeNodeInfo: Codable, Equatable, Sendable {
    let nodeURL: URL
    let npmURL: URL?
    let version: WorkPiRuntimeVersion

    var meetsMinimum: Bool {
        version >= WorkPiRuntimePolicy.minimumNodeVersion
    }
}

struct WorkPiRuntimeInstallation: Codable, Equatable, Sendable {
    let executableURL: URL
    let version: WorkPiRuntimeVersion
    let source: WorkPiRuntimeInstallationSource
    let nodeURL: URL?

    var displayPath: String { executableURL.path }
}

enum WorkPiRuntimeNodeState: Equatable, Sendable {
    case unknown
    case missing
    case incompatible(WorkPiRuntimeNodeInfo)
    case available(WorkPiRuntimeNodeInfo)

    var canInstallPi: Bool {
        if case .available = self { return true }
        return false
    }

    var info: WorkPiRuntimeNodeInfo? {
        switch self {
        case .available(let info), .incompatible(let info): return info
        case .unknown, .missing: return nil
        }
    }
}

enum WorkPiRuntimeInstallPhase: Equatable, Sendable {
    case preparing
    case installingNode
    case installingPi
    case verifying
    case activating

    var title: String {
        switch self {
        case .preparing: return "准备安装…"
        case .installingNode: return "安装 Node.js…"
        case .installingPi: return "安装 Pi…"
        case .verifying: return "验证 Runtime…"
        case .activating: return "启用 Runtime…"
        }
    }
}

enum WorkPiRuntimeProvisioningError: LocalizedError, Equatable, Sendable {
    case nodeMissing
    case npmMissing
    case nodeTooOld(found: WorkPiRuntimeVersion, required: WorkPiRuntimeVersion)
    case unsupportedPlatform
    case network(String)
    case commandFailed(command: String, detail: String)
    case verificationFailed(String)
    case unsafeManagedDirectory
    case cancelled

    var errorDescription: String? {
        switch self {
        case .nodeMissing:
            return "未找到 Node.js。请安装 Node.js 22.19.0 或更高版本。"
        case .npmMissing:
            return "已找到 Node.js，但没有可用的 npm。请安装包含 npm 的 Node.js 发行版。"
        case .nodeTooOld(let found, let required):
            return "当前 Node.js 为 \(found)，Pi 需要 \(required) 或更高版本。"
        case .unsupportedPlatform:
            return "当前 macOS 硬件或系统不支持自动安装 Node.js。"
        case .network(let message):
            return "下载 Pi Runtime 失败：\(message)"
        case .commandFailed(let command, let detail):
            if detail.isEmpty { return "安装命令失败：\(command)" }
            return "安装命令失败：\(command)\n\(detail)"
        case .verificationFailed(let message):
            return "Runtime 验证失败：\(message)"
        case .unsafeManagedDirectory:
            return "Pura Pi 的 Runtime 目录不安全，已停止安装以保护现有文件。"
        case .cancelled:
            return "Runtime 安装已取消。"
        }
    }
}

enum WorkPiRuntimeAvailability: Equatable, Sendable {
    case checking
    case available(WorkPiRuntimeInstallation)
    case missing(node: WorkPiRuntimeNodeState)
    case incompatible(WorkPiRuntimeInstallation)
    case installing(WorkPiRuntimeInstallPhase)
    case failed(WorkPiRuntimeProvisioningError)

    var installation: WorkPiRuntimeInstallation? {
        switch self {
        case .available(let installation), .incompatible(let installation): return installation
        case .checking, .missing, .installing, .failed: return nil
        }
    }

    var nodeState: WorkPiRuntimeNodeState? {
        switch self {
        case .missing(let node): return node
        case .checking, .available, .incompatible, .installing, .failed: return nil
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 在主线程状态对象与后台创建 transport 的闭包之间共享当前 Runtime。
/// 不把 `ObservableObject` 跨线程捕获，避免 Swift 6 并发检查和生命周期竞态。
struct WorkPiRuntimeSelectionSnapshot: Sendable {
    let installation: WorkPiRuntimeInstallation?
    let automaticResolutionAllowed: Bool

    var executableURL: URL? { installation?.executableURL }

    var environmentOverrides: [String: String] {
        guard let nodeURL = installation?.nodeURL else { return [:] }
        let nodeBin = nodeURL.deletingLastPathComponent().path
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = ([nodeBin] + existing.split(separator: ":").map(String.init))
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, path in
                if !result.contains(path) { result.append(path) }
            }
        return ["PATH": paths.joined(separator: ":")]
    }
}

final class WorkPiRuntimeSelection: @unchecked Sendable {
    static let unavailableExecutableURL = URL(fileURLWithPath: "/__workpi_pi_runtime_not_installed__")

    private let lock = NSLock()
    private var selectedInstallation: WorkPiRuntimeInstallation?
    private var automaticResolutionAllowed = true

    func update(
        _ installation: WorkPiRuntimeInstallation?,
        allowAutomaticResolution: Bool? = nil
    ) {
        lock.lock()
        selectedInstallation = installation
        if let allowAutomaticResolution {
            self.automaticResolutionAllowed = allowAutomaticResolution
        } else if installation != nil {
            automaticResolutionAllowed = false
        }
        lock.unlock()
    }

    func snapshot() -> WorkPiRuntimeSelectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return WorkPiRuntimeSelectionSnapshot(
            installation: selectedInstallation,
            automaticResolutionAllowed: automaticResolutionAllowed
        )
    }

    func currentExecutableURL() -> URL? {
        snapshot().executableURL
    }
}

struct WorkPiRuntimeLocations: Equatable, Sendable {
    let rootURL: URL

    init(rootURL: URL = Self.defaultRootURL()) {
        self.rootURL = rootURL.standardizedFileURL
    }

    var piReleasesURL: URL {
        rootURL.appendingPathComponent("pi/releases", isDirectory: true)
    }

    var nodeReleasesURL: URL {
        rootURL.appendingPathComponent("node/releases", isDirectory: true)
    }

    var currentPiVersionURL: URL {
        rootURL.appendingPathComponent("pi/current-version")
    }

    var currentNodeVersionURL: URL {
        rootURL.appendingPathComponent("node/current-version")
    }

    var metadataURL: URL {
        rootURL.appendingPathComponent("runtime.json")
    }

    func piExecutableURL(for version: WorkPiRuntimeVersion) -> URL {
        piReleasesURL
            .appendingPathComponent(version.description, isDirectory: true)
            .appendingPathComponent("bin/pi")
    }

    func nodeDirectoryURL(for version: WorkPiRuntimeVersion) -> URL {
        nodeReleasesURL.appendingPathComponent(version.description, isDirectory: true)
    }

    func nodeExecutableURL(for version: WorkPiRuntimeVersion) -> URL {
        nodeDirectoryURL(for: version).appendingPathComponent("bin/node")
    }

    func npmExecutableURL(for version: WorkPiRuntimeVersion) -> URL {
        nodeDirectoryURL(for: version).appendingPathComponent("bin/npm")
    }

    static func defaultRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("WorkPi/Runtime", isDirectory: true)
    }
}

enum WorkPiRuntimePolicy {
    static let piPackageName = "@earendil-works/pi-coding-agent"
    /// 当前 RPC 实现最低支持的 Pi 版本；更低版本不冒险复用。
    static let minimumSupportedPiVersion = WorkPiRuntimeVersion(major: 0, minor: 84, patch: 0)
    /// 缺失时安装的固定 Pi 版本；升级必须由新的 WorkPi 版本显式验证。
    static let managedPiVersion = WorkPiRuntimeVersion(major: 0, minor: 84, patch: 4)
    static let minimumNodeVersion = WorkPiRuntimeVersion(major: 22, minor: 19, patch: 0)
    static let nodeDownloadBaseURL = URL(string: "https://nodejs.org/dist/latest-v22.x")!
    static let piWebsiteURL = URL(string: "https://pi.dev")!
    static let nodeDownloadURL = URL(string: "https://nodejs.org/en/download")!
    static let maxNodeChecksumBytes = 2 * 1024 * 1024
    static let maxNodeArchiveBytes = 120 * 1024 * 1024
    static let maxProcessOutputBytes = 512 * 1024
}

struct WorkPiRuntimeDiscoverySnapshot: Equatable, Sendable {
    let installation: WorkPiRuntimeInstallation?
    let node: WorkPiRuntimeNodeState
    let diagnostics: [String]
}
