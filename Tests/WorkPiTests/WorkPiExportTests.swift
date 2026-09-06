import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi

/// 会话导出与上下文压缩的 HUD 入口。
@MainActor
final class WorkPiExportTests: XCTestCase {
    // MARK: - 协议层

    func testExportCommandEncodesOutputPath() {
        let withPath = PiRPCCommand.exportHTML(outputPath: "/tmp/s.html")
        XCTAssertEqual(withPath.type, "export_html")
        XCTAssertEqual(withPath.fields["outputPath"]?.stringValue, "/tmp/s.html")

        // 不传路径时不能出现空的 outputPath，否则 Pi 会当成合法路径。
        let withoutPath = PiRPCCommand.exportHTML()
        XCTAssertEqual(withoutPath.type, "export_html")
        XCTAssertNil(withoutPath.fields["outputPath"])
    }

    func testExportedPathParsing() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("export_html"),
            "success": .bool(true),
            "data": .object(["path": .string("/tmp/session.html")]),
        ])
        XCTAssertEqual(record.exportedFilePath, "/tmp/session.html")
    }

    // MARK: - 响应处理

    /// 失败响应必须清掉 in-flight 标记，否则导出按钮永久禁用。
    func testFailedExportClearsInFlightMarker() {
        let session = PiSessionController()
        session.activeExportCommandID = "req-1"

        let consumed = session.consumeExportResponse(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("export_html"),
            "id": .string("req-1"),
            "success": .bool(false),
            "error": .string("磁盘已满"),
        ]))

        XCTAssertTrue(consumed)
        XCTAssertNil(session.activeExportCommandID)
        XCTAssertFalse(session.isExporting)
        XCTAssertEqual(session.lastError, "磁盘已满")
    }

    /// 过期响应（id 不匹配）不能清掉当前请求的标记。
    func testStaleExportResponseDoesNotClearCurrentRequest() {
        let session = PiSessionController()
        session.activeExportCommandID = "req-2"

        _ = session.consumeExportResponse(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("export_html"),
            "id": .string("req-1"),
            "success": .bool(true),
        ]))

        XCTAssertEqual(session.activeExportCommandID, "req-2")
    }

    /// 非导出响应不应被这里消费。
    func testOtherCommandsAreNotConsumed() {
        let session = PiSessionController()
        let consumed = session.consumeExportResponse(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
        ]))
        XCTAssertFalse(consumed)
    }

    // MARK: - 自动压缩开关

    func testAutoCompactionCommandEncodesEnabled() {
        XCTAssertEqual(PiRPCCommand.setAutoCompaction(enabled: true).type, "set_auto_compaction")
        XCTAssertEqual(
            PiRPCCommand.setAutoCompaction(enabled: false).fields["enabled"]?.boolValue,
            false
        )
    }

    /// 状态必须来自 Pi 的 `get_state`，不能在本地推断。
    func testAutoCompactionStateParsedFromRuntimeState() {
        let record = PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("get_state"),
            "success": .bool(true),
            "data": .object(["autoCompactionEnabled": .bool(false)]),
        ])
        XCTAssertEqual(record.autoCompactionEnabled, false)
    }

    /// 失败时必须清 in-flight 标记，否则开关永久卡住。
    func testFailedAutoCompactionTogglesClearMarker() {
        let session = PiSessionController()
        session.activeAutoCompactionCommandID = "req-9"

        let consumed = session.consumeAutoCompactionResponse(PiRPCRecord(fields: [
            "type": .string("response"),
            "command": .string("set_auto_compaction"),
            "id": .string("req-9"),
            "success": .bool(false),
            "error": .string("不支持"),
        ]))

        XCTAssertTrue(consumed)
        XCTAssertNil(session.activeAutoCompactionCommandID)
        XCTAssertEqual(session.lastError, "不支持")
    }

    // MARK: - 压缩入口门控

    /// Runtime 未就绪时不能压缩：按钮条件必须与 `compactSession` 的前置条件一致，
    /// 否则按钮可点但请求被静默拒绝。
    func testCompactIsUnavailableBeforeRuntimeReady() {
        let session = PiSessionController()
        XCTAssertFalse(session.runtimeReady)
        XCTAssertFalse(session.canCompactContext)
    }
}
