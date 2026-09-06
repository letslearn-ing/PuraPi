import Darwin
import Foundation
import PiDomain
import PiRPC
import XCTest
@testable import WorkPi

/// 附件输入与单条消息复制。
@MainActor
final class WorkPiAttachmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workpi-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 协议层

    /// 图片必须按 Pi 的格式编码：base64 + mimeType。
    func testPromptEncodesImages() {
        let image = PiPromptImage(data: Data([0x01, 0x02]), mimeType: "image/png")
        let command = PiRPCCommand.prompt("看这张图", images: [image])

        guard case .array(let images)? = command.fields["images"] else {
            return XCTFail("images 字段缺失")
        }
        XCTAssertEqual(images.count, 1)
        guard case .object(let first) = images[0] else {
            return XCTFail("图片应为对象")
        }
        XCTAssertEqual(first["type"]?.stringValue, "image")
        XCTAssertEqual(first["mimeType"]?.stringValue, "image/png")
        XCTAssertEqual(first["data"]?.stringValue, Data([0x01, 0x02]).base64EncodedString())
    }

    /// 没有附件时不能出现空的 images 字段。
    func testPromptOmitsImagesWhenEmpty() {
        XCTAssertNil(PiRPCCommand.prompt("你好").fields["images"])
    }

    func testMimeTypeInference() {
        XCTAssertEqual(PiPromptImage.mimeType(forPathExtension: "PNG"), "image/png")
        XCTAssertEqual(PiPromptImage.mimeType(forPathExtension: "jpeg"), "image/jpeg")
        // 不认识的扩展名返回 nil，不猜测。
        XCTAssertNil(PiPromptImage.mimeType(forPathExtension: "txt"))
        XCTAssertNil(PiPromptImage.mimeType(forPathExtension: ""))
    }

    func testAttachmentMemoryEstimateIncludesBase64Copy() {
        let raw = Data(repeating: 0x01, count: 3)
        let attachment = WorkPiAttachment(
            url: nil,
            kind: .image(PiPromptImage(data: raw, mimeType: "image/png"))
        )
        XCTAssertEqual(attachment.byteCount, 3)
        // 3 bytes encode to 4 Base64 bytes, plus the explicit object headroom.
        XCTAssertEqual(attachment.estimatedMemoryByteCount, 3 + 4 + 8 * 1024)
    }

    // MARK: - 附件收集

    /// 文本文件读成内容拼进正文：Pi 的 prompt 只接受图片附件。
    func testTextFileBecomesInlineContent() throws {
        let file = root.appendingPathComponent("notes.md")
        try "# 标题\n正文".write(to: file, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.attachFiles([file])

        XCTAssertEqual(session.pendingAttachments.count, 1)
        XCTAssertFalse(session.pendingAttachments[0].isImage)
        // 图片列表里不该出现文本附件。
        XCTAssertTrue(session.pendingPromptImages.isEmpty)

        let merged = session.messageWithTextAttachments("看看这个")
        XCTAssertTrue(merged.contains("<file name=\"notes.md\">"))
        XCTAssertTrue(merged.contains("# 标题"))
        // 用户原话必须保留。
        XCTAssertTrue(merged.contains("看看这个"))
    }

    func testImageFileBecomesPromptImage() throws {
        let file = root.appendingPathComponent("shot.png")
        let onePixelPNG = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try onePixelPNG.write(to: file)

        let session = PiSessionController()
        session.attachFiles([file])

        XCTAssertEqual(session.pendingAttachments.count, 1)
        XCTAssertTrue(session.pendingAttachments[0].isImage)
        XCTAssertEqual(session.pendingPromptImages.count, 1)
        // 图片不进正文。
        XCTAssertEqual(session.messageWithTextAttachments("描述一下"), "描述一下")
    }

    /// 目录不是附件，静默跳过而不是报错或崩溃。
    func testTextAttachmentFilenameIsEscapedInEnvelope() throws {
        let file = root.appendingPathComponent("a\"<&>.txt")
        try "内容".write(to: file, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.attachFiles([file])
        let message = session.messageWithTextAttachments("问题")

        XCTAssertTrue(message.contains("<file name=\"a&quot;&lt;&amp;&gt;.txt\">"))
        XCTAssertTrue(message.contains("内容"))
    }

    func testDirectoriesAreIgnored() throws {
        let dir = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let session = PiSessionController()
        session.attachFiles([dir])

        XCTAssertTrue(session.pendingAttachments.isEmpty)
    }

    func testWorkspaceParentSymlinkIsRejectedWithoutReadingTarget() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("workpi-attach-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "不应读取".write(
            to: outside.appendingPathComponent("secret.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        let session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: root)
        session.attachFiles([root.appendingPathComponent("link/secret.txt")])

        XCTAssertTrue(session.pendingAttachments.isEmpty)
    }

    func testSpecialFileIsRejectedWithoutBlocking() throws {
        let fifo = root.appendingPathComponent("stream.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        let session = PiSessionController()
        session.attachFiles([fifo])
        XCTAssertTrue(session.pendingAttachments.isEmpty)
    }

    /// 超大文本要截断，否则会挤爆上下文。
    func testOversizedTextIsTruncated() throws {
        let file = root.appendingPathComponent("big.log")
        let payload = String(repeating: "A", count: PiSessionController.maximumTextAttachmentBytes + 5_000)
        try payload.write(to: file, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.attachFiles([file])

        guard case .text(let content)? = session.pendingAttachments.first?.kind else {
            return XCTFail("应为文本附件")
        }
        XCTAssertTrue(content.contains("文件已截断"))
        XCTAssertLessThan(content.count, payload.count)
    }

    func testRemoveAndClear() throws {
        let file = root.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let session = PiSessionController()
        session.attachFiles([file, file])
        XCTAssertEqual(session.pendingAttachments.count, 2)

        session.removeAttachment(id: session.pendingAttachments[0].id)
        XCTAssertEqual(session.pendingAttachments.count, 1)

        session.clearAttachments()
        XCTAssertTrue(session.pendingAttachments.isEmpty)
        XCTAssertFalse(session.hasPendingAttachments)
    }

    // MARK: - 单条消息复制

    func testCopyWritesToPasteboard() {
        WorkPiMessageActions.copy("要复制的内容")
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "要复制的内容"
        )
    }

    /// 「编辑」把原文填回输入框，让用户改完自己发。
    func testEditPostsNotificationWithText() {
        let expectation = expectation(description: "收到编辑通知")
        let token = NotificationCenter.default.addObserver(
            forName: .workPiEditMessage,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.userInfo?["text"] as? String, "原来的问题")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        WorkPiMessageActions.edit("原来的问题")
        wait(for: [expectation], timeout: 2)
    }

    /// 「重试」与「编辑」必须是两条独立通道：
    /// 重试原样立即重发，编辑只填回输入框。混成一个会让其中一种意图无法表达。
    func testRetryPostsSeparateNotification() {
        let expectation = expectation(description: "收到重试通知")
        let token = NotificationCenter.default.addObserver(
            forName: .workPiRetryMessage,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.userInfo?["text"] as? String, "再来一次")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        WorkPiMessageActions.retry("再来一次")
        wait(for: [expectation], timeout: 2)
    }

    /// 重试在 Agent 忙时要排队，不能静默丢弃。
    func testRetryWhileBusyEnqueues() {
        let session = PiSessionController()
        session.phase = .requesting
        XCTAssertTrue(session.isAgentBusy)

        session.retryMessage("排队的重试")

        XCTAssertEqual(session.queuedPrompts.count, 1)
        XCTAssertEqual(session.queuedPrompts.first?.text, "排队的重试")
    }

    /// 空白重试不应产生任何动作。
    func testRetryIgnoresBlankText() {
        let session = PiSessionController()
        session.retryMessage("   ")
        XCTAssertTrue(session.queuedPrompts.isEmpty)
    }

    /// 历史消息的时间取自 Pi 的毫秒时间戳，而不是显示成"现在"。
    func testHistoryTimestampIsPreserved() {
        let data = JSONValue.object([
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string("你好"),
                    "timestamp": .integer(1_733_234_567_890),
                ]),
            ]),
        ])
        let items = PiSessionHistoryMapper.conversation(from: data)
        let user = items.first { $0.kind == .user }
        XCTAssertEqual(
            user?.createdAt.timeIntervalSince1970 ?? 0,
            1_733_234_567.890,
            accuracy: 0.01
        )
    }
}
