import Foundation
import PiRPC
import XCTest
@testable import WorkPi

final class RuntimeProvisioningUnavailableTransport: PiRPCTransport, @unchecked Sendable {
    func start(in workspaceURL: URL) async throws -> AsyncThrowingStream<PiRPCTransportEvent, Error> {
        throw PiRPCError.executableNotFound("pi")
    }

    func send(_ command: PiRPCCommand) async throws {
        throw PiRPCError.notRunning
    }

    func stop() async {}
}

final class RuntimeProvisioningFakeRunner: WorkPiProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [WorkPiProcessRequest] = []
    var requests: [WorkPiProcessRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
    var versionOutput = "0.84.4\n"
    var nodeOutput = "v24.19.0\n"
    var npmOutput = "11.17.0\n"
    var installStatus: Int32 = 0
    var installDiagnostic = ""
    var createInstalledPi = true
    var createExtractedNode = false
    let extractedNodeVersion = WorkPiRuntimeVersion(major: 22, minor: 23, patch: 0)

    func run(_ request: WorkPiProcessRequest) async throws -> WorkPiProcessResult {
        record(request)

        let name = request.executableURL.lastPathComponent
        if name == "npm", request.arguments.contains("install") {
            if createInstalledPi,
               let prefixIndex = request.arguments.firstIndex(of: "--prefix"),
               request.arguments.indices.contains(prefixIndex + 1) {
                let prefix = URL(fileURLWithPath: request.arguments[prefixIndex + 1])
                let bin = prefix.appendingPathComponent("bin", isDirectory: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                let pi = bin.appendingPathComponent("pi")
                FileManager.default.createFile(
                    atPath: pi.path,
                    contents: Data("#!/bin/sh\nexit 0\n".utf8),
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
                )
            }
            return result(
                status: installStatus,
                stdout: "npm install\n",
                stderr: installDiagnostic
            )
        }
        if name == "node" {
            return result(status: 0, stdout: nodeOutput)
        }
        if name == "npm" {
            return result(status: 0, stdout: npmOutput)
        }
        if name == "pi" {
            return result(status: 0, stdout: versionOutput)
        }
        if name == "tar" {
            if request.arguments.contains("-tf"), createExtractedNode {
                return result(
                    status: 0,
                    stdout: "node-v\(extractedNodeVersion)-darwin-arm64/\nnode-v\(extractedNodeVersion)-darwin-arm64/bin/node\n"
                )
            }
            if createExtractedNode,
               let extractIndex = request.arguments.firstIndex(of: "-C"),
               request.arguments.indices.contains(extractIndex + 1) {
                let extraction = URL(fileURLWithPath: request.arguments[extractIndex + 1])
                let directory = extraction.appendingPathComponent(
                    "node-v\(extractedNodeVersion)-darwin-arm64",
                    isDirectory: true
                )
                try makeExecutable(at: directory.appendingPathComponent("bin/node"))
                try makeExecutable(at: directory.appendingPathComponent("bin/npm"))
            }
            return result(status: 0)
        }
        return result(status: 0)
    }

    private func record(_ request: WorkPiProcessRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    private func result(
        status: Int32,
        stdout: String = "",
        stderr: String = ""
    ) -> WorkPiProcessResult {
        WorkPiProcessResult(
            status: status,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8),
            stdoutWasTruncated: false,
            stderrWasTruncated: false
        )
    }
}

final class RuntimeProvisioningFakeDownloader: WorkPiArtifactDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestedURLs: [URL] = []
    var payloads: [String: Data] = [:]

    func download(url: URL, to destination: URL, maximumBytes: Int) async throws {
        guard let payload = recordAndGetPayload(for: url), payload.count <= maximumBytes else {
            throw WorkPiRuntimeProvisioningError.network("测试下载内容不存在")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: destination)
    }

    private func recordAndGetPayload(for url: URL) -> Data? {
        lock.lock()
        requestedURLs.append(url)
        let payload = payloads[url.lastPathComponent]
        lock.unlock()
        return payload
    }
}

final class SlowRuntimeProvisioningClient: WorkPiRuntimeProvisioningClient, @unchecked Sendable {
    let installation: WorkPiRuntimeInstallation
    private let lock = NSLock()
    private(set) var installCount = 0

    init(installation: WorkPiRuntimeInstallation) {
        self.installation = installation
    }

    func discover() async -> WorkPiRuntimeDiscoverySnapshot {
        WorkPiRuntimeDiscoverySnapshot(installation: nil, node: .missing, diagnostics: [])
    }

    func inspect(executableURL: URL) async throws -> WorkPiRuntimeInstallation {
        installation
    }

    func setPreferredExecutableURL(_ url: URL?) {}

    func install(
        progress: @escaping @Sendable (WorkPiRuntimeInstallPhase) -> Void
    ) async throws -> WorkPiRuntimeInstallation {
        incrementInstallCount()
        progress(.installingPi)
        try await Task.sleep(for: .milliseconds(500))
        return installation
    }

    private func incrementInstallCount() {
        lock.lock()
        installCount += 1
        lock.unlock()
    }
}

final class RuntimeProvisioningFakeClient: WorkPiRuntimeProvisioningClient, @unchecked Sendable {
    let snapshot: WorkPiRuntimeDiscoverySnapshot
    let installation: WorkPiRuntimeInstallation
    var installError: Error?
    private let lock = NSLock()
    private(set) var installCount = 0

    init(
        snapshot: WorkPiRuntimeDiscoverySnapshot,
        installation: WorkPiRuntimeInstallation
    ) {
        self.snapshot = snapshot
        self.installation = installation
    }

    func discover() async -> WorkPiRuntimeDiscoverySnapshot {
        snapshot
    }

    func inspect(executableURL: URL) async throws -> WorkPiRuntimeInstallation {
        installation
    }

    func setPreferredExecutableURL(_ url: URL?) {}

    func install(
        progress: @escaping @Sendable (WorkPiRuntimeInstallPhase) -> Void
    ) async throws -> WorkPiRuntimeInstallation {
        incrementInstallCount()
        progress(.installingPi)
        if let installError { throw installError }
        return installation
    }

    private func incrementInstallCount() {
        lock.lock()
        installCount += 1
        lock.unlock()
    }
}

@discardableResult
func makeExecutable(
    at url: URL,
    contents: String = "#!/bin/sh\nexit 0\n"
) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    fileManager.createFile(
        atPath: url.path,
        contents: Data(contents.utf8),
        attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
    )
    return url
}

func waitForRuntimeProvisioning(
    timeout: TimeInterval = 3,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Runtime 供应测试等待超时")
}
