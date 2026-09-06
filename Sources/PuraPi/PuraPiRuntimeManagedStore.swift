import Foundation

struct PuraPiManagedRuntimeMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let piPackage: String
    let piVersion: PuraPiRuntimeVersion
    let nodeVersion: PuraPiRuntimeVersion?
    let installedAt: Date
}

/// PuraPi 自己安装的 Runtime 只放在用户级 Application Support 目录中。
/// 这个存储器不接触用户已有的全局 npm 安装，也不跟随 PATH 写入 Shell 配置。
struct PuraPiRuntimeManagedStore: Sendable {
    let locations: PuraPiRuntimeLocations

    init(locations: PuraPiRuntimeLocations = PuraPiRuntimeLocations()) {
        self.locations = locations
    }

    func currentInstallation() -> PuraPiRuntimeInstallation? {
        currentInstallationWithoutLegacy()
            ?? legacyStore?.currentInstallationWithoutLegacy()
    }

    func currentNode() -> PuraPiRuntimeNodeInfo? {
        currentNodeWithoutLegacy()
            ?? legacyStore?.currentNodeWithoutLegacy()
    }

    /// 只读检查指定目录，避免旧 store 再次递归查找其它兼容目录。
    private func currentInstallationWithoutLegacy() -> PuraPiRuntimeInstallation? {
        guard let version = readVersion(at: locations.currentPiVersionURL),
              let metadata = readMetadata(),
              metadata.schemaVersion == 1,
              metadata.piPackage == PuraPiRuntimePolicy.piPackageName,
              metadata.piVersion == version,
              let executable = validatedExecutable(locations.piExecutableURL(for: version))
        else { return nil }
        let nodeURL: URL?
        if let nodeVersion = readVersion(at: locations.currentNodeVersionURL) {
            let candidate = locations.nodeExecutableURL(for: nodeVersion)
            nodeURL = validatedExecutable(candidate)
        } else {
            nodeURL = nil
        }
        return PuraPiRuntimeInstallation(
            executableURL: executable,
            version: version,
            source: .puraPiManaged,
            nodeURL: nodeURL
        )
    }

    private func currentNodeWithoutLegacy() -> PuraPiRuntimeNodeInfo? {
        guard let version = readVersion(at: locations.currentNodeVersionURL),
              let nodeURL = validatedExecutable(locations.nodeExecutableURL(for: version))
        else { return nil }
        let npmURL = validatedExecutable(locations.npmExecutableURL(for: version))
        return PuraPiRuntimeNodeInfo(nodeURL: nodeURL, npmURL: npmURL, version: version)
    }

    private var legacyStore: PuraPiRuntimeManagedStore? {
        locations.legacyLocations.map { PuraPiRuntimeManagedStore(locations: $0) }
    }

    func prepareDirectories() throws {
        let fileManager = FileManager.default
        try ensureSafeDirectory(locations.rootURL, create: true)
        try ensureSafeDirectory(locations.rootURL.appendingPathComponent("pi", isDirectory: true), create: true)
        try ensureSafeDirectory(locations.piReleasesURL, create: true)
        try ensureSafeDirectory(locations.rootURL.appendingPathComponent("pi/staging", isDirectory: true), create: true)
        try ensureSafeDirectory(locations.rootURL.appendingPathComponent("node", isDirectory: true), create: true)
        try ensureSafeDirectory(locations.nodeReleasesURL, create: true)
        try ensureSafeDirectory(locations.rootURL.appendingPathComponent("node/staging", isDirectory: true), create: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: locations.rootURL.path
        )
    }

