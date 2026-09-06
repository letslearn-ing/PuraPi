import CryptoKit
import Foundation
import XCTest
@testable import PuraPi
import WorkspaceKit

@MainActor
final class PuraPiRuntimeProvisioningTests: XCTestCase {
    func testLegacyManagedInstallationSourceDecodesIntoCurrentValue() throws {
        let data = Data("\"workPiManaged\"".utf8)
        let source = try JSONDecoder().decode(
            PuraPiRuntimeInstallationSource.self,
            from: data
        )
        XCTAssertEqual(source, .puraPiManaged)
    }

    func testVersionParserAcceptsCommonCLIOutputAndComparesSemver() {
        XCTAssertEqual(PuraPiRuntimeVersion("v24.19.0\n"), PuraPiRuntimeVersion(major: 24, minor: 19, patch: 0))
        XCTAssertEqual(PuraPiRuntimeVersion("pi 0.84.4 (darwin)"), PuraPiRuntimeVersion(major: 0, minor: 84, patch: 4))
        XCTAssertNil(PuraPiRuntimeVersion("24.19"))
        XCTAssertNil(PuraPiRuntimeVersion("unknown"))
        XCTAssertTrue(
            PuraPiRuntimeVersion(major: 22, minor: 19, patch: 0)
                >= PuraPiRuntimePolicy.minimumNodeVersion
        )
        XCTAssertLessThan(
            PuraPiRuntimeVersion(major: 0, minor: 84, patch: 3),
            PuraPiRuntimePolicy.managedPiVersion
        )
    }

