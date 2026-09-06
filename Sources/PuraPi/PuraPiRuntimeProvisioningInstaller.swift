import Foundation

extension PuraPiDefaultRuntimeProvisioningClient {
    func install(
        progress: @escaping @Sendable (PuraPiRuntimeInstallPhase) -> Void
    ) async throws -> PuraPiRuntimeInstallation {
        progress(.preparing)
        try Task.checkCancellation()
        try managedStore.prepareDirectories()

        let snapshot = await discoverNode()
        try Task.checkCancellation()
        let node: PuraPiRuntimeNodeInfo
        if case .available(let info) = snapshot {
            node = info
        } else {
            progress(.installingNode)
            node = try await installManagedNode()
        }
        try Task.checkCancellation()

        progress(.installingPi)
        let release = locations.piReleasesURL
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: release,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? fileManager.removeItem(at: release) }

        let npmURL = try requireExecutable(node.npmURL, name: "npm")
        let environment = PuraPiRuntimeEnvironment.environment(
            base: PuraPiRuntimeEnvironment.safeEnvironment(
                base: environment,
                homeDirectory: homeDirectory
            ),
            homeDirectory: homeDirectory,
            prepend: [node.nodeURL.deletingLastPathComponent().path]
        )
        let packageSpecifier = "\(PuraPiRuntimePolicy.piPackageName)@\(managedPiVersion)"
        let npmConfig = release.appendingPathComponent(".npmrc")
        let npmGlobalConfig = release.appendingPathComponent(".npm-globalrc")
        let npmCache = release.appendingPathComponent(".npm-cache", isDirectory: true)
        try Data("registry=https://registry.npmjs.org/\nignore-scripts=true\nfund=false\naudit=false\nupdate-notifier=false\n".utf8)
            .write(to: npmConfig, options: [.atomic])
        try Data("registry=https://registry.npmjs.org/\nignore-scripts=true\nfund=false\naudit=false\nupdate-notifier=false\n".utf8)
            .write(to: npmGlobalConfig, options: [.atomic])
        try fileManager.createDirectory(at: npmCache, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: npmConfig)
            try? fileManager.removeItem(at: npmGlobalConfig)
            try? fileManager.removeItem(at: npmCache)
        }
        let result: PuraPiProcessResult
        do {
            result = try await runner.run(PuraPiProcessRequest(
                executableURL: npmURL,
                arguments: [
                    "install",
                    "--global",
                    "--prefix", release.path,
                    "--ignore-scripts",
                    "--no-fund",
                    "--no-audit",
                    "--progress=false",
                    "--min-release-age=0",
                    "--registry", "https://registry.npmjs.org/",
                    "--userconfig", npmConfig.path,
                    "--globalconfig", npmGlobalConfig.path,
                    "--cache", npmCache.path,
                    packageSpecifier,
                ],
                environment: environment,
                currentDirectoryURL: release,
                timeout: 900,
                outputLimit: PuraPiRuntimePolicy.maxProcessOutputBytes
            ))
        } catch {
            throw PuraPiRuntimeProvisioningError.commandFailed(
                command: "npm install --global --ignore-scripts \(packageSpecifier)",
                detail: error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw PuraPiRuntimeProvisioningError.commandFailed(
                command: "npm install --global --ignore-scripts \(packageSpecifier)",
                detail: safeDiagnostic(result.diagnosticText)
            )
        }

        progress(.verifying)
        let stagedExecutable = release.appendingPathComponent("bin/pi")
        guard fileManager.isExecutableFile(atPath: stagedExecutable.path) else {
            throw PuraPiRuntimeProvisioningError.verificationFailed(
                "npm 完成后没有生成 pi 可执行文件。"
            )
        }
        let versionResult = try await runVersionProbe(
            executable: stagedExecutable,
            pathPrefixes: [
                stagedExecutable.deletingLastPathComponent(),
                node.nodeURL.deletingLastPathComponent()
            ]
        )
        guard versionResult.succeeded,
              let installedVersion = PuraPiRuntimeVersion(versionResult.stdoutText),
              installedVersion == managedPiVersion
        else {
            throw PuraPiRuntimeProvisioningError.verificationFailed(
                "安装后的 Pi 版本与已验证版本不一致。"
            )
        }
        // 临时 npm 配置和缓存不能随 release 一起保留，避免占用空间或让
        // 后续 Runtime 误读取安装期配置。
        try? fileManager.removeItem(at: npmConfig)
        try? fileManager.removeItem(at: npmGlobalConfig)
        try? fileManager.removeItem(at: npmCache)

        try Task.checkCancellation()
        progress(.activating)
        let finalRelease = locations.piReleasesURL
            .appendingPathComponent(managedPiVersion.description, isDirectory: true)
        if fileManager.fileExists(atPath: finalRelease.path) {
            guard managedStore.isValidPiRelease(at: finalRelease, version: managedPiVersion) else {
                throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
            }
            try fileManager.removeItem(at: release)
        } else {
            try fileManager.moveItem(at: release, to: finalRelease)
        }
        try managedStore.activatePi(
            version: managedPiVersion,
            nodeVersion: node.version
        )
        return PuraPiRuntimeInstallation(
            executableURL: finalRelease.appendingPathComponent("bin/pi"),
            version: managedPiVersion,
            source: .puraPiManaged,
            nodeURL: node.nodeURL
        )
    }

    private func installManagedNode() async throws -> PuraPiRuntimeNodeInfo {
        guard let architecture = PuraPiRuntimeCandidatePaths.nodeArchitecture else {
            throw PuraPiRuntimeProvisioningError.unsupportedPlatform
        }
        let fileManager = FileManager.default
        let staging = locations.rootURL
            .appendingPathComponent("node/staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let checksumURL = staging.appendingPathComponent("SHASUMS256.txt")
        let checksumRemote = PuraPiRuntimePolicy.nodeDownloadBaseURL
            .appendingPathComponent("SHASUMS256.txt")
        try await downloader.download(
            url: checksumRemote,
            to: checksumURL,
            maximumBytes: PuraPiRuntimePolicy.maxNodeChecksumBytes
        )
        guard let checksumData = PuraPiRuntimeBoundedFile.data(
            at: checksumURL,
            maximumBytes: PuraPiRuntimePolicy.maxNodeChecksumBytes
        ),
              let checksumText = String(data: checksumData, encoding: .utf8),
              let artifact = PuraPiNodeArtifact.parse(
                  checksumText: checksumText,
                  platform: "darwin",
                  architecture: architecture
              )
        else {
            throw PuraPiRuntimeProvisioningError.verificationFailed(
                "官方 Node.js 校验清单中没有适用于当前 Mac 的版本。"
            )
        }

        let archiveURL = staging.appendingPathComponent(artifact.fileName)
        let archiveRemote = PuraPiRuntimePolicy.nodeDownloadBaseURL
            .appendingPathComponent(artifact.fileName)
        try await downloader.download(
            url: archiveRemote,
            to: archiveURL,
            maximumBytes: PuraPiRuntimePolicy.maxNodeArchiveBytes
        )
        try PuraPiNodeArtifact.verify(archiveURL: archiveURL, expectedSHA256: artifact.sha256)
        try Task.checkCancellation()

        let listingResult = try await runner.run(PuraPiProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tf", archiveURL.path],
            environment: PuraPiRuntimeEnvironment.environment(
                base: PuraPiRuntimeEnvironment.safeEnvironment(
                    base: environment,
                    homeDirectory: homeDirectory
                ),
                homeDirectory: homeDirectory,
                prepend: []
            ),
            timeout: 180,
            outputLimit: 4 * 1024 * 1024
        ))
        guard listingResult.succeeded,
              !listingResult.stdoutWasTruncated,
              PuraPiNodeArchiveSafety.validate(
                  listing: listingResult.stdoutText,
                  expectedTopDirectoryPrefix: "node-v\(artifact.version)-"
              )
        else {
            throw PuraPiRuntimeProvisioningError.verificationFailed(
                "Node.js 压缩包包含不安全或无法验证的路径。"
            )
        }

        let extraction = staging.appendingPathComponent("extract", isDirectory: true)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
        let tarResult = try await runner.run(PuraPiProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xJf", archiveURL.path, "-C", extraction.path],
            environment: PuraPiRuntimeEnvironment.environment(
                base: environment,
                homeDirectory: homeDirectory,
                prepend: []
            ),
            timeout: 180,
            outputLimit: 64 * 1024
        ))
        guard tarResult.succeeded else {
            throw PuraPiRuntimeProvisioningError.commandFailed(
                command: "tar -xJf Node.js archive",
                detail: safeDiagnostic(tarResult.diagnosticText)
            )
        }
        let extracted = try validatedNodeDirectory(in: extraction, version: artifact.version)
        try Task.checkCancellation()
        let finalNode = locations.nodeDirectoryURL(for: artifact.version)
        if fileManager.fileExists(atPath: finalNode.path) {
            guard managedStore.isValidNodeRelease(at: finalNode, version: artifact.version) else {
                throw PuraPiRuntimeProvisioningError.unsafeManagedDirectory
            }
        } else {
            try fileManager.moveItem(at: extracted, to: finalNode)
        }
        try managedStore.activateNode(version: artifact.version)
        guard let node = managedStore.currentNode() else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("Node.js 启用后无法再次读取。")
        }
        return node
    }

    private func validatedNodeDirectory(in extraction: URL, version: PuraPiRuntimeVersion) throws -> URL {
        let fileManager = FileManager.default
        guard validateExtractedTree(in: extraction) else {
            throw PuraPiRuntimeProvisioningError.verificationFailed(
                "Node.js 压缩包包含指向目录外的符号链接。"
            )
        }
        let children = try fileManager.contentsOfDirectory(
            at: extraction,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let directories = children.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard directories.count == 1,
              let directory = directories.first,
              directory.lastPathComponent.hasPrefix("node-v\(version.description)-")
        else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("Node.js 压缩包目录结构不符合预期。")
        }
        guard fileManager.isExecutableFile(
            atPath: directory.appendingPathComponent("bin/node").path
        ) else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("Node.js 压缩包缺少可执行文件。")
        }
        return directory
    }

    private func validateExtractedTree(in root: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return false }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            ) else { return false }
            guard values.isSymbolicLink == true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(rootPath + "/") else { return false }
        }
        return true
    }
}

