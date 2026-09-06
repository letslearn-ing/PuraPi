import Darwin
import Foundation
import PiRPC

/// 认证 sidecar 的内置脚本资源。资源由 PuraPi 自己打包，不接受用户可执行主题或项目文件。
enum PuraPiAuthBridgeResources {
    static var scriptURL: URL? {
        Bundle.module.url(forResource: "PuraPiAuthBridge", withExtension: "mjs")
    }
}

/// 启动官方认证 SDK sidecar 所需的固定路径。这里不包含任何凭据内容。
struct PuraPiAuthBridgeConfiguration: Equatable, Sendable {
    let nodeURL: URL
    let nodeCandidates: [URL]
    let entryURL: URL
    let authPath: URL
    let modelsPath: URL
    let agentDirectoryURL: URL
    let currentDirectoryURL: URL
    let environment: [String: String]

    init(
        nodeURL: URL,
        nodeCandidates: [URL] = [],
        entryURL: URL,
        authPath: URL,
        modelsPath: URL,
        agentDirectoryURL: URL,
        currentDirectoryURL: URL,
        environment: [String: String]
    ) {
        self.nodeURL = nodeURL
        var seen = Set<String>()
        self.nodeCandidates = ([nodeURL] + nodeCandidates).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
        self.entryURL = entryURL
        self.authPath = authPath
        self.modelsPath = modelsPath
        self.agentDirectoryURL = agentDirectoryURL
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
    }
}

enum PuraPiAuthFileSystem {
    /// Node/npm 常用符号链接；检查其最终目标，避免把合法 shim 当成不安全文件。
    /// auth.json 不使用此方法，而是由 O_NOFOLLOW 单独拒绝符号链接。
    static func isRegularFile(at url: URL) -> Bool {
        var information = stat()
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard Darwin.lstat(resolved.path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFREG
    }
}

/// 把 PuraPi 选择的 Pi 安装映射到同一发行版中的 Node 和官方 SDK 入口。
enum PuraPiAuthStorageSecurity {
    /// 只收紧权限，不跟随符号链接；不存在的文件交给官方 AuthStorage 以 0600 创建。
    static func ensureUserOnlyPermissions(at url: URL) throws {
        try ensureParentDirectory(at: url.deletingLastPathComponent())
        let path = url.standardizedFileURL.path
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw PuraPiAuthError.unavailable("无法安全访问 Pi auth.json；请检查文件权限。")
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG
        else {
            throw PuraPiAuthError.unavailable("Pi auth.json 必须是普通文件，认证桥接已停止。")
        }
        guard information.st_size <= 1 * 1024 * 1024 else {
            throw PuraPiAuthError.unavailable("Pi auth.json 超过认证桥接的安全大小限制。")
        }
        guard !hasExtendedACL(descriptor) else {
            throw PuraPiAuthError.unavailable("Pi auth.json 含有额外访问控制列表；请移除 ACL 后重试。")
        }
        if (information.st_mode & 0o077) != 0 {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw PuraPiAuthError.unavailable("Pi auth.json 权限过宽且无法修复；请将权限设为 600。")
            }
            guard Darwin.fstat(descriptor, &information) == 0,
                  (information.st_mode & 0o077) == 0
            else {
                throw PuraPiAuthError.unavailable("无法确认 Pi auth.json 的安全权限。")
            }
        }
    }

    private static func ensureParentDirectory(at url: URL) throws {
        // /tmp、/var 等系统路径可能包含合法的中间符号链接；目录检查允许这些
        // 系统别名，真正的 auth.json 文件仍由 O_NOFOLLOW 单独保护。
        var directory = url.resolvingSymlinksInPath().standardizedFileURL
        while true {
            let descriptor = Darwin.open(
                directory.path,
                O_RDONLY | O_DIRECTORY
            )
            if descriptor < 0 {
                if errno == ENOENT {
                    let parent = directory.deletingLastPathComponent()
                    guard parent.path != directory.path else { return }
                    directory = parent
                    continue
                }
                throw PuraPiAuthError.unavailable("无法安全访问 Pi auth.json 所在目录。")
            }

            var information = stat()
            let isDirectory = Darwin.fstat(descriptor, &information) == 0
                && (information.st_mode & S_IFMT) == S_IFDIR
            let hasACL = hasExtendedACL(descriptor)
            let hasOtherWritePermission = (information.st_mode & 0o022) != 0
            let isStickyDirectory = (information.st_mode & S_ISVTX) != 0
            var directoryIsSafe = isDirectory && !hasACL
            if directoryIsSafe && hasOtherWritePermission && !isStickyDirectory {
                directoryIsSafe = Darwin.fchmod(descriptor, mode_t(0o700)) == 0
                    && Darwin.fstat(descriptor, &information) == 0
                    && (information.st_mode & 0o022) == 0
            }
            _ = Darwin.close(descriptor)
            guard directoryIsSafe else {
                throw PuraPiAuthError.unavailable("Pi auth.json 所在目录的访问权限不安全。")
            }
            if directory.path == "/" { return }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return }
            directory = parent
        }
    }

    private static func hasExtendedACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { return true }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
            .split(whereSeparator: \.isNewline)
            .drop(while: { $0.hasPrefix("!#") })
            .contains { line in
                let value = String(line)
                return !value.hasPrefix("user::")
                    && !value.hasPrefix("group::")
                    && !value.hasPrefix("other::")
                    && !value.hasPrefix("mask::")
            }
    }
}