    func testRenamedManagedStoreReadsLegacyRuntimeDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-runtime-new-\(UUID().uuidString)", isDirectory: true)
        let legacyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-runtime-legacy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: legacyRoot)
        }

        let locations = PuraPiRuntimeLocations(rootURL: root, legacyRootURL: legacyRoot)
        let legacyLocations = try XCTUnwrap(locations.legacyLocations)
        let legacyStore = PuraPiRuntimeManagedStore(locations: legacyLocations)
        let version = PuraPiRuntimePolicy.managedPiVersion
        try legacyStore.prepareDirectories()
        try makeExecutable(at: legacyLocations.piExecutableURL(for: version))
        try makeExecutable(at: legacyLocations.nodeExecutableURL(for: PuraPiRuntimePolicy.minimumNodeVersion))
        try makeExecutable(at: legacyLocations.npmExecutableURL(for: PuraPiRuntimePolicy.minimumNodeVersion))
        try legacyStore.activateNode(version: PuraPiRuntimePolicy.minimumNodeVersion)
        try legacyStore.activatePi(
            version: version,
            nodeVersion: PuraPiRuntimePolicy.minimumNodeVersion
        )

        let store = PuraPiRuntimeManagedStore(locations: locations)
        XCTAssertEqual(
            store.currentInstallation()?.executableURL,
            legacyLocations.piExecutableURL(for: version)
        )
        XCTAssertEqual(
            store.currentNode()?.nodeURL,
            legacyLocations.nodeExecutableURL(for: PuraPiRuntimePolicy.minimumNodeVersion)
        )
    }

    func testSelectionCarriesManagedNodePathIntoTransportEnvironment() {
        let installation = PuraPiRuntimeInstallation(
            executableURL: URL(fileURLWithPath: "/tmp/purapi/pi"),
            version: PuraPiRuntimePolicy.managedPiVersion,
            source: .puraPiManaged,
            nodeURL: URL(fileURLWithPath: "/tmp/purapi/node/bin/node")
        )
        let selection = PuraPiRuntimeSelection()
        selection.update(installation)
        let snapshot = selection.snapshot()

        XCTAssertEqual(snapshot.executableURL, installation.executableURL)
        XCTAssertTrue(snapshot.environmentOverrides["PATH"]?.hasPrefix("/tmp/purapi/node/bin") == true)
    }

    func testExplicitExecutableOverrideWinsOverRememberedPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-override-\(UUID().uuidString)", isDirectory: true)
        let preferred = try makeExecutable(at: root.appendingPathComponent("preferred/pi"))
        let override = try makeExecutable(at: root.appendingPathComponent("override/pi"))
        defer { try? FileManager.default.removeItem(at: root) }
        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: PuraPiRuntimeLocations(rootURL: root.appendingPathComponent("managed", isDirectory: true)),
            environment: ["PATH": root.path, "PI_EXECUTABLE": override.path],
            homeDirectory: root,
            runner: RuntimeProvisioningFakeRunner(),
            includeDefaultDirectories: false,
            preferredExecutableURL: preferred
        )

        let snapshot = await client.discover()
        XCTAssertEqual(snapshot.installation?.executableURL, override)
    }

    func testDiscoveryPrefersRememberedExecutableBeforePATH() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-preferred-\(UUID().uuidString)", isDirectory: true)
        let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
        let preferredBin = root.appendingPathComponent("preferred-bin", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(at: pathBin.appendingPathComponent("pi"))
        let preferred = try makeExecutable(at: preferredBin.appendingPathComponent("pi"))
        let runner = RuntimeProvisioningFakeRunner()
        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: PuraPiRuntimeLocations(rootURL: root.appendingPathComponent("managed", isDirectory: true)),
            environment: ["PATH": pathBin.path],
            homeDirectory: root,
            runner: runner,
            includeDefaultDirectories: false,
            preferredExecutableURL: preferred
        )

        let snapshot = await client.discover()
        XCTAssertEqual(snapshot.installation?.executableURL, preferred)

        let later = try makeExecutable(at: root.appendingPathComponent("later/pi"))
        client.setPreferredExecutableURL(later)
        let refreshed = await client.discover()
        XCTAssertEqual(refreshed.installation?.executableURL, later)
    }

    func testDiscoveryReusesExistingPiAndFindsNodeWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-discovery-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(at: bin.appendingPathComponent("pi"))
        try makeExecutable(at: bin.appendingPathComponent("node"))
        try makeExecutable(at: bin.appendingPathComponent("npm"))

        let runner = RuntimeProvisioningFakeRunner()
        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: PuraPiRuntimeLocations(rootURL: root.appendingPathComponent("managed", isDirectory: true)),
            environment: ["PATH": bin.path],
            homeDirectory: root,
            runner: runner,
            managedPiVersion: PuraPiRuntimePolicy.managedPiVersion
        )
        let snapshot = await client.discover()

        XCTAssertEqual(snapshot.installation?.executableURL, bin.appendingPathComponent("pi"))
        XCTAssertEqual(snapshot.installation?.source, .existing)
        XCTAssertEqual(snapshot.installation?.version, PuraPiRuntimePolicy.managedPiVersion)
        guard case .available(let node) = snapshot.node else {
            return XCTFail("应发现兼容的 Node.js 与 npm")
        }
        XCTAssertEqual(node.nodeURL, bin.appendingPathComponent("node"))
        XCTAssertEqual(node.npmURL, bin.appendingPathComponent("npm"))
        XCTAssertTrue(
            runner.requests.allSatisfy { $0.environment["PI_OFFLINE"] == "1" },
            "发现阶段只能执行离线版本探测"
        )
    }

    func testDiscoveryFindsOfficialUserLocalPiLocationsWithoutShellPATH() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-user-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = try makeExecutable(at: root.appendingPathComponent(".pi/agent/bin/pi"))
        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: PuraPiRuntimeLocations(rootURL: root.appendingPathComponent("managed", isDirectory: true)),
            environment: ["PATH": ""],
            homeDirectory: root,
            runner: RuntimeProvisioningFakeRunner(),
            includeDefaultDirectories: false
        )

        let snapshot = await client.discover()
        XCTAssertEqual(snapshot.installation?.executableURL, pi)
    }

    func testDiscoveryReportsMissingPiAndNodeSeparately() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RuntimeProvisioningFakeRunner()
        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: PuraPiRuntimeLocations(rootURL: root.appendingPathComponent("managed", isDirectory: true)),
            environment: ["PATH": root.path],
            homeDirectory: root,
            runner: runner,
            includeDefaultDirectories: false
        )
        let snapshot = await client.discover()

        XCTAssertNil(snapshot.installation)
        XCTAssertEqual(snapshot.node, .missing)
    }

    func testManagedInstallUsesUserDirectoryAndDoesNotReplaceExistingPi() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-install-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("existing-bin", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existingPi = try makeExecutable(
            at: bin.appendingPathComponent("pi"),
            contents: "#!/bin/sh\n# user installation\nexit 0\n"
        )
        try makeExecutable(at: bin.appendingPathComponent("node"))
        try makeExecutable(at: bin.appendingPathComponent("npm"))

        let runner = RuntimeProvisioningFakeRunner()
        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: PuraPiRuntimeLocations(rootURL: managed),
            environment: ["PATH": bin.path],
            homeDirectory: root,
            runner: runner
        )
        let installation = try await client.install { _ in }

        XCTAssertEqual(installation.source, .puraPiManaged)
        XCTAssertEqual(
            installation.executableURL,
            managed.appendingPathComponent("pi/releases/0.84.4/bin/pi")
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.executableURL.path))
        XCTAssertEqual(
            try String(contentsOf: existingPi, encoding: .utf8),
            "#!/bin/sh\n# user installation\nexit 0\n"
        )
        let stored = PuraPiRuntimeManagedStore(
            locations: PuraPiRuntimeLocations(rootURL: managed)
        ).currentInstallation()
        XCTAssertEqual(stored?.executableURL, installation.executableURL)
        XCTAssertEqual(stored?.version, installation.version)
        XCTAssertEqual(stored?.source, installation.source)
        XCTAssertTrue(
            runner.requests.contains { request in
                request.executableURL == bin.appendingPathComponent("npm")
                    && request.arguments.contains("--ignore-scripts")
                    && request.arguments.contains("--global")
                    && request.arguments.contains("--registry")
                    && request.arguments.contains("--userconfig")
                    && request.arguments.contains("--cache")
            }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installation.executableURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(".npmrc")
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installation.executableURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(".npm-cache")
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installation.executableURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(".npm-globalrc")
                    .path
            )
        )
        let rediscovered = await client.discover()
        XCTAssertEqual(rediscovered.installation?.source, .puraPiManaged)
        XCTAssertEqual(rediscovered.installation?.version, installation.version)
    }

    func testFailedPiInstallCleansStagingAndLeavesNoCurrentPointer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-failed-install-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(at: bin.appendingPathComponent("node"))
        try makeExecutable(at: bin.appendingPathComponent("npm"))
        let runner = RuntimeProvisioningFakeRunner()
        runner.installStatus = 1
        runner.installDiagnostic = "registry unavailable"
        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: PuraPiRuntimeLocations(rootURL: managed),
            environment: ["PATH": bin.path],
            homeDirectory: root,
            runner: runner,
            includeDefaultDirectories: false
        )

        do {
            _ = try await client.install { _ in }
            XCTFail("npm 失败时安装应抛出错误")
        } catch let error as PuraPiRuntimeProvisioningError {
            guard case .commandFailed = error else {
                return XCTFail("应返回 npm commandFailed，而不是其它终态")
            }
        }
        let store = PuraPiRuntimeManagedStore(locations: PuraPiRuntimeLocations(rootURL: managed))
        XCTAssertNil(store.currentInstallation())
        let releases = try FileManager.default.contentsOfDirectory(
            at: store.locations.piReleasesURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        XCTAssertTrue(releases.isEmpty)
    }

    func testInstallPreparesPrivateNodeWhenNoCompatibleNodeExists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-private-node-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = PuraPiRuntimeLocations(rootURL: root.appendingPathComponent("managed", isDirectory: true))
        let runner = RuntimeProvisioningFakeRunner()
        runner.createExtractedNode = true
        let downloader = RuntimeProvisioningFakeDownloader()
        let nodeVersion = runner.extractedNodeVersion
        let archiveName = "node-v\(nodeVersion)-darwin-arm64.tar.xz"
        let archivePayload = Data("test archive bytes".utf8)
        let digest = SHA256.hash(data: archivePayload)
            .map { String(format: "%02x", $0) }
            .joined()
        // 校验清单中的摘要必须对应测试归档内容。
        downloader.payloads["SHASUMS256.txt"] = Data(
            "\(digest)  \(archiveName)\n".utf8
        )
        downloader.payloads[archiveName] = archivePayload

        let client = PuraPiDefaultRuntimeProvisioningClient(
            locations: locations,
            environment: ["PATH": root.path],
            homeDirectory: root,
            runner: runner,
            downloader: downloader,
            includeDefaultDirectories: false
        )
        let installation = try await client.install { _ in }

        XCTAssertEqual(installation.version, PuraPiRuntimePolicy.managedPiVersion)
        XCTAssertEqual(installation.nodeURL, locations.nodeExecutableURL(for: nodeVersion))
        XCTAssertNotNil(
            PuraPiRuntimeManagedStore(locations: locations).currentNode()
        )
        XCTAssertTrue(
            downloader.requestedURLs.contains {
                $0.lastPathComponent == "SHASUMS256.txt"
            }
        )
    }

    func testManagedStoreRejectsSymlinkedReleaseDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-symlink-\(UUID().uuidString)", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let locations = PuraPiRuntimeLocations(rootURL: root.appendingPathComponent("managed", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try makeExecutable(at: outside.appendingPathComponent("bin/pi"))
        try FileManager.default.createDirectory(at: locations.piReleasesURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: locations.piReleasesURL.appendingPathComponent("0.84.4"),
            withDestinationURL: outside
        )
        try FileManager.default.createDirectory(at: locations.rootURL, withIntermediateDirectories: true)
        try Data("0.84.4\n".utf8).write(to: locations.currentPiVersionURL)

        XCTAssertNil(PuraPiRuntimeManagedStore(locations: locations).currentInstallation())
    }

    func testArchiveSafetyRejectsTraversalAndMixedTopLevelDirectories() {
        XCTAssertTrue(
            PuraPiNodeArchiveSafety.validate(
                listing: "node-v22.20.1-darwin-arm64/\nnode-v22.20.1-darwin-arm64/bin/node\n",
                expectedTopDirectoryPrefix: "node-v22.20.1-"
            )
        )
        XCTAssertFalse(
            PuraPiNodeArchiveSafety.validate(
                listing: "node-v22.20.1-darwin-arm64/bin/node\n../outside\n",
                expectedTopDirectoryPrefix: "node-v22.20.1-"
            )
        )
        XCTAssertFalse(
            PuraPiNodeArchiveSafety.validate(
                listing: "node-v22.20.1-darwin-arm64/bin/node\nother/bin/npm\n",
                expectedTopDirectoryPrefix: "node-v22.20.1-"
            )
        )
    }

    func testInstallerEnvironmentDropsSecretsAndNpmOverrides() {
        let environment = PuraPiRuntimeEnvironment.safeEnvironment(
            base: [
                "PATH": "/tmp/bin",
                "OPENAI_API_KEY": "secret",
                "NPM_CONFIG_REGISTRY": "https://evil.example",
                "NODE_OPTIONS": "--require evil",
                "DYLD_INSERT_LIBRARIES": "/tmp/debugger.dylib",
                "__XPC_DYLD_LIBRARY_PATH": "/tmp/debugger",
                "SAFE_VALUE": "kept",
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp/purapi-home")
        )
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["NPM_CONFIG_REGISTRY"])
        XCTAssertNil(environment["NODE_OPTIONS"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["__XPC_DYLD_LIBRARY_PATH"])
        XCTAssertEqual(environment["SAFE_VALUE"], "kept")
        XCTAssertTrue(environment["PATH"]?.contains("/tmp/bin") == true)
    }

    func testNodeArtifactParserSelectsHighestCompatibleDarwinArchive() {
        let text = """
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  node-v22.19.0-darwin-arm64.tar.xz
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  node-v22.20.1-darwin-arm64.tar.xz
        cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  node-v22.20.1-darwin-x64.tar.xz
        dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  node-v21.9.0-darwin-arm64.tar.xz
        """
        let artifact = PuraPiNodeArtifact.parse(
            checksumText: text,
            platform: "darwin",
            architecture: "arm64"
        )

        XCTAssertEqual(artifact?.version, PuraPiRuntimeVersion(major: 22, minor: 20, patch: 1))
        XCTAssertEqual(artifact?.fileName, "node-v22.20.1-darwin-arm64.tar.xz")
        XCTAssertEqual(artifact?.sha256, String(repeating: "b", count: 64))
    }

    func testNodeArtifactParserRejectsPathLikeFilenames() {
        let malicious = String(repeating: "a", count: 64)
            + "  node-v22.20.1/../../outside-darwin-arm64.tar.xz\n"
        XCTAssertNil(
            PuraPiNodeArtifact.parse(
                checksumText: malicious,
                platform: "darwin",
                architecture: "arm64"
            )
        )
    }

    func testCurlDownloaderRejectsNonOfficialArtifactURL() async throws {
        let runner = RuntimeProvisioningFakeRunner()
        let downloader = PuraPiCurlArtifactDownloader(runner: runner)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-rejected-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await downloader.download(
                url: URL(string: "https://example.com/node.tar.xz")!,
                to: destination,
                maximumBytes: 1_024
            )
            XCTFail("非官方地址不应下载")
        } catch let error as PuraPiRuntimeProvisioningError {
            guard case .network = error else {
                return XCTFail("应返回 network 错误")
            }
        }
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testNodeArtifactVerificationAcceptsMatchingDigestAndRejectsMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-node-digest-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("node.tar.xz")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("signed test payload".utf8)
        try payload.write(to: archive)
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertNoThrow(try PuraPiNodeArtifact.verify(archiveURL: archive, expectedSHA256: digest))
        XCTAssertThrowsError(
            try PuraPiNodeArtifact.verify(
                archiveURL: archive,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        )
    }

    func testDefaultProcessRunnerBoundsTimeoutAndCapturesOutput() async throws {
        let runner = PuraPiDefaultProcessRunner()
        let result = try await runner.run(PuraPiProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["hello"],
            timeout: 2,
            outputLimit: 32
        ))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdoutText, "hello")

        do {
            _ = try await runner.run(PuraPiProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.05,
                outputLimit: 32
            ))
            XCTFail("sleep 应超时")
        } catch let error as PuraPiProcessError {
            XCTAssertEqual(error, .timedOut(URL(fileURLWithPath: "/bin/sleep")))
        }
    }

    func testMissingExecutableMarksSessionAsWaitingForProvisioning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { _ in RuntimeProvisioningUnavailableTransport() }
        )
        session.openWorkspace(root)
        try await waitForRuntimeProvisioning {
            session.runtimeProvisioningRequired
        }
        XCTAssertTrue(session.canReconnectRuntime)
        XCTAssertTrue(session.lastError?.contains("找不到 Pi") == true)
    }

    func testCancellingInstallKeepsSecondInstallBehindStopBarrier() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = PuraPiRuntimeInstallation(
            executableURL: root.appendingPathComponent("pi"),
            version: PuraPiRuntimePolicy.managedPiVersion,
            source: .puraPiManaged,
            nodeURL: nil
        )
        let client = SlowRuntimeProvisioningClient(installation: installation)
        let provisioner = PuraPiRuntimeProvisioner(
            locations: PuraPiRuntimeLocations(rootURL: root),
            selection: PuraPiRuntimeSelection(),
            client: client
        )
        try await waitForRuntimeProvisioning {
            if case .missing = provisioner.availability { return true }
            return false
        }
        provisioner.install()
        try await waitForRuntimeProvisioning { client.installCount == 1 }
        provisioner.cancelInstall()
        provisioner.install()
        XCTAssertEqual(client.installCount, 1, "旧安装取消清理期间不能启动第二个安装")
        try await waitForRuntimeProvisioning { !provisioner.isCancellingInstall }
        XCTAssertEqual(client.installCount, 1)
    }

    func testProvisionerExposesInstallFailureAndKeepsRetryAvailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-failure-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = PuraPiRuntimeInstallation(
            executableURL: root.appendingPathComponent("pi"),
            version: PuraPiRuntimePolicy.managedPiVersion,
            source: .puraPiManaged,
            nodeURL: nil
        )
        let fakeClient = RuntimeProvisioningFakeClient(
            snapshot: PuraPiRuntimeDiscoverySnapshot(
                installation: nil,
                node: .missing,
                diagnostics: []
            ),
            installation: installation
        )
        fakeClient.installError = PuraPiRuntimeProvisioningError.network("测试网络失败")
        let provisioner = PuraPiRuntimeProvisioner(
            locations: PuraPiRuntimeLocations(rootURL: root),
            selection: PuraPiRuntimeSelection(),
            client: fakeClient
        )
        try await waitForRuntimeProvisioning {
            if case .missing = provisioner.availability { return true }
            return false
        }
        provisioner.install()
        try await waitForRuntimeProvisioning {
            if case .failed = provisioner.availability { return true }
            return false
        }
        XCTAssertTrue(provisioner.canInstall)
        guard case .failed(let error) = provisioner.availability else {
            return XCTFail("安装失败后应保留 failed 状态")
        }
        XCTAssertEqual(error, .network("测试网络失败"))
    }

    func testProvisionerPublishesDiscoveryAndInstallWithoutAutoInstalling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-provision-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = PuraPiRuntimeInstallation(
            executableURL: root.appendingPathComponent("pi"),
            version: PuraPiRuntimePolicy.managedPiVersion,
            source: .puraPiManaged,
            nodeURL: nil
        )
        let fakeClient = RuntimeProvisioningFakeClient(
            snapshot: PuraPiRuntimeDiscoverySnapshot(
                installation: nil,
                node: .missing,
                diagnostics: []
            ),
            installation: installation
        )
        let selection = PuraPiRuntimeSelection()
        let provisioner = PuraPiRuntimeProvisioner(
            locations: PuraPiRuntimeLocations(rootURL: root),
            selection: selection,
            client: fakeClient
        )

        try await waitForRuntimeProvisioning {
            if case .missing = provisioner.availability { return true }
            return false
        }
        XCTAssertEqual(fakeClient.installCount, 0)
        XCTAssertTrue(provisioner.canInstall)

        provisioner.install()
        try await waitForRuntimeProvisioning {
            provisioner.availability.isAvailable
        }
        XCTAssertEqual(fakeClient.installCount, 1)
        XCTAssertEqual(selection.currentExecutableURL(), installation.executableURL)
    }
}