    func activateNode(version: PuraPiRuntimeVersion) throws {
        guard validatedExecutable(locations.nodeExecutableURL(for: version)) != nil else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("Node.js 可执行文件不存在。")
        }
        try writeVersion(version, to: locations.currentNodeVersionURL)
    }

    func activatePi(
        version: PuraPiRuntimeVersion,
        nodeVersion: PuraPiRuntimeVersion?
    ) throws {
        guard validatedExecutable(locations.piExecutableURL(for: version)) != nil else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("Pi 可执行文件不存在。")
        }
        let metadata = PuraPiManagedRuntimeMetadata(
            schemaVersion: 1,
            piPackage: PuraPiRuntimePolicy.piPackageName,
            piVersion: version,
            nodeVersion: nodeVersion,
            installedAt: Date()
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(metadata)
        } catch {
            throw PuraPiRuntimeProvisioningError.verificationFailed("无法生成 Runtime 元数据。")
        }
        let fileManager = FileManager.default
        let oldMetadata = boundedData(at: locations.metadataURL, maximumBytes: 16 * 1024)
        let oldVersion = boundedData(at: locations.currentPiVersionURL, maximumBytes: 128)
        do {
            try writeVersion(version, to: locations.currentPiVersionURL)
            try writeAtomically(data, to: locations.metadataURL, permissions: 0o600)
        } catch {
            // 两个指针不是单个文件，若第二次替换失败，尽力恢复旧的一致状态；
            // 恢复失败也不继续暴露半激活版本。
            restore(oldVersion, at: locations.currentPiVersionURL)
            restore(oldMetadata, at: locations.metadataURL)
            if fileManager.fileExists(atPath: locations.currentPiVersionURL.path),
               oldVersion == nil {
                try? fileManager.removeItem(at: locations.currentPiVersionURL)
            }
            if fileManager.fileExists(atPath: locations.metadataURL.path),
               oldMetadata == nil {
                try? fileManager.removeItem(at: locations.metadataURL)
            }
            throw error
        }
    }

    func isSafeStagingPath(_ url: URL) -> Bool {
        isDescendant(url, of: locations.rootURL)
    }

    private func readMetadata() -> PuraPiManagedRuntimeMetadata? {
        guard let data = boundedData(at: locations.metadataURL, maximumBytes: 16 * 1024) else {
            return nil
        }
        return try? JSONDecoder().decode(PuraPiManagedRuntimeMetadata.self, from: data)
    }

    private func readVersion(at url: URL) -> PuraPiRuntimeVersion? {
        guard let data = boundedData(at: url, maximumBytes: 128),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return PuraPiRuntimeVersion(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func boundedData(at url: URL, maximumBytes: Int) -> Data? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        defer { try? handle.close() }
        let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        guard let data = try? handle.read(upToCount: readLimit),
              data.count <= maximumBytes
        else { return nil }
        return data
    }

    private func restore(_ data: Data?, at url: URL) {
        guard let data else { return }
        try? writeAtomically(data, to: url, permissions: 0o600)
    }

    private func writeVersion(
        _ version: PuraPiRuntimeVersion,
        to url: URL
    ) throws {
        try writeAtomically(
            Data((version.description + "\n").utf8),
            to: url,
            permissions: 0o600
        )
    }

    private func writeAtomically(
        _ data: Data,
        to url: URL,
        permissions: Int16
    ) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try ensureSafeDirectory(parent, create: true)
        if fileManager.fileExists(atPath: url.path), isSymbolicLink(url) {
            throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
        }
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: temporary.path
        )
        if fileManager.fileExists(atPath: url.path) {
            // `replaceItemAt` 在目标存在时以单次文件替换完成更新；不要先
            // remove 再 move，否则进程崩溃窗口会留下缺失的 current 指针。
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporary,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private func ensureSafeDirectory(_ url: URL, create: Bool) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard !isSymbolicLink(url) else {
                throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
            }
            try ensureNoSymlinkBetweenRootAnd(url)
            return
        }
        guard create else { return }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try ensureNoSymlinkBetweenRootAnd(url)
    }

    private func ensureNoSymlinkBetweenRootAnd(_ url: URL) throws {
        let root = locations.rootURL.standardizedFileURL
        let target = url.standardizedFileURL
        guard isDescendant(target, of: root) else {
            throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
        }
        let rootComponents = root.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.starts(with: rootComponents) else {
            throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
        }
        var current = URL(fileURLWithPath: rootComponents[0])
        for component in rootComponents.dropFirst() {
            current.appendPathComponent(component)
        }
        guard !isSymbolicLink(current) else {
            throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
        }
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            if FileManager.default.fileExists(atPath: current.path) {
                guard !isSymbolicLink(current) else {
                    throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
                }
            }
        }
    }

    private func validatedExecutable(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        guard isDescendant(url, of: locations.rootURL),
              fileManager.isExecutableFile(atPath: url.path)
        else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolved, of: locations.rootURL),
              fileManager.isExecutableFile(atPath: resolved.path)
        else { return nil }
        return url.standardizedFileURL
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
