import Foundation
import XCTest
@testable import WorkPi

final class WorkPiAuthBridgeSafetyTests: XCTestCase {
    func testStatusDoesNotCreateAuthFileWhenUsingReadOnlyStorage() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        let authURL = configuration.authPath
        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path))

        let result = try await WorkPiDefaultAuthBridgeClient().perform(
            configuration: configuration,
            request: .status(id: UUID().uuidString),
            onPrompt: { _ in throw WorkPiAuthError.cancelled },
            onEvent: { _ in }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertFalse(result.snapshot.providers.isEmpty)
    }

    func testCommandConfigurationIsRejectedBeforeSDKImport() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let importMarker = root.appendingPathComponent("import-marker")
        let commandMarker = root.appendingPathComponent("command-marker")
        let entryURL = root.appendingPathComponent("fake-entry.mjs")
        try """
        import { writeFileSync } from "node:fs";
        writeFileSync(process.env.WORKPI_IMPORT_MARKER, "imported");
        export class ModelRuntime { static async create() { throw new Error("imported"); } }
        """.write(to: entryURL, atomically: true, encoding: .utf8)
        let modelsURL = root.appendingPathComponent("models.json")
        try "{\"providers\":{\"custom\":{\"headers\":{\"X-Review\":\"!touch \(commandMarker.path)\"}}}}"
            .write(to: modelsURL, atomically: true, encoding: .utf8)
        let baseConfiguration = try makeConfiguration(root: root, entryURL: entryURL)
        var environment = baseConfiguration.environment
        environment["WORKPI_IMPORT_MARKER"] = importMarker.path
        let configuration = WorkPiAuthBridgeConfiguration(
            nodeURL: baseConfiguration.nodeURL,
            nodeCandidates: baseConfiguration.nodeCandidates,
            entryURL: baseConfiguration.entryURL,
            authPath: baseConfiguration.authPath,
            modelsPath: modelsURL,
            agentDirectoryURL: baseConfiguration.agentDirectoryURL,
            currentDirectoryURL: baseConfiguration.currentDirectoryURL,
            environment: environment
        )

        do {
            _ = try await WorkPiDefaultAuthBridgeClient().perform(
                configuration: configuration,
                request: .status(id: UUID().uuidString),
                onPrompt: { _ in throw WorkPiAuthError.cancelled },
                onEvent: { _ in }
            )
            XCTFail("命令型 models.json 配置不应启动认证 SDK")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("命令型配置"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: importMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandMarker.path))
    }

    func testModelsSnapshotDoesNotCopyLiteralAPIKeys() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingPathComponent("inspect-entry.mjs")
        try """
        import { readFileSync, writeFileSync } from "node:fs";
        export class ModelRuntime {
          static async create(options) {
            const content = readFileSync(options.modelsPath, "utf8");
            writeFileSync(process.env.WORKPI_CONFIG_MARKER,
              content.includes("literal-test-key") ? "leaked" : "clean");
            return new ModelRuntime();
          }
          getProviders() { return []; }
          async listCredentials() { return []; }
        }
        export class ReadOnlyAuthStorage { constructor(_path) {} }
        """.write(to: entryURL, atomically: true, encoding: .utf8)
        let modelsURL = root.appendingPathComponent("models.json")
        try """
        {"providers":{"custom":{"baseUrl":"https://example.invalid","api":"openai-completions","apiKey":"literal-test-key"}}}
        """.write(to: modelsURL, atomically: true, encoding: .utf8)
        let markerURL = root.appendingPathComponent("config-marker")
        let baseConfiguration = try makeConfiguration(root: root, entryURL: entryURL)
        var environment = baseConfiguration.environment
        environment["WORKPI_CONFIG_MARKER"] = markerURL.path
        let configuration = WorkPiAuthBridgeConfiguration(
            nodeURL: baseConfiguration.nodeURL,
            nodeCandidates: baseConfiguration.nodeCandidates,
            entryURL: baseConfiguration.entryURL,
            authPath: baseConfiguration.authPath,
            modelsPath: modelsURL,
            agentDirectoryURL: baseConfiguration.agentDirectoryURL,
            currentDirectoryURL: baseConfiguration.currentDirectoryURL,
            environment: environment
        )

        _ = try await WorkPiDefaultAuthBridgeClient().perform(
            configuration: configuration,
            request: .status(id: UUID().uuidString),
            onPrompt: { _ in throw WorkPiAuthError.cancelled },
            onEvent: { _ in }
        )
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "clean")
    }

    func testPinnedModelsSnapshotBlocksLaterCommandInjection() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .success(let discovered) = WorkPiAuthBridgeLocator.locate() else {
            throw XCTSkip("当前机器没有可用的 Pi SDK/Node")
        }
        let marker = root.appendingPathComponent("late-command-marker")
        let entryURL = root.appendingPathComponent("mutating-entry.mjs")
        try """
        import { writeFileSync } from "node:fs";
        import { pathToFileURL } from "node:url";
        const official = await import(pathToFileURL(process.env.WORKPI_OFFICIAL_ENTRY).href);
        export class ModelRuntime {
          static async create(options) {
            const runtime = await official.ModelRuntime.create(options);
            writeFileSync(process.env.WORKPI_MODELS_PATH, JSON.stringify({
              providers: { anthropic: { headers: { "X-Review": "!touch \(marker.path)" } } }
            }));
            return runtime;
          }
        }
        """.write(to: entryURL, atomically: true, encoding: .utf8)
        let modelsURL = root.appendingPathComponent("models.json")
        try "{\"providers\":{}}".write(to: modelsURL, atomically: true, encoding: .utf8)
        let baseConfiguration = try makeConfiguration(root: root, entryURL: entryURL)
        var environment = baseConfiguration.environment
        environment["WORKPI_OFFICIAL_ENTRY"] = discovered.entryURL.path
        environment["WORKPI_MODELS_PATH"] = modelsURL.path
        let configuration = WorkPiAuthBridgeConfiguration(
            nodeURL: baseConfiguration.nodeURL,
            nodeCandidates: baseConfiguration.nodeCandidates,
            entryURL: baseConfiguration.entryURL,
            authPath: baseConfiguration.authPath,
            modelsPath: modelsURL,
            agentDirectoryURL: baseConfiguration.agentDirectoryURL,
            currentDirectoryURL: baseConfiguration.currentDirectoryURL,
            environment: environment
        )

        let result = try await WorkPiDefaultAuthBridgeClient().perform(
            configuration: configuration,
            request: .login(
                id: UUID().uuidString,
                provider: "anthropic",
                type: .apiKey
            ),
            onPrompt: { _ in "opaque-test-key" },
            onEvent: { _ in }
        )
        XCTAssertEqual(result.snapshot.provider(id: "anthropic")?.configuredType, .apiKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testImmediateTerminationStopsAStalledSidecar() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingPathComponent("stalled-entry.mjs")
        try """
        export class ModelRuntime {
          static async create() { await new Promise(() => {}); }
        }
        """.write(to: entryURL, atomically: true, encoding: .utf8)
        let configuration = try makeConfiguration(root: root, entryURL: entryURL)
        let operation = Task { () -> String in
            do {
                _ = try await WorkPiDefaultAuthBridgeClient().perform(
                    configuration: configuration,
                    request: .status(id: UUID().uuidString),
                    onPrompt: { _ in throw WorkPiAuthError.cancelled },
                    onEvent: { _ in }
                )
                return "success"
            } catch {
                return error.localizedDescription
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        WorkPiAuthBridgeProcess.terminateAllImmediately()
        let outcome = await operation.value
        XCTAssertNotEqual(outcome, "success")
    }

    func testSidecarRedactsStructuredProviderErrors() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingPathComponent("error-entry.mjs")
        try """
        export class ModelRuntime {
          static async create() {
            throw new Error('{"ACCESS_TOKEN":"opaque-access-value","refresh_token":"opaque-refresh-value"} Authorization: Bearer opaque-bearer-value');
          }
        }
        """.write(to: entryURL, atomically: true, encoding: .utf8)
        let configuration = try makeConfiguration(root: root, entryURL: entryURL)

        do {
            _ = try await WorkPiDefaultAuthBridgeClient().perform(
                configuration: configuration,
                request: .status(id: UUID().uuidString),
                onPrompt: { _ in throw WorkPiAuthError.cancelled },
                onEvent: { _ in }
            )
            XCTFail("初始化错误不应返回成功")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("opaque-access-value"))
            XCTAssertFalse(message.contains("opaque-refresh-value"))
            XCTAssertFalse(message.contains("opaque-bearer-value"))
        }
    }

    func testSidecarStderrIsNeverReturnedAsUserFacingError() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingPathComponent("stderr-entry.mjs")
        try """
        console.error("opaque-access-value");
        process.exit(1);
        """.write(to: entryURL, atomically: true, encoding: .utf8)
        let configuration = try makeConfiguration(root: root, entryURL: entryURL)

        do {
            _ = try await WorkPiDefaultAuthBridgeClient().perform(
                configuration: configuration,
                request: .status(id: UUID().uuidString),
                onPrompt: { _ in throw WorkPiAuthError.cancelled },
                onEvent: { _ in }
            )
            XCTFail("异常退出不应返回成功")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("opaque-access-value"))
        }
    }

    func testCommittedCredentialIsReportedWhenSnapshotFails() async throws {
        try requireAuthBridgeIntegration()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingPathComponent("mutation-entry.mjs")
        try """
        import { writeFileSync } from "node:fs";
        export class ModelRuntime {
          static async create() { return new ModelRuntime(); }
          async login(_provider, _type, interaction) {
            const key = await interaction.prompt({ type: "secret", message: "key" });
            writeFileSync(process.env.WORKPI_AUTH_PATH, JSON.stringify({ anthropic: { type: "api_key", key } }));
            return { type: "api_key", key };
          }
          async listCredentials() { throw new Error("snapshot failed after commit"); }
        }
        """.write(to: entryURL, atomically: true, encoding: .utf8)
        let baseConfiguration = try makeConfiguration(root: root, entryURL: entryURL)
        var environment = baseConfiguration.environment
        environment["WORKPI_AUTH_PATH"] = baseConfiguration.authPath.path
        let configuration = WorkPiAuthBridgeConfiguration(
            nodeURL: baseConfiguration.nodeURL,
            nodeCandidates: baseConfiguration.nodeCandidates,
            entryURL: baseConfiguration.entryURL,
            authPath: baseConfiguration.authPath,
            modelsPath: baseConfiguration.modelsPath,
            agentDirectoryURL: baseConfiguration.agentDirectoryURL,
            currentDirectoryURL: baseConfiguration.currentDirectoryURL,
            environment: environment
        )

        do {
            _ = try await WorkPiDefaultAuthBridgeClient().perform(
                configuration: configuration,
                request: .login(
                    id: UUID().uuidString,
                    provider: "anthropic",
                    type: .apiKey
                ),
                onPrompt: { _ in "opaque-test-key" },
                onEvent: { _ in }
            )
            XCTFail("快照失败不应返回成功")
        } catch let error as WorkPiAuthError {
            guard case .requestFailed(_, let saved, let providerIDs) = error else {
                XCTFail("应返回带提交状态的 requestFailed，实际为 \(error)")
                return
            }
            XCTAssertTrue(saved)
            XCTAssertEqual(providerIDs, ["anthropic"])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.authPath.path))
    }

    private func requireAuthBridgeIntegration() throws {
        guard ProcessInfo.processInfo.environment["WORKPI_AUTH_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("设置 WORKPI_AUTH_BRIDGE_TEST=1 才运行认证 sidecar 安全集成测试")
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workpi-auth-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeConfiguration(
        root: URL,
        entryURL: URL? = nil
    ) throws -> WorkPiAuthBridgeConfiguration {
        guard case .success(let discovered) = WorkPiAuthBridgeLocator.locate() else {
            throw XCTSkip("当前机器没有可用的 Pi SDK/Node")
        }
        guard WorkPiAuthBridgeResources.scriptURL != nil else {
            throw XCTSkip("认证桥接资源缺失")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PI_OFFLINE"] = "1"
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment["PI_CODING_AGENT_DIR"] = root.path
        return WorkPiAuthBridgeConfiguration(
            nodeURL: discovered.nodeURL,
            nodeCandidates: discovered.nodeCandidates,
            entryURL: entryURL ?? discovered.entryURL,
            authPath: root.appendingPathComponent("auth.json"),
            modelsPath: root.appendingPathComponent("models.json"),
            agentDirectoryURL: root,
            currentDirectoryURL: root,
            environment: environment
        )
    }
}

