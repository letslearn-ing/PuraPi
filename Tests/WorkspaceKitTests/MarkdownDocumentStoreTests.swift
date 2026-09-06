import Darwin
import Foundation
import PiDomain
import XCTest
@testable import WorkspaceKit

/// 文档读写与冲突判定。
///
/// 冲突这部分是刚需而非防御性编程：Pi 的 `file-mutation-queue` 只在 Pi 进程内
/// 串行化，它看不到 PuraPi 的写入，所以同时编辑必然可能丢内容。
final class MarkdownDocumentStoreTests: XCTestCase {
    private var root: URL!
    private let store = MarkdownDocumentStore()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("purapi-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, name: String = "doc.md") throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 读取

    func testLoadParsesBlocksAndBaseline() throws {
        let url = try write("# 标题\n\n正文\n")
        let document = try store.load(url: url, workspaceRoot: root)

        XCTAssertFalse(document.blocks.isEmpty)
        XCTAssertEqual(document.baselineHash, MarkdownDocumentStore.hash("# 标题\n\n正文\n"))
        XCTAssertNotNil(document.baselineModificationDate)
        XCTAssertFalse(document.isDirty)
        XCTAssertTrue(document.hasTrailingNewline)
        XCTAssertFalse(document.usesCRLF)
    }

    /// 越界读取必须拒绝，否则编辑器成了任意文件读写入口。
    func testLoadSupportsSymlinkedWorkspaceRootPath() throws {
        let linkedRoot = root.deletingLastPathComponent()
            .appendingPathComponent("purapi-md-root-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        let url = linkedRoot.appendingPathComponent("README.md")
        try "通过根目录链接\n".write(to: url, atomically: true, encoding: .utf8)

        let document = try store.load(url: url, workspaceRoot: linkedRoot)
        XCTAssertEqual(document.workspaceRoot, root.standardizedFileURL)
        XCTAssertEqual(document.blocks.first?.source, "通过根目录链接")
    }

    func testLoadRejectsFileOutsideWorkspace() throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try store.load(url: outside, workspaceRoot: root)) { error in
            XCTAssertEqual(error as? MarkdownDocumentStore.LoadFailure, .outsideWorkspace)
        }
    }

    func testLoadRejectsOversizedFile() throws {
        let small = MarkdownDocumentStore(maximumEditableBytes: 16)
        let url = try write(String(repeating: "A", count: 100))
        XCTAssertThrowsError(try small.load(url: url, workspaceRoot: root)) { error in
            guard case .tooLarge = error as? MarkdownDocumentStore.LoadFailure else {
                return XCTFail("应报 tooLarge，实际 \(error)")
            }
        }
    }

