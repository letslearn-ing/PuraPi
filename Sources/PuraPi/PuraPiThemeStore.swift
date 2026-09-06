import CryptoKit
import Foundation
import PiDomain

/// 一个已经通过校验的声明式主题包。
///
/// 这里只暴露资源 URL，不加载或执行包中的代码。主题包的资源未来可由渲染层按
/// 需要读取；当前版本只消费 `theme.json` 中的语义令牌。
struct PuraPiThemePackage: Identifiable, Equatable, Sendable {
    let definition: PuraPiThemeDefinition
    let packageURL: URL
    let previewURL: URL?
    let assetURLs: [String: URL]
    let checksum: String
    let checksumValidated: Bool
    let needsMigration: Bool

    var id: String { definition.id }
    var theme: PuraPiTheme { PuraPiTheme(definition: definition) }

    /// 兼容更直观的调用命名。
    var previewImageURL: URL? { previewURL }
    var assets: [String: URL] { assetURLs }
}

enum PuraPiThemeStoreError: LocalizedError, Equatable, Sendable {
    case invalidPackage(String)
    case packageNotFound(String)
    case unsupportedSchema(Int)
    case checksumMismatch(String)
    case unsafeResource(String)
    case resourceTooLarge(path: String, byteCount: Int)
    case cannotDeleteBuiltIn(String)
    case cannotDeleteLegacy(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let message): return "主题包无效：\(message)"
        case .packageNotFound(let id): return "找不到主题包：\(id)"
        case .unsupportedSchema(let version): return "不支持主题包 schemaVersion：\(version)"
        case .checksumMismatch(let path): return "主题包校验和不匹配：\(path)"
        case .unsafeResource(let path): return "主题包包含不安全资源路径：\(path)"
        case .resourceTooLarge(let path, let byteCount):
            return "主题包资源过大：\(path)（\(byteCount) bytes）"
        case .cannotDeleteBuiltIn(let id): return "不能删除内置主题：\(id)"
        case .cannotDeleteLegacy(let id): return "不能直接删除旧版主题，请先导入到 PuraPi：\(id)"
        case .io(let message): return "主题包读写失败：\(message)"
        }
    }
}

/// 用户主题包的安全存储。
///
/// `.purapitheme` 只是一种数据目录：加载器不会调用 `Process`、动态加载库、
/// 执行脚本，也不会把主题包路径当成工作区或 Pi 权限来源。所有文件都会经过
/// 路径、符号链接、大小、权限、schema 和可选 checksum 校验。
struct PuraPiThemeStore: Sendable {
    static let packageExtension = "purapitheme"
    static let currentSchemaVersion = 1

