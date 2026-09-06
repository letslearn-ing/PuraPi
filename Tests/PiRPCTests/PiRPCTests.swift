import Foundation
import XCTest
@testable import PiRPC

final class PiRPCTests: XCTestCase {
    func testCommandIsStrictJSONL() throws {
        let data = try PiRPCCommand.prompt("第一行\u{2028}第二行", id: "request-1").jsonLine()
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.dropLast().filter { $0 == 0x0A }.count, 0)
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "prompt")
        XCTAssertEqual(object?["id"] as? String, "request-1")
    }

    func testFramerOnlyUsesLFAndAcceptsCRLF() throws {
        var framer = JSONLFramer()
        let lines = try framer.append(Data("{\"type\":\"one\"}\r\n{\"type\":\"two\"}\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"type\":\"one\"}")
        XCTAssertEqual(String(data: lines[1], encoding: .utf8), "{\"type\":\"two\"}")
    }

    func testRecordExtractsStreamingTextAndToolOutput() throws {
        let text = Data("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"你好\"}}".utf8)
        let record = try JSONDecoder().decode(PiRPCRecord.self, from: text)
        XCTAssertEqual(record.textDelta, "你好")

        let tool = Data("{\"type\":\"tool_execution_end\",\"toolName\":\"read\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"file content\"}]}}".utf8)
        let toolRecord = try JSONDecoder().decode(PiRPCRecord.self, from: tool)
        XCTAssertEqual(toolRecord.toolResultText, "file content")
    }

    func testRecordExtractsRuntimeAndContextMetadata() throws {
        let state = Data("{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{\"model\":{\"id\":\"model-id\",\"name\":\"Model Name\",\"contextWindow\":272000},\"thinkingLevel\":\"max\",\"messageCount\":7}}".utf8)
        let stateRecord = try JSONDecoder().decode(PiRPCRecord.self, from: state)
        XCTAssertEqual(stateRecord.modelName, "Model Name")
        XCTAssertEqual(stateRecord.thinkingLevel, "max")
        XCTAssertEqual(stateRecord.contextWindow, 272_000)
        XCTAssertEqual(stateRecord.messageCount, 7)

        let stats = Data("{\"type\":\"response\",\"command\":\"get_session_stats\",\"success\":true,\"data\":{\"contextUsage\":{\"tokens\":68000,\"contextWindow\":272000,\"percent\":25}}}".utf8)
        let statsRecord = try JSONDecoder().decode(PiRPCRecord.self, from: stats)
        XCTAssertEqual(statsRecord.contextTokens, 68_000)
        XCTAssertEqual(statsRecord.contextWindow, 272_000)
        XCTAssertEqual(statsRecord.contextPercent, 25)
    }

    func testGetCommandsCommandAndResponseAreTyped() throws {
        let data = try PiRPCCommand.getCommands(id: "commands-1").jsonLine()
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "get_commands")
        XCTAssertEqual(object?["id"] as? String, "commands-1")

        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_commands"),
            "success": .bool(true),
            "data": .object([
                "commands": .array([
                    .object([
                        "name": .string("purapi-ui-demo"),
                        "description": .string("演示面板"),
                        "source": .string("extension"),
                    ]),
                ]),
            ]),
        ])
        XCTAssertEqual(
            record.commandInfos,
            [PiRPCCommandInfo(
                name: "purapi-ui-demo",
                description: "演示面板",
                source: "extension"
            )]
        )
    }

    func testSessionStatsCommandIsStrictJSONL() throws {
        let data = try PiRPCCommand.getSessionStats(id: "stats-1").jsonLine()
        XCTAssertEqual(data.last, 0x0A)
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "get_session_stats")
        XCTAssertEqual(object?["id"] as? String, "stats-1")
    }

    func testQueueAndExtensionCommandsUseDocumentedTypes() throws {
        let commands: [(PiRPCCommand, String)] = [
            (.steer("steer", id: "steer-1"), "steer"),
            (.followUp("follow", id: "follow-1"), "follow_up"),
            (.compact(customInstructions: "focus", id: "compact-1"), "compact"),
            (.bash("printf ok", id: "bash-1"), "bash"),
            (.newSession(parentSession: "/tmp/parent.jsonl", id: "new-1"), "new_session"),
            (.extensionUIResponse(requestID: "ui-1", cancelled: true), "extension_ui_response"),
        ]

        for (command, type) in commands {
            let object = try JSONSerialization.jsonObject(with: command.jsonLine().dropLast()) as? [String: Any]
            XCTAssertEqual(object?["type"] as? String, type)
        }

        let newSession = try JSONSerialization.jsonObject(
            with: PiRPCCommand.newSession(parentSession: "/tmp/parent.jsonl", id: "new-1").jsonLine().dropLast()
        ) as? [String: Any]
        XCTAssertEqual(newSession?["parentSession"] as? String, "/tmp/parent.jsonl")
    }

    func testExtensionUIRequestParsesDialogAndFireAndForgetFields() throws {
        let record = PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("ui-parse"),
            "method": .string("editor"),
            "title": .string("编辑"),
            "message": .string("说明"),
            "prefill": .string("初始"),
            "timeout": .integer(1_500),
            "widgetKey": .string("widget"),
            "widgetLines": .array([.string("a"), .string("b")]),
            "widgetPlacement": .string("belowEditor"),
        ])
        let request = try XCTUnwrap(record.extensionUIRequest)
        XCTAssertEqual(request.id, "ui-parse")
        XCTAssertEqual(request.dialogMethod, .editor)
        XCTAssertEqual(request.title, "编辑")
        XCTAssertEqual(request.message, "说明")
        XCTAssertEqual(request.prefill, "初始")
        XCTAssertEqual(request.timeoutMilliseconds, 1_500)
        XCTAssertEqual(request.widgetKey, "widget")
        XCTAssertEqual(request.widgetLines, ["a", "b"])
        XCTAssertEqual(request.widgetPlacement, "belowEditor")
    }

    func testExtensionUIRequestRequiresIDAndMethod() {
        XCTAssertNil(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "method": .string("confirm"),
        ]).extensionUIRequest)
        XCTAssertNil(PiRPCRecord(fields: [
            "type": .string("extension_ui_request"),
            "id": .string("missing-method"),
        ]).extensionUIRequest)
    }

    func testExtensionUIResponseEncodesEachResultShape() throws {
        let value = try JSONSerialization.jsonObject(
            with: PiRPCCommand.extensionUIResponse(
                requestID: "value-1",
                value: "result"
            ).jsonLine().dropLast()
        ) as? [String: Any]
        XCTAssertEqual(value?["id"] as? String, "value-1")
        XCTAssertEqual(value?["value"] as? String, "result")
        XCTAssertNil(value?["confirmed"])
        XCTAssertNil(value?["cancelled"])

        let confirmed = try JSONSerialization.jsonObject(
            with: PiRPCCommand.extensionUIResponse(
                requestID: "confirm-1",
                confirmed: false
            ).jsonLine().dropLast()
        ) as? [String: Any]
        XCTAssertEqual(confirmed?["confirmed"] as? Bool, false)

        let cancelled = try JSONSerialization.jsonObject(
            with: PiRPCCommand.extensionUIResponse(
                requestID: "cancel-1",
                cancelled: true
            ).jsonLine().dropLast()
        ) as? [String: Any]
        XCTAssertEqual(cancelled?["cancelled"] as? Bool, true)
    }

    func testRecordExtractsTerminalAndExtensionStates() throws {
        let aborted = Data("""
        {"type":"message_end","message":{"role":"assistant","stopReason":"aborted","content":[{"type":"thinking","thinking":"partial"}]}}
        """.utf8)
        let abortedRecord = try JSONDecoder().decode(PiRPCRecord.self, from: aborted)
        XCTAssertEqual(abortedRecord.messageStopReason, "aborted")
        XCTAssertEqual(abortedRecord.messageRole, "assistant")

        let request = Data("""
        {"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Confirm","message":"Continue?"}
        """.utf8)
        let requestRecord = try JSONDecoder().decode(PiRPCRecord.self, from: request)
        XCTAssertEqual(requestRecord.extensionUIRequestID, "ui-1")
        XCTAssertEqual(requestRecord.extensionUIMethod, "confirm")
        XCTAssertEqual(requestRecord.extensionUIMessage, "Continue?")
    }

    func testExecutableResolverHonorsExplicitOverrideBeforeSearchPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-pi-resolver-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("custom-pi")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )

        let resolver = PiExecutableResolver(
            environment: [
                "PI_EXECUTABLE": executable.path,
                "PATH": "/does/not/exist",
            ]
        )
        XCTAssertEqual(resolver.resolve(), executable)
    }

    func testFakeTransportRecordsCommands() async throws {
        let transport = FakePiRPCTransport()
        let stream = try await transport.start(in: URL(fileURLWithPath: "/tmp"))
        _ = stream
        try await transport.send(.getState(id: "state-1"))
        try await transport.send(.steer("next", id: "steer-1"))
        let commands = await transport.sentCommands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.first?.type, "get_state")
        XCTAssertEqual(commands.last?.type, "steer")
        await transport.stop()
    }

    func testProcessTransportDoesNotPassNodeInjectionEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-pi-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("env-probe.sh")
        let script = """
        #!/bin/sh
        if [ -n "$NODE_OPTIONS" ] || [ -n "$BASH_ENV" ] || [ -n "$NPM_CONFIG_USERCONFIG" ]; then
          printf '%s\\n' 'unsafe runtime environment leaked' >&2
          exit 1
        fi
        printf '%s\\n' '{"type":"response","command":"get_state","success":true}'
        """
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )

        let transport = PiRPCProcessTransport(
            executableURL: executable,
            processArguments: [],
            environmentOverrides: [
                "NODE_OPTIONS": "--require /does/not/exist",
                "BASH_ENV": "/does/not/exist",
                "NPM_CONFIG_USERCONFIG": "/does/not/exist",
            ]
        )
        let stream = try await transport.start(in: root)
        var sawStateResponse = false
        for try await event in stream {
            if case .record(let record) = event,
               record.type == "response",
               record.command == "get_state" {
                sawStateResponse = true
            }
        }
        XCTAssertTrue(sawStateResponse)
        await transport.stop()
    }

    func testProcessTransportAttachesStderrToExitDiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuraPi-pi-diagnostic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("diagnostic-probe.sh")
        let script = """
        #!/bin/sh
        printf '%s\\n' 'fatal: no model is configured' >&2
        exit 1
        """
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )

        let transport = PiRPCProcessTransport(
            executableURL: executable,
            processArguments: []
        )
        let stream = try await transport.start(in: root)
        var diagnostic: String?
        for try await event in stream {
            if case .processExitedWithDiagnostic(let status, let text) = event {
                XCTAssertEqual(status, 1)
                diagnostic = text
            }
        }
        XCTAssertTrue(diagnostic?.contains("fatal: no model is configured") == true)
        await transport.stop()
    }
}