    func testLoadRejectsNonUTF8() throws {
        let url = root.appendingPathComponent("bin.md")
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: url)
        XCTAssertThrowsError(try store.load(url: url, workspaceRoot: root)) { error in
            XCTAssertEqual(error as? MarkdownDocumentStore.LoadFailure, .notUTF8)
        }
    }

    func testLoadRejectsUTF8DataContainingNULAsEditableMarkdown() throws {
        let url = root.appendingPathComponent("binary.md")
        try Data("text\0bytes".utf8).write(to: url)
        XCTAssertThrowsError(try store.load(url: url, workspaceRoot: root)) { error in
            XCTAssertEqual(error as? MarkdownDocumentStore.LoadFailure, .notUTF8)
        }
    }

    func testLoadRejectsDirectory() throws {
        XCTAssertThrowsError(try store.load(url: root, workspaceRoot: root)) { error in
            XCTAssertEqual(error as? MarkdownDocumentStore.LoadFailure, .notAFile)
        }
    }

    // MARK: - 保存与保真

    /// 未编辑就保存，文件必须逐字节不变。
    func testSaveWithoutEditsPreservesBytes() throws {
        let original = "# 标题\n\n\n多空行\n\n* 星号\n  - 缩进\n"
        let url = try write(original)
        let document = try store.load(url: url, workspaceRoot: root)

        let outcome = try store.save(document)
        guard case .saved = outcome else { return XCTFail("应保存成功") }

        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, original, "未编辑的保存不能改动任何字节")
    }

    func testSaveAppliesBlockEdit() throws {
        let url = try write("# 标题\n\n正文\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let paragraph = try XCTUnwrap(document.blocks.first { $0.kind == .paragraph })

        document.apply(.update(id: paragraph.id, source: "改过的正文"))
        XCTAssertTrue(document.isDirty)

        let outcome = try store.save(document)
        guard case .saved(let hash, _) = outcome else { return XCTFail("应保存成功") }

        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "# 标题\n\n改过的正文\n")
        XCTAssertEqual(hash, MarkdownDocumentStore.hash(after))
    }

    func testSavePreservesCRLF() throws {
        let url = try write("# 标题\r\n\r\n正文\r\n")
        var document = try store.load(url: url, workspaceRoot: root)
        XCTAssertTrue(document.usesCRLF)

        let paragraph = try XCTUnwrap(document.blocks.first { $0.kind == .paragraph })
        document.apply(.update(id: paragraph.id, source: "新正文"))
        _ = try store.save(document)

        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.contains("\r\n"), "CRLF 风格必须保留")
        XCTAssertFalse(after.contains("\n\n\n"))
    }

    func testEditingPreservesMixedLineEndingsOutsideChangedText() throws {
        let original = "第一段\r\n\r\n第二段\n\r\n第三段\r\n"
        let url = try write(original)
        var document = try store.load(url: url, workspaceRoot: root)
        let paragraph = try XCTUnwrap(document.blocks.last { $0.kind == .paragraph })
        document.apply(.update(id: paragraph.id, source: "改过的第三段"))
        _ = try store.save(document)

        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "第一段\r\n\r\n第二段\n\r\n改过的第三段\r\n"
        )
    }

    func testEditingCROnlyFileKeepsItsLineEnding() throws {
        let url = try write("第一段\r\r第二段\r")
        var document = try store.load(url: url, workspaceRoot: root)
        let second = try XCTUnwrap(document.blocks.last { $0.kind == .paragraph })
        document.apply(.update(id: second.id, source: "修改后的第二段"))
        _ = try store.save(document)

        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "第一段\r\r修改后的第二段\r"
        )
    }

    func testSubsequentEditAfterSaveKeepsLineEndingMetadata() throws {
        let original = "第一段\r\n\r\n第二段\n\r\n"
        let url = try write(original)
        var document = try store.load(url: url, workspaceRoot: root)
        let first = try XCTUnwrap(document.blocks.first { $0.kind == .paragraph })
        let inserted = MarkdownBlock(kind: .paragraph, source: "插入", lineRange: 1..<2)
        document.apply(.insert(block: inserted, after: first.id))
        guard case .saved(let hash, let date) = try store.save(document) else {
            return XCTFail("第一次结构性保存应成功")
        }
        document.resetBaseline(hash: hash, modificationDate: date)

        let second = try XCTUnwrap(document.blocks.first { $0.source == "第二段" })
        document.apply(.update(id: second.id, source: "第二段-再次修改"))
        _ = try store.save(document)

        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "第一段\r\n插入\r\n\r\n第二段-再次修改\n\r\n"
        )
    }

    /// 无尾随换行的文件不能被擅自补上。
    func testSavePreservesMissingTrailingNewline() throws {
        let url = try write("只有一行")
        var document = try store.load(url: url, workspaceRoot: root)
        XCTAssertFalse(document.hasTrailingNewline)

        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: "改一行"))
        _ = try store.save(document)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "改一行")
    }

    func testRemovingLastBlockMarksDocumentDirtyAndWritesEmptyFile() throws {
        let url = try write("唯一一段\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)

        document.apply(.remove(id: block.id))
        XCTAssertTrue(document.isDirty, "删空文档仍然必须触发保存")
        guard case .saved = try store.save(document) else {
            return XCTFail("删空文档应保存成功")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testSaveDoesNotRecreateDeletedFile() throws {
        let url = try write("原始\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: "我的版本"))
        try FileManager.default.removeItem(at: url)

        guard case .deleted = try store.save(document) else {
            return XCTFail("目标文件被删除时应返回 deleted")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSaveDoesNotOverwriteUnreadableFile() throws {
        let url = try write("原始\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: "我的版本"))
        let invalidBytes = Data([0xFF, 0xFE, 0x00, 0x01])
        try invalidBytes.write(to: url)

        guard case .unreadable = try store.save(document) else {
            return XCTFail("无法读取磁盘内容时应返回 unreadable")
        }
        XCTAssertEqual(try Data(contentsOf: url), invalidBytes)
        XCTAssertTrue(store.hasExternalChange(document))
    }

    func testSaveRejectsGrowthBeyondEditableLimit() throws {
        let limitedStore = MarkdownDocumentStore(maximumEditableBytes: 16)
        let url = try write("short\n")
        var document = try limitedStore.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: String(repeating: "x", count: 32)))

        XCTAssertThrowsError(try limitedStore.save(document)) { error in
            guard case .tooLarge = error as? MarkdownDocumentStore.SaveFailure else {
                return XCTFail("应报 SaveFailure.tooLarge，实际 \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "short\n")
    }

    // MARK: - 冲突

    /// 保存前磁盘被改（Agent 写入）时必须拒绝覆盖。
    func testSaveDetectsExternalChange() throws {
        let url = try write("原始内容\n")
        var document = try store.load(url: url, workspaceRoot: root)

        // 模拟 Agent 在用户编辑期间改了文件
        try "Agent 改过的内容\n".write(to: url, atomically: true, encoding: .utf8)

        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: "用户改的内容"))

        let outcome = try store.save(document)
        guard case .conflict(let diskHash, let diskText) = outcome else {
            return XCTFail("应报冲突而不是覆盖")
        }
        XCTAssertEqual(diskText, "Agent 改过的内容\n")
        XCTAssertEqual(diskHash, MarkdownDocumentStore.hash(diskText))
        // 关键：磁盘内容没有被覆盖
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Agent 改过的内容\n")
    }

    /// 用户在冲突界面选「保留我的」时才允许强制覆盖。
    func testForceSaveRejectsTargetOutsideDocumentWorkspace() throws {
        let outsideRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("purapi-md-force-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outsideURL = outsideRoot.appendingPathComponent("doc.md")
        let block = MarkdownBlock(kind: .paragraph, source: "越界", lineRange: 0..<1)
        let document = MarkdownDocument(
            url: outsideURL,
            workspaceRoot: root,
            blocks: [block],
            baselineHash: MarkdownDocumentStore.hash("旧\n")
        )

        XCTAssertThrowsError(try store.save(document, force: true)) { error in
            XCTAssertEqual(
                error as? MarkdownDocumentStore.SaveFailure,
                .outsideWorkspace
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    func testForceSaveRejectsSymlinkedParentDirectory() throws {
        let outsideRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("purapi-md-parent-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideRoot)
        let target = link.appendingPathComponent("doc.md")
        let block = MarkdownBlock(kind: .paragraph, source: "越界", lineRange: 0..<1)
        let document = MarkdownDocument(
            url: target,
            workspaceRoot: root,
            blocks: [block],
            baselineHash: MarkdownDocumentStore.hash("旧\n")
        )

        XCTAssertThrowsError(try store.save(document, force: true)) { error in
            XCTAssertEqual(
                error as? MarkdownDocumentStore.SaveFailure,
                .outsideWorkspace
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideRoot.appendingPathComponent("doc.md").path))
    }

    func testForceSaveOverwritesConflict() throws {
        let url = try write("原始\n")
        var document = try store.load(url: url, workspaceRoot: root)
        try "外部修改\n".write(to: url, atomically: true, encoding: .utf8)

        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: "我的版本"))

        let outcome = try store.save(document, force: true)
        guard case .saved = outcome else { return XCTFail("强制保存应成功") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "我的版本\n")
    }

    func testAtomicSavePreservesOriginalMode() throws {
        let url = try write("原始\n")
        XCTAssertEqual(chmod(url.path, mode_t(0o640)), 0)
        var document = try store.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: "改后"))

        guard case .saved = try store.save(document) else {
            return XCTFail("保存应成功")
        }
        var fileStat = stat()
        XCTAssertEqual(stat(url.path, &fileStat), 0)
        XCTAssertEqual(fileStat.st_mode & 0o777, 0o640)
    }

    /// 保存成功后基线要更新，否则下一次保存会误报冲突。
    func testBaselineResetAfterSave() throws {
        let url = try write("初始\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)

        document.apply(.update(id: block.id, source: "第一次改"))
        guard case .saved(let hash, let date) = try store.save(document) else {
            return XCTFail("首次保存应成功")
        }
        document.resetBaseline(hash: hash, modificationDate: date)
        XCTAssertFalse(document.isDirty)

        document.apply(.update(id: block.id, source: "第二次改"))
        guard case .saved = try store.save(document) else {
            return XCTFail("基线已更新，第二次保存不该报冲突")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "第二次改\n")
    }

    func testHasExternalChange() throws {
        let url = try write("内容\n")
        let document = try store.load(url: url, workspaceRoot: root)
        XCTAssertFalse(store.hasExternalChange(document))

        try "别的内容\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.hasExternalChange(document))
    }

    func testExternalChangeTreatsDeletionAsChange() throws {
        let url = try write("内容\n")
        let document = try store.load(url: url, workspaceRoot: root)
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(store.externalChange(for: document), .deleted)
        XCTAssertTrue(store.hasExternalChange(document))
    }

    /// 原子写不能留下临时文件。
    func testAtomicWriteLeavesNoTemporaryFiles() throws {
        let url = try write("内容\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)
        document.apply(.update(id: block.id, source: "改后"))
        _ = try store.save(document)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(remaining.filter { $0.hasPrefix(".purapi-") }, [])
    }

    // MARK: - 文档变更

    func testInsertAndRemoveBlocks() throws {
        let url = try write("# 标题\n\n正文\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let heading = try XCTUnwrap(document.blocks.first)

        let inserted = MarkdownBlock(
            kind: .paragraph,
            source: "插入的段落",
            lineRange: 0..<1
        )
        document.apply(.insert(block: inserted, after: heading.id))
        XCTAssertEqual(document.blocks[1].source, "插入的段落")

        document.apply(.remove(id: inserted.id))
        XCTAssertFalse(document.blocks.contains { $0.id == inserted.id })
        // 删除也要留下脏标记，否则该区域不会被重写
        XCTAssertTrue(document.isDirty)
    }

    func testSplitAndMerge() throws {
        let url = try write("一段很长的文字\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let block = try XCTUnwrap(document.blocks.first)

        let second = MarkdownBlock(kind: .paragraph, source: "的文字", lineRange: 0..<1)
        document.apply(.split(id: block.id, firstSource: "一段很长", second: second))
        XCTAssertEqual(document.blocks.count, 2)

        document.apply(.merge(into: block.id, from: second.id, source: "一段很长的文字"))
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].source, "一段很长的文字")
    }

    /// 锚点不存在时不能静默丢弃插入。
    func testInsertWithMissingAnchorAppends() throws {
        let url = try write("正文\n")
        var document = try store.load(url: url, workspaceRoot: root)
        let orphan = MarkdownBlock(kind: .paragraph, source: "新块", lineRange: 0..<1)

        document.apply(.insert(block: orphan, after: UUID()))
        XCTAssertTrue(document.blocks.contains { $0.id == orphan.id })
    }
}