    static var defaultDirectoryURL: URL {
        applicationSupportURL
            .appendingPathComponent("PuraPi", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    /// 旧版主题目录只读兼容；新导入始终写入 PuraPi 目录。
    static var legacyDirectoryURL: URL {
        applicationSupportURL
            .appendingPathComponent(
                PuraPiLegacyIdentifiers.themesDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("Themes", isDirectory: true)
    }

    private static var applicationSupportURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    let directoryURL: URL
    private let legacyDirectoryURLOverride: URL?
    let maximumThemeJSONBytes: Int
    let maximumPreviewBytes: Int
    let maximumAssetBytes: Int
    let maximumTotalAssetBytes: Int

    init(
        directoryURL: URL = PuraPiThemeStore.defaultDirectoryURL,
        legacyDirectoryURL: URL? = nil,
        maximumThemeJSONBytes: Int = 256 * 1024,
        maximumPreviewBytes: Int = 5 * 1024 * 1024,
        maximumAssetBytes: Int = 20 * 1024 * 1024,
        maximumTotalAssetBytes: Int = 64 * 1024 * 1024
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.legacyDirectoryURLOverride = legacyDirectoryURL?.standardizedFileURL
        self.maximumThemeJSONBytes = max(1, maximumThemeJSONBytes)
        self.maximumPreviewBytes = max(1, maximumPreviewBytes)
        self.maximumAssetBytes = max(1, maximumAssetBytes)
        self.maximumTotalAssetBytes = max(1, maximumTotalAssetBytes)
    }

    /// 扫描用户主题目录；无效包会被跳过，不影响内置主题和其它有效包。
    /// 旧版 WorkPi 目录和 `.workpitheme` 扩展名只用于读取，PuraPi 目录优先。
    func scan() -> [PuraPiThemePackage] {
        var packagesByID: [String: PuraPiThemePackage] = [:]
        for directory in scanDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where Self.acceptedPackageExtensions.contains(entry.pathExtension.lowercased()) {
                guard let package = try? loadPackage(at: entry),
                      packagesByID[package.id] == nil
                else { continue }
                packagesByID[package.id] = package
            }
        }

        return packagesByID.values.sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    /// `scan` 的语义别名，方便设置页和导入逻辑表达意图。
    func packages() -> [PuraPiThemePackage] { scan() }

    func loadPackage(id: String) throws -> PuraPiThemePackage {
        guard isValidThemeID(id) else {
            throw PuraPiThemeStoreError.invalidPackage("主题 id 不合法")
        }
        for directory in scanDirectories {
            for extensionName in Self.acceptedPackageExtensions {
                let url = directory.appendingPathComponent(
                    "\(id).\(extensionName)",
                    isDirectory: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    return try loadPackage(at: url)
                }
            }
        }
        throw PuraPiThemeStoreError.packageNotFound(id)
    }

    func loadPackage(at url: URL) throws -> PuraPiThemePackage {
        let packageURL = url.standardizedFileURL
        guard Self.acceptedPackageExtensions.contains(packageURL.pathExtension.lowercased()) else {
            throw PuraPiThemeStoreError.invalidPackage(
                "目录必须以 .\(Self.packageExtension) 或 .\(PuraPiLegacyIdentifiers.themePackageExtension) 结尾"
            )
        }
        guard isDirectory(packageURL), !isSymbolicLink(packageURL) else {
            throw PuraPiThemeStoreError.unsafeResource(packageURL.path)
        }

        let packageID = packageURL.deletingPathExtension().lastPathComponent
        guard isValidThemeID(packageID) else {
            throw PuraPiThemeStoreError.invalidPackage("目录名不是安全的主题 id")
        }

        let files = try enumerateFiles(in: packageURL)
        let allowedRootFiles: Set<String> = [
            "theme.json", "preview.png", "manifest.json", "checksums.json",
            "checksum.json", "checksum.sha256", "README.md", "LICENSE",
        ]
        guard files.keys.allSatisfy({
            allowedRootFiles.contains($0) || $0.hasPrefix("assets/")
        }) else {
            throw PuraPiThemeStoreError.invalidPackage("根目录包含未支持的文件")
        }
        let themeURL = packageURL.appendingPathComponent("theme.json")
        guard files["theme.json"] != nil else {
            throw PuraPiThemeStoreError.invalidPackage("缺少 theme.json")
        }
        let themeData = try readBoundedData(
            at: themeURL,
            maximumBytes: maximumThemeJSONBytes,
            relativePath: "theme.json"
        )
        let decoded = try decodeDefinition(themeData, expectedID: packageID)
        try validate(decoded.definition)

        let previewURL: URL?
        if let preview = files["preview.png"] {
            let data = try readBoundedData(
                at: preview,
                maximumBytes: maximumPreviewBytes,
                relativePath: "preview.png"
            )
            let pngSignature = [UInt8](data.prefix(8))
            guard pngSignature == [
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            ] else {
                throw PuraPiThemeStoreError.invalidPackage("preview.png 不是有效 PNG")
            }
            previewURL = preview
        } else {
            previewURL = nil
        }

        var assetURLs: [String: URL] = [:]
        var assetBytes = 0
        var assetCount = 0
        for (relativePath, fileURL) in files where relativePath.hasPrefix("assets/") {
            assetCount += 1
            guard assetCount <= 1_024 else {
                throw PuraPiThemeStoreError.invalidPackage("assets 文件数量超过 1024 个")
            }
            try validateResourceFile(fileURL, relativePath: relativePath)
            let attributes = try fileAttributes(fileURL, relativePath: relativePath)
            let byteCount = attributes[.size] as? NSNumber
            let size = byteCount?.intValue ?? 0
            guard size <= maximumAssetBytes else {
                throw PuraPiThemeStoreError.resourceTooLarge(
                    path: relativePath,
                    byteCount: size
                )
            }
            guard size <= maximumTotalAssetBytes - assetBytes else {
                throw PuraPiThemeStoreError.resourceTooLarge(
                    path: "assets/",
                    byteCount: assetBytes + size
                )
            }
            assetBytes += size
            assetURLs[String(relativePath.dropFirst("assets/".count))] = fileURL
        }

        let declaredChecksums = try readDeclaredChecksums(
            in: packageURL,
            files: files
        )
        if let declaredChecksums {
            try verifyChecksums(declaredChecksums, files: files)
        }
        let aggregateChecksum = try aggregateChecksum(files: files)

        return PuraPiThemePackage(
            definition: decoded.definition,
            packageURL: packageURL,
            previewURL: previewURL,
            assetURLs: assetURLs,
            checksum: aggregateChecksum,
            checksumValidated: declaredChecksums != nil,
            needsMigration: decoded.needsMigration
        )
    }

    /// 返回内置主题加上所有通过校验的用户主题。
    func themes() -> [PuraPiTheme] {
        let builtInIDs = Set(PuraPiThemeCatalog.builtInThemes.map(\.id))
        let external = scan()
            .filter { !builtInIDs.contains(PuraPiThemeCatalog.canonicalID(for: $0.id)) }
            .map(\.theme)
        return PuraPiThemeCatalog.builtInThemes + external
    }

    func theme(for id: String) -> PuraPiTheme {
        let canonicalID = PuraPiThemeCatalog.canonicalID(for: id)
        return themes().first(where: { $0.id == canonicalID }) ?? .default
    }

    /// 将一个外部主题包安全复制到用户主题目录，并替换同 id 的旧包。
    @discardableResult
    func merge(packageAt sourceURL: URL) throws -> PuraPiThemePackage {
        let source = try loadPackage(at: sourceURL)
        guard !PuraPiThemeCatalog.builtInThemes.contains(where: {
            $0.id == PuraPiThemeCatalog.canonicalID(for: source.id)
        }) else {
            throw PuraPiThemeStoreError.invalidPackage("用户包不能覆盖内置主题")
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let destination = directoryURL.appendingPathComponent(
            "\(source.id).\(Self.packageExtension)",
            isDirectory: true
        )
        if destination.standardizedFileURL == source.packageURL.standardizedFileURL {
            return try migrate(packageAt: destination)
        }

        let temporary = directoryURL.appendingPathComponent(
            ".purapi-import-\(UUID().uuidString).\(Self.packageExtension)",
            isDirectory: true
        )
        let backup = directoryURL.appendingPathComponent(
            ".purapi-backup-\(UUID().uuidString).\(Self.packageExtension)",
            isDirectory: true
        )
        let fileManager = FileManager.default
        do {
            try fileManager.copyItem(at: source.packageURL, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            let result = try migrate(packageAt: destination)
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            return result
        } catch {
            try? fileManager.removeItem(at: temporary)
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.removeItem(at: destination)
                try? fileManager.moveItem(at: backup, to: destination)
            } else {
                try? fileManager.removeItem(at: destination)
            }
            if let storeError = error as? PuraPiThemeStoreError {
                throw storeError
            }
            throw PuraPiThemeStoreError.io(error.localizedDescription)
        }
    }

    /// 对 schema 0 或缺省 schema 的包执行显式迁移；读取本身不会改写用户文件。
    @discardableResult
    func migrate(packageAt url: URL) throws -> PuraPiThemePackage {
        let package = try loadPackage(at: url)
        guard package.needsMigration else { return package }
        let data = try JSONEncoder.puraPiThemeEncoder.encode(package.definition)
        let target = package.packageURL.appendingPathComponent("theme.json")
        let originalThemeData = try readBoundedData(
            at: target,
            maximumBytes: maximumThemeJSONBytes,
            relativePath: "theme.json"
        )
        let checksumFiles: [(URL, Data?)] = [
            "manifest.json", "checksums.json", "checksum.json", "checksum.sha256",
        ].compactMap {
            let fileURL = package.packageURL.appendingPathComponent($0)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return (
                fileURL,
                try? readBoundedData(
                    at: fileURL,
                    maximumBytes: maximumThemeJSONBytes,
                    relativePath: $0
                )
            )
        }
        let temporary = package.packageURL.appendingPathComponent(
            ".theme-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            try updateDeclaredThemeChecksumIfNeeded(
                in: package.packageURL,
                data: data
            )
            return try loadPackage(at: package.packageURL)
        } catch let error as PuraPiThemeStoreError {
            try? originalThemeData.write(
                to: target,
                options: Data.WritingOptions.atomic
            )
            for (fileURL, originalData) in checksumFiles {
                if let originalData {
                    try? originalData.write(
                        to: fileURL,
                        options: Data.WritingOptions.atomic
                    )
                }
            }
            throw error
        } catch {
            try? originalThemeData.write(
                to: target,
                options: Data.WritingOptions.atomic
            )
            for (fileURL, originalData) in checksumFiles {
                if let originalData {
                    try? originalData.write(
                        to: fileURL,
                        options: Data.WritingOptions.atomic
                    )
                }
            }
            throw PuraPiThemeStoreError.io(error.localizedDescription)
        }
    }

    /// 删除用户主题；内置主题和目录外路径都不能被删除。
    func delete(id: String) throws {
        guard !PuraPiThemeCatalog.builtInThemes.contains(where: {
            $0.id == PuraPiThemeCatalog.canonicalID(for: id)
        }) else {
            throw PuraPiThemeStoreError.cannotDeleteBuiltIn(id)
        }
        guard isValidThemeID(id) else {
            throw PuraPiThemeStoreError.invalidPackage("主题 id 不合法")
        }
        guard let packageURL = packageURL(for: id) else {
            throw PuraPiThemeStoreError.packageNotFound(id)
        }
        guard isDirectory(packageURL), !isSymbolicLink(packageURL) else {
            throw PuraPiThemeStoreError.unsafeResource(packageURL.path)
        }
        guard isInside(packageURL, root: directoryURL) else {
            throw PuraPiThemeStoreError.cannotDeleteLegacy(id)
        }
        do {
            try FileManager.default.removeItem(at: packageURL)
        } catch {
            throw PuraPiThemeStoreError.io(error.localizedDescription)
        }
    }

    private static let acceptedPackageExtensions = [
        packageExtension,
        PuraPiLegacyIdentifiers.themePackageExtension,
    ]

    private var scanDirectories: [URL] {
        var result = [directoryURL]
        let legacyDirectory = legacyDirectoryURLOverride
            ?? (directoryURL == Self.defaultDirectoryURL ? Self.legacyDirectoryURL : nil)
        if let legacyDirectory, legacyDirectory != directoryURL {
            result.append(legacyDirectory)
        }
        return result
    }

    private func packageURL(for id: String) -> URL? {
        for directory in scanDirectories {
            for extensionName in Self.acceptedPackageExtensions {
                let candidate = directory.appendingPathComponent(
                    "\(id).\(extensionName)",
                    isDirectory: true
                )
                guard isInside(candidate, root: directory),
                      FileManager.default.fileExists(atPath: candidate.path)
                else { continue }
                return candidate
            }
        }
        return nil
    }

    // MARK: - 校验

    private func decodeDefinition(
        _ data: Data,
        expectedID: String
    ) throws -> (definition: PuraPiThemeDefinition, needsMigration: Bool) {
        guard var object = try? JSONSerialization.jsonObject(with: data),
              var dictionary = object as? [String: Any]
        else {
            throw PuraPiThemeStoreError.invalidPackage("theme.json 不是 JSON 对象")
        }
        let rawSchema = (dictionary["schemaVersion"] as? NSNumber)?.intValue ?? 0
        guard rawSchema >= 0, rawSchema <= Self.currentSchemaVersion else {
            throw PuraPiThemeStoreError.unsupportedSchema(rawSchema)
        }
        let needsMigration = rawSchema < Self.currentSchemaVersion
        if needsMigration { dictionary["schemaVersion"] = Self.currentSchemaVersion }
        object = dictionary
        let normalized: Data
        do {
            normalized = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        } catch {
            throw PuraPiThemeStoreError.invalidPackage("theme.json 无法规范化")
        }
        do {
            let definition = try JSONDecoder().decode(
                PuraPiThemeDefinition.self,
                from: normalized
            )
            guard definition.id == expectedID else {
                throw PuraPiThemeStoreError.invalidPackage("theme id 与目录名不一致")
            }
            return (definition, needsMigration)
        } catch let error as PuraPiThemeStoreError {
            throw error
        } catch {
            throw PuraPiThemeStoreError.invalidPackage(
                "theme.json 缺少必需字段：\(error.localizedDescription)"
            )
        }
    }

    private func validate(_ definition: PuraPiThemeDefinition) throws {
        guard definition.schemaVersion == Self.currentSchemaVersion else {
            throw PuraPiThemeStoreError.unsupportedSchema(definition.schemaVersion)
        }
        guard isValidThemeID(definition.id) else {
            throw PuraPiThemeStoreError.invalidPackage("主题 id 只能包含字母、数字、点、短横线和下划线")
        }
        guard definition.names.values.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw PuraPiThemeStoreError.invalidPackage("至少需要一个非空主题名称")
        }
        try validate(definition.colors)
        let metrics = definition.metrics
        guard metrics.chromeCornerRadius.isFinite,
              metrics.chromeCornerRadius >= 0,
              metrics.chromeCornerRadius <= 100,
              metrics.paneTintOpacity.isFinite,
              (0...1).contains(metrics.paneTintOpacity),
              metrics.panelBorderWidth.isFinite,
              metrics.panelBorderWidth >= 0,
              metrics.panelBorderWidth <= 20,
              metrics.smallControlCornerRadius.isFinite,
              metrics.smallControlCornerRadius >= 0,
              metrics.smallControlCornerRadius <= 50
        else {
            throw PuraPiThemeStoreError.invalidPackage("主题视觉指标超出安全范围")
        }
    }

    private func validate(_ colors: PuraPiThemeColors) throws {
        for token in [
            colors.accent, colors.hairline, colors.windowBackground,
            colors.workspaceBackground, colors.contentBackground, colors.panelBorder,
            colors.searchBarBackground, colors.success, colors.warning, colors.error,
            colors.info,
        ] {
            guard token.opacity.isFinite, (0...1).contains(token.opacity) else {
                throw PuraPiThemeStoreError.invalidPackage("颜色透明度必须在 0 到 1 之间")
            }
            if case .rgba(let rgba) = token.source {
                guard [rgba.red, rgba.green, rgba.blue, rgba.alpha].allSatisfy({
                    $0.isFinite && (0...1).contains($0)
                }) else {
                    throw PuraPiThemeStoreError.invalidPackage("RGBA 颜色通道必须在 0 到 1 之间")
                }
            }
        }
    }

    private func enumerateFiles(in root: URL) throws -> [String: URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: []
        ) else {
            throw PuraPiThemeStoreError.io("无法枚举主题包目录")
        }

        var files: [String: URL] = [:]
        for case let url as URL in enumerator {
            let item = url.standardizedFileURL
            guard isInside(item, root: root) else {
                throw PuraPiThemeStoreError.unsafeResource(item.path)
            }
            if isSymbolicLink(item) {
                throw PuraPiThemeStoreError.unsafeResource(relativePath(item, root: root))
            }
            let values = try? item.resourceValues(
                forKeys: Set([URLResourceKey.isDirectoryKey])
            )
            if values?.isDirectory == true { continue }
            let relative = relativePath(item, root: root)
            try validateResourceFile(item, relativePath: relative)
            files[relative] = item
        }
        return files
    }

    private func validateResourceFile(_ url: URL, relativePath: String) throws {
        guard isSafeRelativePath(relativePath) else {
            throw PuraPiThemeStoreError.unsafeResource(relativePath)
        }
        let lower = url.pathExtension.lowercased()
        let executableExtensions: Set<String> = [
            "app", "command", "dylib", "exe", "js", "node", "plugin", "scpt", "sh",
            "so", "swift", "swiftmodule", "wasm", "zsh",
        ]
        guard !executableExtensions.contains(lower) else {
            throw PuraPiThemeStoreError.unsafeResource(relativePath)
        }
        let attributes = try fileAttributes(url, relativePath: relativePath)
        if let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
           permissions & 0o111 != 0 {
            throw PuraPiThemeStoreError.unsafeResource(relativePath)
        }
    }

    private func readDeclaredChecksums(
        in root: URL,
        files: [String: URL]
    ) throws -> [String: String]? {
        var result: [String: String] = [:]
        let fileManager = FileManager.default

        let jsonManifestNames = ["manifest.json", "checksums.json", "checksum.json"]
        for name in jsonManifestNames where files[name] != nil {
            let data = try readBoundedData(
                at: root.appendingPathComponent(name),
                maximumBytes: maximumThemeJSONBytes,
                relativePath: name
            )
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any]
            else { throw PuraPiThemeStoreError.invalidPackage("\(name) 不是 JSON 对象") }
            var candidates = ["checksums", "files"].compactMap {
                dictionary[$0] as? [String: Any]
            }
            if candidates.isEmpty, name == "checksums.json" {
                candidates = [dictionary]
            }
            for candidate in candidates {
                for (path, value) in candidate {
                    guard let hash = value as? String else {
                        throw PuraPiThemeStoreError.invalidPackage("\(name) 中的校验和格式无效")
                    }
                    try mergeChecksum(hash, for: path, into: &result)
                }
            }
        }

        let checksumURL = root.appendingPathComponent("checksum.sha256")
        if fileManager.fileExists(atPath: checksumURL.path) {
            let data = try readBoundedData(
                at: checksumURL,
                maximumBytes: maximumThemeJSONBytes,
                relativePath: "checksum.sha256"
            )
            guard let text = String(data: data, encoding: .utf8) else {
                throw PuraPiThemeStoreError.invalidPackage("checksum.sha256 不是 UTF-8")
            }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(
                    maxSplits: 1,
                    whereSeparator: { $0.isWhitespace }
                )
                guard parts.count == 2 else { continue }
                let hash = String(parts[0])
                let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                try mergeChecksum(hash, for: path, into: &result)
            }
        }
        return result.isEmpty ? nil : result
    }

    private func mergeChecksum(
        _ rawHash: String,
        for rawPath: String,
        into checksums: inout [String: String]
    ) throws {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard isSafeRelativePath(path),
              rawHash.count == 64,
              rawHash.allSatisfy({ $0.isHexDigit })
        else { throw PuraPiThemeStoreError.unsafeResource(rawPath) }
        let hash = rawHash.lowercased()
        if let old = checksums[path], old != hash {
            throw PuraPiThemeStoreError.checksumMismatch(path)
        }
        checksums[path] = hash
    }

    private func verifyChecksums(
        _ checksums: [String: String],
        files: [String: URL]
    ) throws {
        for (path, expected) in checksums {
            guard let url = files[path] else {
                throw PuraPiThemeStoreError.checksumMismatch(path)
            }
            let data = try readBoundedData(
                at: url,
                maximumBytes: maximumBytes(for: path),
                relativePath: path
            )
            let actual = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            guard actual == expected else {
                throw PuraPiThemeStoreError.checksumMismatch(path)
            }
        }
    }

    private func aggregateChecksum(files: [String: URL]) throws -> String {
        var hasher = SHA256()
        for path in files.keys.sorted() {
            guard let url = files[path] else { continue }
            let data = try readBoundedData(
                at: url,
                maximumBytes: maximumBytes(for: path),
                relativePath: path
            )
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func maximumBytes(for relativePath: String) -> Int {
        if relativePath == "theme.json" || relativePath == "manifest.json"
            || relativePath == "checksums.json" || relativePath == "checksum.json"
            || relativePath == "checksum.sha256" {
            return maximumThemeJSONBytes
        }
        if relativePath == "preview.png" { return maximumPreviewBytes }
        return maximumAssetBytes
    }

    private func fileAttributes(
        _ url: URL,
        relativePath: String
    ) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw PuraPiThemeStoreError.io("无法读取 \(relativePath)")
        }
    }

    func readBoundedData(
        at url: URL,
        maximumBytes: Int,
        relativePath: String
    ) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let readCount = maximumBytes == Int.max ? Int.max : maximumBytes + 1
            let data = try handle.read(upToCount: readCount) ?? Data()
            guard data.count <= maximumBytes else {
                throw PuraPiThemeStoreError.resourceTooLarge(
                    path: relativePath,
                    byteCount: data.count
                )
            }
            return data
        } catch let error as PuraPiThemeStoreError {
            throw error
        } catch {
            throw PuraPiThemeStoreError.io("无法读取 \(relativePath)：\(error.localizedDescription)")
        }
    }

    private func isValidThemeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128,
              !id.hasPrefix("."), !id.hasSuffix(".")
        else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if rootPath == "/" {
            return path.hasPrefix("/")
        }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return String(path.dropFirst(prefix.count))
            .replacingOccurrences(of: "\\", with: "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

private extension JSONEncoder {
    static var puraPiThemeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