/// 只接受一个官方 Node.js 归档根目录，并拒绝绝对路径与路径穿越。
enum PuraPiNodeArchiveSafety {
    static func validate(
        listing: String,
        expectedTopDirectoryPrefix: String
    ) -> Bool {
        var topDirectory: String?
        var sawEntry = false
        for rawLine in listing.split(whereSeparator: \.isNewline) {
            let path = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.utf8.contains(0)
            else { return false }
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first,
                  first != "..",
                  !components.contains(".."),
                  first.hasPrefix(expectedTopDirectoryPrefix)
            else { return false }
            if let topDirectory, topDirectory != first {
                return false
            }
            topDirectory = String(first)
            sawEntry = true
        }
        return sawEntry
            && topDirectory?.hasPrefix(expectedTopDirectoryPrefix) == true
    }
}

struct PuraPiNodeArtifact: Equatable, Sendable {
    let version: PuraPiRuntimeVersion
    let fileName: String
    let sha256: String

    static func parse(
        checksumText: String,
        platform: String,
        architecture: String
    ) -> Self? {
        let suffix = "-\(platform)-\(architecture).tar.xz"
        var matches: [Self] = []
        for line in checksumText.split(whereSeparator: \.isNewline) {
            let parts = line.split { $0 == " " || $0 == "\t" }
            guard parts.count >= 2 else { continue }
            let checksum = String(parts[0]).lowercased()
            let fileName = String(parts[1])
            guard fileName.hasPrefix("node-v"),
                  fileName.hasSuffix(suffix),
                  !fileName.contains("/"),
                  !fileName.contains("\\"),
                  checksum.count == 64,
                  checksum.allSatisfy({ $0.isHexDigit })
            else { continue }
            let versionStart = fileName.index(fileName.startIndex, offsetBy: 6)
            let versionEnd = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
            guard versionStart < versionEnd else { continue }
            let versionText = String(fileName[versionStart..<versionEnd])
            guard let version = PuraPiRuntimeVersion(versionText),
                  version >= PuraPiRuntimePolicy.minimumNodeVersion,
                  versionText == version.description
            else {
                continue
            }
            matches.append(Self(version: version, fileName: fileName, sha256: checksum))
        }
        return matches.max { $0.version < $1.version }
    }
}

