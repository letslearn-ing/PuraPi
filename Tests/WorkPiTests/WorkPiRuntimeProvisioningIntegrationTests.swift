import Foundation
import XCTest
@testable import WorkPi

/// 真实安装测试默认跳过：它会访问 npm/Node 官方下载站点，但永远只写临时目录。
final class WorkPiRuntimeProvisioningIntegrationTests: XCTestCase {
    func testOptInManagedRuntimeInstallIsAtomicAndRunnable() async throws {
        guard ProcessInfo.processInfo.environment["WORKPI_RUNTIME_INSTALL_TEST"] == "1" else {
            throw XCTSkip("设置 WORKPI_RUNTIME_INSTALL_TEST=1 才运行真实 Runtime 安装测试")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-runtime-install-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let forcePrivateNode = ProcessInfo.processInfo.environment["WORKPI_RUNTIME_PRIVATE_NODE_TEST"] == "1"
        let environment = forcePrivateNode
            ? [
                "PATH": "/usr/bin:/bin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            ]
            : ProcessInfo.processInfo.environment
        let client = WorkPiDefaultRuntimeProvisioningClient(
            locations: WorkPiRuntimeLocations(rootURL: root),
            environment: environment,
            homeDirectory: forcePrivateNode ? root : FileManager.default.homeDirectoryForCurrentUser,
            includeDefaultDirectories: !forcePrivateNode
        )
        let installation = try await client.install { _ in }

        XCTAssertEqual(installation.version, WorkPiRuntimePolicy.managedPiVersion)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.executableURL.path))
        let probeEnvironment = WorkPiRuntimeEnvironment.environment(
            base: WorkPiRuntimeEnvironment.safeEnvironment(
                base: environment,
                homeDirectory: forcePrivateNode ? root : FileManager.default.homeDirectoryForCurrentUser
            ),
            homeDirectory: forcePrivateNode ? root : FileManager.default.homeDirectoryForCurrentUser,
            prepend: [
                installation.executableURL.deletingLastPathComponent().path,
                installation.nodeURL?.deletingLastPathComponent().path,
            ].compactMap { $0 }
        )
        let probe = try await WorkPiDefaultProcessRunner().run(WorkPiProcessRequest(
            executableURL: installation.executableURL,
            arguments: ["--version"],
            environment: probeEnvironment,
            currentDirectoryURL: root,
            timeout: 10,
            outputLimit: 8 * 1024
        ))
        XCTAssertTrue(probe.succeeded)
        XCTAssertEqual(WorkPiRuntimeVersion(probe.stdoutText), installation.version)

        let rediscovered = await client.discover()
        XCTAssertEqual(rediscovered.installation?.source, .workPiManaged)
        XCTAssertEqual(rediscovered.installation?.version, installation.version)
    }
}
