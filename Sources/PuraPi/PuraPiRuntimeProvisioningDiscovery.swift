import Foundation

protocol PuraPiRuntimeProvisioningClient: Sendable {
    func discover() async -> PuraPiRuntimeDiscoverySnapshot
    func inspect(executableURL: URL) async throws -> PuraPiRuntimeInstallation
    func setPreferredExecutableURL(_ url: URL?)
    func install(
        progress: @escaping @Sendable (PuraPiRuntimeInstallPhase) -> Void
    ) async throws -> PuraPiRuntimeInstallation
}

/// 发现逻辑与 UI 分离，便于在没有真实 Pi 或网络的测试中验证候选路径和版本。
final class PuraPiDefaultRuntimeProvisioningClient: PuraPiRuntimeProvisioningClient, @unchecked Sendable {
    let locations: PuraPiRuntimeLocations
    let environment: [String: String]
    let homeDirectory: URL
    let runner: any PuraPiProcessRunner
    let downloader: any PuraPiArtifactDownloader
    let managedPiVersion: PuraPiRuntimeVersion
    let includeDefaultDirectories: Bool
    private let preferredPathLock = NSLock()
    private var preferredExecutablePath: URL?
    let managedStore: PuraPiRuntimeManagedStore

    init(
        locations: PuraPiRuntimeLocations = PuraPiRuntimeLocations(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: any PuraPiProcessRunner = PuraPiDefaultProcessRunner(),
        downloader: (any PuraPiArtifactDownloader)? = nil,
        managedPiVersion: PuraPiRuntimeVersion = PuraPiRuntimePolicy.managedPiVersion,
        includeDefaultDirectories: Bool = true,
        preferredExecutableURL: URL? = nil
    ) {
        self.locations = locations
        self.environment = environment
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.runner = runner
        self.downloader = downloader ?? PuraPiCurlArtifactDownloader(
            environment: PuraPiRuntimeEnvironment.safeEnvironment(
                base: environment,
                homeDirectory: homeDirectory
            )
        )
        self.managedPiVersion = managedPiVersion
        self.includeDefaultDirectories = includeDefaultDirectories
        self.preferredExecutablePath = preferredExecutableURL?.standardizedFileURL
        self.managedStore = PuraPiRuntimeManagedStore(locations: locations)
    }

    func setPreferredExecutableURL(_ url: URL?) {
        preferredPathLock.lock()
        preferredExecutablePath = url?.standardizedFileURL
        preferredPathLock.unlock()
    }

    private func preferredExecutableURLSnapshot() -> URL? {
        preferredPathLock.lock()
        defer { preferredPathLock.unlock() }
        return preferredExecutablePath
    }

    func discover() async -> PuraPiRuntimeDiscoverySnapshot {
        let node = await discoverNode()
        let candidates = PuraPiRuntimeCandidatePaths.piCandidates(
            environment: environment,
            homeDirectory: homeDirectory,
            managedStore: managedStore,
            includeDefaultDirectories: includeDefaultDirectories,
            preferredExecutableURL: preferredExecutableURLSnapshot()
        )
        var diagnostics: [String] = []
        var incompatible: PuraPiRuntimeInstallation?

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            guard PuraPiRuntimeCandidatePaths.isExecutable(candidate) else { continue }
            do {
                let result = try await runVersionProbe(
                    executable: candidate,
                    pathPrefixes: [
                        candidate.deletingLastPathComponent(),
                        node.info?.nodeURL.deletingLastPathComponent()
                    ].compactMap { $0 }
                )
                guard result.succeeded,
                      let version = PuraPiRuntimeVersion(result.stdoutText)
                else {
                    diagnostics.append("无法读取 \(candidate.path) 的版本。")
                    continue
                }
                let installation = PuraPiRuntimeInstallation(
                    executableURL: candidate.standardizedFileURL,
                    version: version,
                    source: managedStore.isManagedExecutable(candidate) ? .puraPiManaged : .existing,
                    nodeURL: node.info?.nodeURL
                )
                if version >= PuraPiRuntimePolicy.minimumSupportedPiVersion {
                    return PuraPiRuntimeDiscoverySnapshot(
                        installation: installation,
                        node: node,
                        diagnostics: diagnostics
                    )
                }
                incompatible = installation
                diagnostics.append("\(candidate.path) 版本为 \(version)，低于最低支持版本 \(PuraPiRuntimePolicy.minimumSupportedPiVersion)。")
            } catch {
                diagnostics.append("检查 \(candidate.path) 失败：\(error.localizedDescription)")
            }
        }

        return PuraPiRuntimeDiscoverySnapshot(
            installation: incompatible,
            node: node,
            diagnostics: diagnostics
        )
    }

