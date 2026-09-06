import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi
import WorkspaceKit

@MainActor
final class WorkPiExtensionUITests: XCTestCase {
    func testExtensionUIDialogsReturnNativeResultsExactlyOnce() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        let requests: [(String, String, WorkPiExtensionUIResult)] = [
            ("ui-select", "select", .value("允许")),
            ("ui-confirm", "confirm", .confirmed(true)),
            ("ui-input", "input", .value("输入内容")),
            ("ui-editor", "editor", .value("第一行\n第二行")),
        ]

        for (id, method, result) in requests {
            await transport.emit(.record(Self.extensionUIRequestRecord(
                id: id,
                method: method,
                options: method == "select" ? ["允许", "拒绝"] : [],
                prefill: method == "editor" ? "初始文本" : nil
            )))
            try await waitUntil { session.extensionUIRequest?.id == id }
            session.resolveExtensionUI(id, result)
            // 重复点击/重复消失回调不能产生第二个响应。
            session.resolveExtensionUI(id, result)
            try await waitUntil {
                await transport.sentCommands.filter {
                    $0.type == "extension_ui_response"
                        && $0.fields["id"]?.stringValue == id
                }.count == 1
            }
        }

        let responses = await transport.sentCommands.filter { $0.type == "extension_ui_response" }
        XCTAssertEqual(responses.count, requests.count)
        XCTAssertEqual(responses[0].fields["value"]?.stringValue, "允许")
        XCTAssertEqual(responses[1].fields["confirmed"]?.boolValue, true)
        XCTAssertEqual(responses[2].fields["value"]?.stringValue, "输入内容")
        XCTAssertEqual(responses[3].fields["value"]?.stringValue, "第一行\n第二行")
    }

    func testExtensionUIRequestsQueueAndIgnoreDuplicateIDs() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-first",
            method: "select",
            options: ["A", "B"]
        )))
        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-second",
            method: "confirm"
        )))
        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-first",
            method: "select",
            options: ["重复"]
        )))

        try await waitUntil { session.extensionUIRequest?.id == "ui-first" }
        session.resolveExtensionUI("ui-first", .value("A"))
        try await waitUntil { session.extensionUIRequest?.id == "ui-second" }
        session.resolveExtensionUI("ui-second", .confirmed(false))

        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "extension_ui_response" }.count == 2
        }
        let responses = await transport.sentCommands.filter { $0.type == "extension_ui_response" }
        XCTAssertEqual(responses.map { $0.fields["id"]?.stringValue }, ["ui-first", "ui-second"])
        XCTAssertEqual(responses[1].fields["confirmed"]?.boolValue, false)
    }

    func testStaleSheetResponseCannotResolveNextRequest() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-old",
            method: "confirm"
        )))
        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-new",
            method: "input"
        )))
        try await waitUntil { session.extensionUIRequest?.id == "ui-old" }

        session.resolveExtensionUI("ui-old", .confirmed(true))
        try await waitUntil { session.extensionUIRequest?.id == "ui-new" }
        session.resolveExtensionUI("ui-old", .value("错误的旧回调"))

        XCTAssertEqual(session.extensionUIRequest?.id, "ui-new")
        let responseCount = await transport.sentCommands.filter {
            $0.type == "extension_ui_response"
        }.count
        XCTAssertEqual(responseCount, 1)
        session.resolveExtensionUI("ui-new", .value("正确输入"))
        try await waitUntil {
            await transport.sentCommands.filter { $0.type == "extension_ui_response" }.count == 2
        }
    }

    func testExtensionUIQueueIsBoundedAndOverflowIsCancelled() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-active",
            method: "confirm"
        )))
        try await waitUntil { session.extensionUIRequest?.id == "ui-active" }
        for index in 0..<70 {
            await transport.emit(.record(Self.extensionUIRequestRecord(
                id: "ui-queued-\(index)",
                method: "input"
            )))
        }

        try await waitUntil {
            session.queuedExtensionUIRequests.count >= 64
        }
        try await waitUntil {
            await transport.sentCommands.filter {
                $0.type == "extension_ui_response"
                    && $0.fields["cancelled"]?.boolValue == true
            }.count == 6
        }
        let overflowResponses = await transport.sentCommands.filter {
            $0.type == "extension_ui_response"
                && $0.fields["cancelled"]?.boolValue == true
        }
        XCTAssertEqual(overflowResponses.count, 6)
        XCTAssertEqual(session.queuedExtensionUIRequests.count, 64)
    }

    func testQueuedExtensionUITimeoutStartsAtEnqueue() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-active",
            method: "confirm"
        )))
        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-queued-timeout",
            method: "input",
            timeout: 250
        )))
        try await waitUntil {
            session.extensionUIRequest?.id == "ui-active"
                && session.queuedExtensionUIRequests.map(\.id) == ["ui-queued-timeout"]
        }

        try await Task.sleep(for: .milliseconds(350))
        let responses = await transport.sentCommands.filter {
            $0.type == "extension_ui_response"
                && $0.fields["id"]?.stringValue == "ui-queued-timeout"
        }
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses[0].fields["cancelled"]?.boolValue == true)
        XCTAssertEqual(session.extensionUIRequest?.id, "ui-active")
    }

    func testExtensionUIRequestTimeoutCancelsWithoutBlockingRuntime() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-timeout",
            method: "input",
            timeout: 25
        )))

        try await waitUntil(timeout: 2) {
            await transport.sentCommands.contains(where: {
                $0.type == "extension_ui_response"
                    && $0.fields["id"]?.stringValue == "ui-timeout"
                    && $0.fields["cancelled"]?.boolValue == true
            })
        }
        XCTAssertNil(session.extensionUIRequest)
        XCTAssertTrue(session.runtimeReady)
    }

    func testAbortCancelsPendingExtensionUIRequests() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        session.draftPrompt = "触发扩展"
        session.submitPrompt()
        try await waitUntil {
            await transport.sentCommands.contains(where: { $0.type == "prompt" })
        }
        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-abort",
            method: "confirm"
        )))
        try await waitUntil { session.extensionUIRequest?.id == "ui-abort" }

        session.abort()
        try await waitUntil(timeout: 2) {
            let commands = await transport.sentCommands
            return commands.contains(where: {
                $0.type == "extension_ui_response"
                    && $0.fields["id"]?.stringValue == "ui-abort"
                    && $0.fields["cancelled"]?.boolValue == true
            }) && commands.contains(where: { $0.type == "abort" })
        }
        XCTAssertNil(session.extensionUIRequest)
    }

    func testClosingWorkspaceCancelsActiveAndQueuedExtensionUIRequests() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-close-active",
            method: "confirm"
        )))
        await transport.emit(.record(Self.extensionUIRequestRecord(
            id: "ui-close-queued",
            method: "input"
        )))
        try await waitUntil {
            session.extensionUIRequest?.id == "ui-close-active"
                && session.queuedExtensionUIRequests.map(\.id) == ["ui-close-queued"]
        }

        session.closeWorkspace()
        try await waitUntil(timeout: 2) {
            let responses = await transport.sentCommands.filter { $0.type == "extension_ui_response" }
            return responses.count == 2
        }
        let responses = await transport.sentCommands.filter { $0.type == "extension_ui_response" }
        XCTAssertEqual(responses.map { $0.fields["id"]?.stringValue }, ["ui-close-active", "ui-close-queued"])
        XCTAssertTrue(responses.allSatisfy { $0.fields["cancelled"]?.boolValue == true })
        XCTAssertNil(session.extensionUIRequest)
        XCTAssertTrue(session.extensionStatuses.isEmpty)
    }

    func testExtensionUIStatusNotificationAndWidgetStaySeparateFromRuntimeError() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)
        session.lastError = "保留的 Runtime 错误"

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("notice-1"),
            "method": .string("notify"),
            "message": .string("扩展通知"),
            "notifyType": .string("warning"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("status-1"),
            "method": .string("setStatus"),
            "statusKey": .string("extension"),
            "statusText": .string("处理中"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("widget-1"),
            "method": .string("setWidget"),
            "widgetKey": .string("extension"),
            "widgetLines": .array([.string("一"), .string("二")]),
        ])))

        try await waitUntil {
            session.extensionNotifications.count == 1
                && session.extensionStatuses["extension"] == "处理中"
                && session.extensionWidgets["extension"]?.lines == ["一", "二"]
        }
        XCTAssertEqual(session.lastError, "保留的 Runtime 错误")

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("status-2"),
            "method": .string("setStatus"),
            "statusKey": .string("extension"),
        ])))
        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("widget-2"),
            "method": .string("setWidget"),
            "widgetKey": .string("extension"),
        ])))
        try await waitUntil {
            session.extensionStatuses["extension"] == nil
                && session.extensionWidgets["extension"] == nil
        }
    }

    func testUnsupportedExtensionMethodIsCancelledAndVisible() async throws {
        let (session, transport, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try await startAndHandshake(session, transport, root)

        await transport.emit(.record(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("ui-unsupported"),
            "method": .string("custom"),
            "title": .string("Custom"),
        ])))
        try await waitUntil {
            (await transport.sentCommands).contains(where: { command in
                command.type == "extension_ui_response"
                    && command.fields["id"]?.stringValue == "ui-unsupported"
                    && command.fields["cancelled"]?.boolValue == true
            })
        }
        XCTAssertEqual(session.lastError, "Pi Extension 请求了 Pura Pi 尚未支持的 UI 方法：custom")
    }

    func testRealPiRPC02ExtensionUIProtocol() async throws {
        guard ProcessInfo.processInfo.environment["WORKPI_REAL_RPC_TEST"] == "1" else {
            throw XCTSkip("Set WORKPI_REAL_RPC_TEST=1 to run the real Pi Extension UI integration test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-real-extension-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let extensionURL = root.appendingPathComponent("extension-ui-probe.ts")
        let resultURL = root.appendingPathComponent("extension-ui-result.json")
        try Self.realExtensionUISource(resultPath: resultURL.path)
            .write(to: extensionURL, atomically: true, encoding: .utf8)

        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: {
                PiRPCProcessTransport(
                    processArguments: [
                        "--mode", "rpc",
                        "--no-session",
                        "--no-extensions",
                        "--no-skills",
                        "--no-prompt-templates",
                        "--no-context-files",
                        "--extension", extensionURL.path,
                    ],
                    environmentOverrides: [
                        "PI_SKIP_VERSION_CHECK": "1",
                        "PI_OFFLINE": "1",
                    ]
                )
            }
        )
        defer { session.closeWorkspace() }

        session.openWorkspace(root)
        try await waitUntil(timeout: 30) { session.runtimeStatus == "Pi Runtime 已连接" }
        session.draftPrompt = "/workpi-ui-test"
        session.submitPrompt()

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let request = session.extensionUIRequest {
                switch request.method {
                case "select": session.resolveExtensionUI(request.id, .value("允许"))
                case "confirm": session.resolveExtensionUI(request.id, .confirmed(true))
                case "input": session.resolveExtensionUI(request.id, .value("真实输入"))
                case "editor": session.resolveExtensionUI(request.id, .value("编辑后\n内容"))
                default: XCTFail("Unexpected real Extension UI method: \(request.method)")
                }
            }

            if FileManager.default.fileExists(atPath: resultURL.path),
               session.extensionUIRequest == nil,
               session.extensionStatuses["real-ui"] == "完成",
               session.extensionWidgets["real-ui"]?.lines == ["上方", "小组件"] {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        try await waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: resultURL.path)
        }
        let resultData = try Data(contentsOf: resultURL)
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        )
        XCTAssertEqual(result["selection"] as? String, "允许")
        XCTAssertEqual(result["confirmed"] as? Bool, true)
        XCTAssertEqual(result["input"] as? String, "真实输入")
        XCTAssertEqual(result["editor"] as? String, "编辑后\n内容")
        XCTAssertTrue(
            session.extensionNotifications.contains(where: { $0.message == "真实 Extension UI 完成" })
        )
        XCTAssertNil(session.lastError)
    }

    private func makeSession() throws -> (PiSessionController, FakePiRPCTransport, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-extension-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = FakePiRPCTransport()
        let session = PiSessionController(
            services: WorkspaceServices(),
            makeTransport: { transport }
        )
        return (session, transport, root)
    }

    private func startAndHandshake(
        _ session: PiSessionController,
        _ transport: FakePiRPCTransport,
        _ root: URL
    ) async throws {
        session.openWorkspace(root)
        try await waitUntil { await transport.workspaceURL != nil }
        try await waitUntil {
            let types = await transport.sentCommands.map(\.type)
            return types.starts(with: ["get_state", "get_session_stats"])
        }
        await transport.emit(.record(Self.stateRecord()))
        await transport.emit(.record(Self.statsRecord()))
        try await waitUntil { session.runtimeStatus == "Pi Runtime 已连接" }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for WorkPi Extension UI state")
    }

    private static func extensionUIRequestRecord(
        id: String,
        method: String,
        options: [String] = [],
        prefill: String? = nil,
        timeout: Int? = nil
    ) -> PiRPCRecord {
        var fields: [String: JSONValue] = [
            "type": .string("extension_ui_request"),
            "id": .string(id),
            "method": .string(method),
        ]
        if !options.isEmpty {
            fields["options"] = .array(options.map(JSONValue.string))
        }
        if let prefill {
            fields["prefill"] = .string(prefill)
        }
        if let timeout {
            fields["timeout"] = .integer(Int64(timeout))
        }
        return PiRPCRecord(fields: fields)
    }

    private static func stateRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object([
                "model": .object([
                    "name": .string("Test Model"),
                    "contextWindow": .integer(100_000),
                ]),
                "thinkingLevel": .string("medium"),
                "messageCount": .integer(0),
            ]),
        ])
    }

    private static func statsRecord() -> PiRPCRecord {
        PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_session_stats"),
            "success": .bool(true),
            "data": .object([
                "contextUsage": .object([
                    "tokens": .integer(0),
                    "contextWindow": .integer(100_000),
                    "percent": .integer(0),
                ]),
            ]),
        ])
    }

    private static func realExtensionUISource(resultPath: String) -> String {
        let escapedPath = resultPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"""
        import { writeFileSync } from "node:fs";
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        export default function (pi: ExtensionAPI) {
          pi.registerCommand("workpi-ui-test", {
            handler: async (_args, ctx) => {
              const selection = await ctx.ui.select("选择", ["允许", "拒绝"]);
              const confirmed = await ctx.ui.confirm("确认", "继续吗？");
              const input = await ctx.ui.input("输入", "请输入");
              const editor = await ctx.ui.editor("编辑", input ?? "预填");
              writeFileSync("__RESULT_PATH__", JSON.stringify({
                selection,
                confirmed,
                input,
                editor,
              }));
              ctx.ui.notify("真实 Extension UI 完成", "info");
              ctx.ui.setStatus("real-ui", "完成");
              ctx.ui.setWidget("real-ui", ["上方", "小组件"]);
            },
          });
        }
        """#.replacingOccurrences(of: "__RESULT_PATH__", with: "\(escapedPath)")
    }
}