enum PuraPiAuthBridgeLocator {
    static func locate(
        selection: PuraPiRuntimeSelectionSnapshot? = nil,
        locations: PuraPiRuntimeLocations = PuraPiRuntimeLocations(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<PuraPiAuthBridgeConfiguration, PuraPiAuthError> {
        let home = homeDirectory.standardizedFileURL
        let piURL = selection?.executableURL
            ?? PiExecutableResolver(environment: environment).resolve()
        guard let piURL else {
            return .failure(.unavailable("未找到可用于认证的 Pi Runtime。请先安装或选择 Pi。"))
        }

        guard let entryURL = findSDKEntry(for: piURL) else {
            return .failure(.unavailable(
                "当前 Pi 安装没有可用的官方 ModelRuntime SDK。请选择由 npm 安装的 Pi，或更新 Pi Runtime。"
            ))
        }

        let managedStore = PuraPiRuntimeManagedStore(locations: locations)
        var nodeCandidates: [URL] = []
        if let selectedNode = selection?.installation?.nodeURL {
            nodeCandidates.append(selectedNode)
        }
        // npm 全局安装的 pi 通常与 Node 位于同一个 bin 目录；优先使用
        // 该相邻 Node，避免 GUI 的 PATH 先命中过旧的 nvm/fnm 版本。
        let adjacentNode = piURL.deletingLastPathComponent().appendingPathComponent("node")
        if isExecutable(adjacentNode) {
            nodeCandidates.append(adjacentNode)
        }
        nodeCandidates.append(contentsOf: PuraPiRuntimeCandidatePaths.nodeCandidates(
            environment: environment,
            homeDirectory: home,
            managedStore: managedStore,
            includeDefaultDirectories: true
        ))
        let executableNodeCandidates = unique(nodeCandidates).filter(isExecutable)
        guard let nodeURL = executableNodeCandidates.first else {
            return .failure(.unavailable(
                "未找到 Node.js。Pi 认证需要 Node.js 22.19.0 或更高版本。"
            ))
        }

        guard PuraPiAuthBridgeResources.scriptURL != nil else {
            return .failure(.unavailable("PuraPi 认证桥接资源缺失，请重新构建应用。"))
        }

        let agentDirectory = agentDirectoryURL(from: environment, home: home)
        var childEnvironment = sanitizedEnvironment(environment)
        childEnvironment["HOME"] = home.path
        childEnvironment["PI_CODING_AGENT_DIR"] = agentDirectory.path
        // OAuth 回调只应绑定本机回环地址；不继承用户环境中的 0.0.0.0 等值，
        // 避免把临时回调端口暴露到局域网。
        childEnvironment["PI_OAUTH_CALLBACK_HOST"] = "127.0.0.1"
        childEnvironment["PI_SKIP_VERSION_CHECK"] = "1"
        childEnvironment["PI_TELEMETRY"] = "0"
        childEnvironment["NO_COLOR"] = "1"
        childEnvironment["PATH"] = pathValue(
            prepending: [
                nodeURL.deletingLastPathComponent().path,
                piURL.deletingLastPathComponent().path,
            ],
            to: childEnvironment["PATH"] ?? ""
        )

        return .success(PuraPiAuthBridgeConfiguration(
            nodeURL: nodeURL.standardizedFileURL,
            nodeCandidates: executableNodeCandidates.map(\.standardizedFileURL),
            entryURL: entryURL.standardizedFileURL,
            authPath: agentDirectory.appendingPathComponent("auth.json"),
            modelsPath: agentDirectory.appendingPathComponent("models.json"),
            agentDirectoryURL: agentDirectory,
            currentDirectoryURL: home,
            environment: childEnvironment
        ))
    }

    private static func findSDKEntry(for executableURL: URL) -> URL? {
        let resolvedExecutable = executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var directory = resolvedExecutable.hasDirectoryPath
            ? resolvedExecutable
            : resolvedExecutable.deletingLastPathComponent()

        for _ in 0..<10 {
            let packageManifest = directory.appendingPathComponent("package.json")
            let manifestSize = (try? FileManager.default.attributesOfItem(atPath: packageManifest.path))?[.size] as? NSNumber
            if PuraPiAuthFileSystem.isRegularFile(at: packageManifest),
               let manifestSize,
               manifestSize.intValue <= 128 * 1024,
               let data = boundedData(at: packageManifest, maximumBytes: 128 * 1024),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["name"] as? String == PuraPiRuntimePolicy.piPackageName,
               let versionText = object["version"] as? String,
               isPackageVersion(versionText),
               let version = PuraPiRuntimeVersion(versionText),
               version >= PuraPiRuntimePolicy.minimumSupportedPiVersion {
                let entry = directory.appendingPathComponent("dist/index.js")
                let resolvedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
                let rootPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
                guard resolvedEntry.path.hasPrefix(rootPath),
                      PuraPiAuthFileSystem.isRegularFile(at: resolvedEntry),
                      FileManager.default.isReadableFile(atPath: resolvedEntry.path)
                else { return nil }
                return resolvedEntry
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }

    private static func isPackageVersion(_ text: String) -> Bool {
        text.range(
            of: #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func boundedData(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let readCount = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        guard let data = try? handle.read(upToCount: readCount),
              data.count <= maximumBytes
        else { return nil }
        return data
    }

    private static func agentDirectoryURL(
        from environment: [String: String],
        home: URL
    ) -> URL {
        guard let configured = environment["PI_CODING_AGENT_DIR"],
              !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return home.appendingPathComponent(".pi/agent", isDirectory: true)
        }
        let expanded = (configured as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        // Pi 的配置目录应是绝对路径；相对路径不交给 sidecar 解释，避免
        // 因当前目录变化而把凭据写到项目目录。
        guard url.path.hasPrefix("/") else {
            return home.appendingPathComponent(".pi/agent", isDirectory: true)
        }
        return url
    }

    private static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        let blockedExact: Set<String> = [
            "NODE_OPTIONS",
            "NODE_PATH",
            "BASH_ENV",
            "ENV",
            "LD_PRELOAD",
        ]
        return environment.filter { key, _ in
            let uppercased = key.uppercased()
            guard !blockedExact.contains(uppercased),
                  !uppercased.hasPrefix("DYLD_") && !uppercased.hasPrefix("NPM_CONFIG_")
            else { return false }
            return true
        }
    }

    private static func pathValue(prepending prefixes: [String], to existing: String) -> String {
        var values: [String] = []
        for value in prefixes + existing.split(separator: ":").map(String.init)
        where !value.isEmpty && !values.contains(value) {
            values.append(value)
        }
        return values.joined(separator: ":")
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}

/// sidecar 的一次请求。API Key 和令牌只存在于 sidecar 内部，不在这些结构中出现。
struct PuraPiAuthBridgeRequest: Encodable, Sendable {
    let id: String
    let type: String
    let provider: String?
    let authType: PuraPiAuthType?
    let providers: [String]?
    let allowNetwork: Bool?
    let force: Bool?

    static func status(id: String) -> Self {
        Self(id: id, type: "status", provider: nil, authType: nil, providers: nil, allowNetwork: nil, force: nil)
    }

    static func models(id: String) -> Self {
        Self(id: id, type: "models", provider: nil, authType: nil, providers: nil, allowNetwork: nil, force: nil)
    }

    static func validate(id: String) -> Self {
        Self(id: id, type: "validate", provider: nil, authType: nil, providers: nil, allowNetwork: nil, force: nil)
    }

    static func login(id: String, provider: String, type: PuraPiAuthType) -> Self {
        Self(id: id, type: "login", provider: provider, authType: type, providers: nil, allowNetwork: nil, force: nil)
    }

    static func logout(id: String, provider: String) -> Self {
        Self(id: id, type: "logout", provider: provider, authType: nil, providers: nil, allowNetwork: nil, force: nil)
    }

    static func refresh(
        id: String,
        providers: [String]? = nil,
        allowNetwork: Bool,
        force: Bool
    ) -> Self {
        Self(id: id, type: "refresh", provider: nil, authType: nil, providers: providers, allowNetwork: allowNetwork, force: force)
    }
}

struct PuraPiAuthBridgePromptResponse: Encodable, Sendable {
    let type = "prompt_response"
    let id: String
    let value: String
}

/// sidecar 的一条 JSONL 消息。凭据字段不在协议模型中定义，避免误解码或回传。
struct PuraPiAuthBridgeMessage: Decodable, Sendable {
    let type: String
    let id: String?
    let operation: String?
    let operationId: String?
    let protocolVersion: Int?
    let prompt: PuraPiAuthPrompt?
    let event: PuraPiAuthEventPayload?
    let providers: [PuraPiAuthProvider]?
    let credentials: [PuraPiStoredCredential]?
    let models: [PuraPiAuthModel]?
    let modelsTruncated: Bool?
    let changedProviderId: String?
    let changedProviderIds: [String]?
    let changedAuthType: PuraPiAuthType?
    let refreshAborted: Bool?
    let refreshErrors: [PuraPiAuthRefreshError]?
    let authErrors: [PuraPiAuthRefreshError]?
    let availabilityErrors: [PuraPiAuthRefreshError]?
    let authStorageRevision: String?
    let credentialCommitted: Bool?
    let cancelled: Bool?
    let message: String?
}

struct PuraPiAuthRefreshError: Decodable, Equatable, Sendable {
    let providerId: String
    let message: String
}

/// 先解码为中间载荷，再严格验证 URL 和字段长度，最后交给主线程状态。
struct PuraPiAuthEventPayload: Decodable, Sendable {
    let type: String
    let message: String?
    let url: String?
    let instructions: String?
    let userCode: String?
    let verificationUri: String?
    let intervalSeconds: Double?
    let expiresInSeconds: Double?
    let links: [PuraPiAuthEventLinkPayload]?

    func materialize() -> PuraPiAuthEvent? {
        guard type.count <= 64 else { return nil }
        let parsedURL = url.flatMap(Self.safeURL)
        let parsedVerificationURL = verificationUri.flatMap(Self.safeURL)
        let parsedLinks: [PuraPiAuthEventLink] = (links ?? []).compactMap { link in
            guard let url = Self.safeURL(link.url) else { return nil }
            return PuraPiAuthEventLink(
                url: url,
                label: link.label.map { PuraPiSensitiveText.redacted(String($0.prefix(512)), limit: 512) }
            )
        }
        return PuraPiAuthEvent(
            type: type,
            message: message.map { PuraPiSensitiveText.redacted(String($0.prefix(4 * 1024))) },
            url: parsedURL,
            instructions: instructions.map { PuraPiSensitiveText.redacted(String($0.prefix(4 * 1024))) },
            userCode: userCode.map { PuraPiSensitiveText.redacted(String($0.prefix(512)), limit: 512) },
            verificationUri: parsedVerificationURL,
            intervalSeconds: intervalSeconds,
            expiresInSeconds: expiresInSeconds,
            links: parsedLinks
        )
    }

    private static func safeURL(_ string: String) -> URL? {
        guard string.count <= 4_096,
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }

}

struct PuraPiAuthEventLinkPayload: Decodable, Sendable {
    let url: String
    let label: String?
}

extension PuraPiAuthPrompt {
    var isWithinSafetyBounds: Bool {
        id.utf8.count <= 512
            && message.utf8.count <= 4 * 1024
            && (placeholder?.utf8.count ?? 0) <= 512
            && options.count <= 100
            && options.allSatisfy {
                $0.id.utf8.count <= 512
                    && $0.label.utf8.count <= 512
                    && ($0.description?.utf8.count ?? 0) <= 1_024
            }
    }
}

extension PuraPiAuthBridgeMessage {
    func operationResult() -> PuraPiAuthBridgeResult? {
        guard let providers, let credentials, let models else { return nil }
        let snapshot = PuraPiAuthSnapshot(
            providers: providers,
            credentials: credentials,
            models: models,
            modelsTruncated: modelsTruncated ?? false
        )
        let warnings = (refreshErrors ?? []).map {
            PuraPiAuthRefreshWarning(providerId: $0.providerId, message: $0.message)
        } + (authErrors ?? []).map {
            PuraPiAuthRefreshWarning(providerId: $0.providerId, message: $0.message)
        } + (availabilityErrors ?? []).map {
            PuraPiAuthRefreshWarning(providerId: $0.providerId, message: $0.message)
        }
        return PuraPiAuthBridgeResult(
            snapshot: snapshot,
            refreshAborted: refreshAborted ?? false,
            refreshWarnings: warnings,
            changedProviderIDs: (changedProviderIds ?? []).filter { !$0.isEmpty },
            authStorageRevision: authStorageRevision
        )
    }
}