    func inspect(executableURL: URL) async throws -> PuraPiRuntimeInstallation {
        guard PuraPiRuntimeCandidatePaths.isExecutable(executableURL) else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("所选文件不是可执行文件。")
        }
        let node = await discoverNode()
        let result = try await runVersionProbe(
            executable: executableURL,
            pathPrefixes: [
                executableURL.deletingLastPathComponent(),
                node.info?.nodeURL.deletingLastPathComponent()
            ].compactMap { $0 }
        )
        guard result.succeeded,
              let version = PuraPiRuntimeVersion(result.stdoutText)
        else {
            throw PuraPiRuntimeProvisioningError.verificationFailed("所选文件不是可用的 Pi Runtime。")
        }
        return PuraPiRuntimeInstallation(
            executableURL: executableURL.standardizedFileURL,
            version: version,
            source: .existing,
            nodeURL: node.info?.nodeURL
        )
    }

    func discoverNode() async -> PuraPiRuntimeNodeState {
        let candidates = PuraPiRuntimeCandidatePaths.nodeCandidates(
            environment: environment,
            homeDirectory: homeDirectory,
            managedStore: managedStore,
            includeDefaultDirectories: includeDefaultDirectories
        )
        var incompatible: PuraPiRuntimeNodeInfo?
        for nodeURL in candidates {
            guard !Task.isCancelled else { break }
            guard PuraPiRuntimeCandidatePaths.isExecutable(nodeURL) else { continue }
            do {
                let result = try await runVersionProbe(
                    executable: nodeURL,
                    pathPrefixes: [nodeURL.deletingLastPathComponent()]
                )
                guard result.succeeded,
                      let version = PuraPiRuntimeVersion(result.stdoutText)
                else { continue }
                let npmURL = PuraPiRuntimeCandidatePaths.npmURL(
                    beside: nodeURL,
                    environment: environment,
                    homeDirectory: homeDirectory,
                    includeDefaultDirectories: includeDefaultDirectories
                )
                let info = PuraPiRuntimeNodeInfo(
                    nodeURL: nodeURL.standardizedFileURL,
                    npmURL: npmURL,
                    version: version
                )
                guard let npmURL else {
                    incompatible = info
                    continue
                }
                guard let npmResult = try? await runVersionProbe(
                    executable: npmURL,
                    pathPrefixes: [nodeURL.deletingLastPathComponent()]
                ), npmResult.succeeded else {
                    incompatible = info
                    continue
                }
                if info.meetsMinimum {
                    return .available(info)
                }
                incompatible = info
            } catch {
                continue
            }
        }
        if let incompatible { return .incompatible(incompatible) }
        if let managed = managedStore.currentNode() {
            return .available(managed)
        }
        return .missing
    }

    func runVersionProbe(
        executable: URL,
        pathPrefixes: [URL]
    ) async throws -> PuraPiProcessResult {
        var path = PuraPiRuntimeEnvironment.environment(
            base: PuraPiRuntimeEnvironment.safeEnvironment(
                base: environment,
                homeDirectory: homeDirectory
            ),
            homeDirectory: homeDirectory,
            prepend: pathPrefixes.map(\.path)
        )
        path["PI_OFFLINE"] = "1"
        path["PI_SKIP_VERSION_CHECK"] = "1"
        path["PI_TELEMETRY"] = "0"
        return try await runner.run(PuraPiProcessRequest(
            executableURL: executable,
            arguments: ["--version"],
            environment: path,
            currentDirectoryURL: homeDirectory,
            timeout: 8,
            outputLimit: 8 * 1024
        ))
    }

    func requireExecutable(_ url: URL?, name: String) throws -> URL {
        guard let url, PuraPiRuntimeCandidatePaths.isExecutable(url) else {
            throw name == "npm"
                ? PuraPiRuntimeProvisioningError.npmMissing
                : PuraPiRuntimeProvisioningError.nodeMissing
        }
        return url
    }

    func safeDiagnostic(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        let selected = Array(lines.suffix(8)).joined(separator: "\n")
        return String(selected.prefix(2_000))
    }
}
