import Foundation

protocol WorkPiRuntimeProvisioningClient: Sendable {
    func discover() async -> WorkPiRuntimeDiscoverySnapshot
    func inspect(executableURL: URL) async throws -> WorkPiRuntimeInstallation
    func setPreferredExecutableURL(_ url: URL?)
    func install(
        progress: @escaping @Sendable (WorkPiRuntimeInstallPhase) -> Void
    ) async throws -> WorkPiRuntimeInstallation
}

/// 发现逻辑与 UI 分离，便于在没有真实 Pi 或网络的测试中验证候选路径和版本。
final class WorkPiDefaultRuntimeProvisioningClient: WorkPiRuntimeProvisioningClient, @unchecked Sendable {
    let locations: WorkPiRuntimeLocations
    let environment: [String: String]
    let homeDirectory: URL
    let runner: any WorkPiProcessRunner
    let downloader: any WorkPiArtifactDownloader
    let managedPiVersion: WorkPiRuntimeVersion
    let includeDefaultDirectories: Bool
    private let preferredPathLock = NSLock()
    private var preferredExecutablePath: URL?
    let managedStore: WorkPiRuntimeManagedStore

    init(
        locations: WorkPiRuntimeLocations = WorkPiRuntimeLocations(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: any WorkPiProcessRunner = WorkPiDefaultProcessRunner(),
        downloader: (any WorkPiArtifactDownloader)? = nil,
        managedPiVersion: WorkPiRuntimeVersion = WorkPiRuntimePolicy.managedPiVersion,
        includeDefaultDirectories: Bool = true,
        preferredExecutableURL: URL? = nil
    ) {
        self.locations = locations
        self.environment = environment
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.runner = runner
        self.downloader = downloader ?? WorkPiCurlArtifactDownloader(
            environment: WorkPiRuntimeEnvironment.safeEnvironment(
                base: environment,
                homeDirectory: homeDirectory
            )
        )
        self.managedPiVersion = managedPiVersion
        self.includeDefaultDirectories = includeDefaultDirectories
        self.preferredExecutablePath = preferredExecutableURL?.standardizedFileURL
        self.managedStore = WorkPiRuntimeManagedStore(locations: locations)
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

    func discover() async -> WorkPiRuntimeDiscoverySnapshot {
        let node = await discoverNode()
        let candidates = WorkPiRuntimeCandidatePaths.piCandidates(
            environment: environment,
            homeDirectory: homeDirectory,
            managedStore: managedStore,
            includeDefaultDirectories: includeDefaultDirectories,
            preferredExecutableURL: preferredExecutableURLSnapshot()
        )
        var diagnostics: [String] = []
        var incompatible: WorkPiRuntimeInstallation?

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            guard WorkPiRuntimeCandidatePaths.isExecutable(candidate) else { continue }
            do {
                let result = try await runVersionProbe(
                    executable: candidate,
                    pathPrefixes: [
                        candidate.deletingLastPathComponent(),
                        node.info?.nodeURL.deletingLastPathComponent()
                    ].compactMap { $0 }
                )
                guard result.succeeded,
                      let version = WorkPiRuntimeVersion(result.stdoutText)
                else {
                    diagnostics.append("无法读取 \(candidate.path) 的版本。")
                    continue
                }
                let installation = WorkPiRuntimeInstallation(
                    executableURL: candidate.standardizedFileURL,
                    version: version,
                    source: managedStore.isManagedExecutable(candidate) ? .workPiManaged : .existing,
                    nodeURL: node.info?.nodeURL
                )
                if version >= WorkPiRuntimePolicy.minimumSupportedPiVersion {
                    return WorkPiRuntimeDiscoverySnapshot(
                        installation: installation,
                        node: node,
                        diagnostics: diagnostics
                    )
                }
                incompatible = installation
                diagnostics.append("\(candidate.path) 版本为 \(version)，低于最低支持版本 \(WorkPiRuntimePolicy.minimumSupportedPiVersion)。")
            } catch {
                diagnostics.append("检查 \(candidate.path) 失败：\(error.localizedDescription)")
            }
        }

        return WorkPiRuntimeDiscoverySnapshot(
            installation: incompatible,
            node: node,
            diagnostics: diagnostics
        )
    }

    func inspect(executableURL: URL) async throws -> WorkPiRuntimeInstallation {
        guard WorkPiRuntimeCandidatePaths.isExecutable(executableURL) else {
            throw WorkPiRuntimeProvisioningError.verificationFailed("所选文件不是可执行文件。")
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
              let version = WorkPiRuntimeVersion(result.stdoutText)
        else {
            throw WorkPiRuntimeProvisioningError.verificationFailed("所选文件不是可用的 Pi Runtime。")
        }
        return WorkPiRuntimeInstallation(
            executableURL: executableURL.standardizedFileURL,
            version: version,
            source: .existing,
            nodeURL: node.info?.nodeURL
        )
    }

    func discoverNode() async -> WorkPiRuntimeNodeState {
        let candidates = WorkPiRuntimeCandidatePaths.nodeCandidates(
            environment: environment,
            homeDirectory: homeDirectory,
            managedStore: managedStore,
            includeDefaultDirectories: includeDefaultDirectories
        )
        var incompatible: WorkPiRuntimeNodeInfo?
        for nodeURL in candidates {
            guard !Task.isCancelled else { break }
            guard WorkPiRuntimeCandidatePaths.isExecutable(nodeURL) else { continue }
            do {
                let result = try await runVersionProbe(
                    executable: nodeURL,
                    pathPrefixes: [nodeURL.deletingLastPathComponent()]
                )
                guard result.succeeded,
                      let version = WorkPiRuntimeVersion(result.stdoutText)
                else { continue }
                let npmURL = WorkPiRuntimeCandidatePaths.npmURL(
                    beside: nodeURL,
                    environment: environment,
                    homeDirectory: homeDirectory,
                    includeDefaultDirectories: includeDefaultDirectories
                )
                let info = WorkPiRuntimeNodeInfo(
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
    ) async throws -> WorkPiProcessResult {
        var path = WorkPiRuntimeEnvironment.environment(
            base: WorkPiRuntimeEnvironment.safeEnvironment(
                base: environment,
                homeDirectory: homeDirectory
            ),
            homeDirectory: homeDirectory,
            prepend: pathPrefixes.map(\.path)
        )
        path["PI_OFFLINE"] = "1"
        path["PI_SKIP_VERSION_CHECK"] = "1"
        path["PI_TELEMETRY"] = "0"
        return try await runner.run(WorkPiProcessRequest(
            executableURL: executable,
            arguments: ["--version"],
            environment: path,
            currentDirectoryURL: homeDirectory,
            timeout: 8,
            outputLimit: 8 * 1024
        ))
    }

    func requireExecutable(_ url: URL?, name: String) throws -> URL {
        guard let url, WorkPiRuntimeCandidatePaths.isExecutable(url) else {
            throw name == "npm"
                ? WorkPiRuntimeProvisioningError.npmMissing
                : WorkPiRuntimeProvisioningError.nodeMissing
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