enum PuraPiRuntimeCandidatePaths {
    static let nodeArchitecture: String? = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
        #else
        return nil
        #endif
    }()

    static func piCandidates(
        environment: [String: String],
        homeDirectory: URL,
        managedStore: PuraPiRuntimeManagedStore,
        includeDefaultDirectories: Bool,
        preferredExecutableURL: URL? = nil
    ) -> [URL] {
        var candidates: [URL] = []
        // 与 PiExecutableResolver 一致：显式环境变量优先，其次是用户在
        // PuraPi 中选择并记住的路径，最后才是 PuraPi 自己的 release。
        if let override = environment["PI_EXECUTABLE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let preferredExecutableURL {
            candidates.append(preferredExecutableURL)
        }
        if let managed = managedStore.currentInstallation()?.executableURL {
            candidates.append(managed)
        }
        candidates.append(contentsOf: executableCandidates(
            name: "pi",
            environment: environment,
            homeDirectory: homeDirectory,
            includeDefaultDirectories: includeDefaultDirectories
        ))
        return Array(unique(candidates).prefix(32))
    }

    static func nodeCandidates(
        environment: [String: String],
        homeDirectory: URL,
        managedStore: PuraPiRuntimeManagedStore,
        includeDefaultDirectories: Bool
    ) -> [URL] {
        var candidates: [URL] = []
        if let managed = managedStore.currentNode()?.nodeURL {
            candidates.append(managed)
        }
        candidates.append(contentsOf: executableCandidates(
            name: "node",
            environment: environment,
            homeDirectory: homeDirectory,
            includeDefaultDirectories: includeDefaultDirectories
        ))
        return Array(unique(candidates).prefix(32))
    }

    static func npmURL(
        beside nodeURL: URL,
        environment: [String: String],
        homeDirectory: URL,
        includeDefaultDirectories: Bool
    ) -> URL? {
        let beside = nodeURL.deletingLastPathComponent().appendingPathComponent("npm")
        if isExecutable(beside) { return beside }
        return executableCandidates(
            name: "npm",
            environment: environment,
            homeDirectory: homeDirectory,
            includeDefaultDirectories: includeDefaultDirectories
        ).first(where: isExecutable)
    }

    static func executableCandidates(
        name: String,
        environment: [String: String],
        homeDirectory: URL,
        includeDefaultDirectories: Bool = true
    ) -> [URL] {
        unique(searchDirectories(
            environment: environment,
            homeDirectory: homeDirectory,
            includeDefaultDirectories: includeDefaultDirectories
        ).map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name)
        })
    }

    private static func searchDirectories(
        environment: [String: String],
        homeDirectory: URL,
        includeDefaultDirectories: Bool
    ) -> [String] {
        let home = homeDirectory.standardizedFileURL.path
        let pathEntries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let fixed = [
            "\(home)/.volta/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.asdf/shims",
            "\(home)/.mise/shims",
            "\(home)/.bun/bin",
            "\(home)/.pi/agent/bin",
            "\(home)/.local/share/pi-node/current/bin",
            "\(home)/Library/pnpm",
        ] + (includeDefaultDirectories ? [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
        ] : [])

        // GUI 启动的进程通常没有 nvm/fnm/mise 的 shell 初始化；扫描这些
        // 版本管理器的已存在 bin 目录，仍然只执行用户明确安装的文件。
        let managerRoots = [
            "\(home)/.nvm/versions/node",
            "\(home)/.fnm/node-versions",
            "\(home)/.local/share/mise/installs/node",
            "\(home)/.asdf/installs/nodejs",
        ]
        var managerBins: [String] = []
        for root in managerRoots {
            appendVersionManagerBins(from: root, to: &managerBins)
        }
        if includeDefaultDirectories {
            // Homebrew 的 `node@版本` 可能没有被链接到 bin，但其 opt 目录
            // 仍然是稳定的用户安装入口。
            for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children where child.lastPathComponent.hasPrefix("node") {
                    managerBins.append(child.appendingPathComponent("bin", isDirectory: true).path)
                }
            }
        }
        return uniquePaths(pathEntries + fixed + managerBins)
    }

    private static func appendVersionManagerBins(from root: String, to bins: inout [String]) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children.sorted(by: { $0.path < $1.path }).prefix(64) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let bin = child.appendingPathComponent("bin", isDirectory: true).path
            bins.append(bin)
            // fnm 的安装目录还会把可执行文件放在 installation/bin。
            let installationBin = child.appendingPathComponent("installation/bin", isDirectory: true).path
            bins.append(installationBin)
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            return seen.insert(normalized).inserted
        }
    }

    static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let normalized = url.standardizedFileURL.path
            return seen.insert(normalized).inserted
        }
    }
}
