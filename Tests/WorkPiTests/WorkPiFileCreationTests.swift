import Foundation
import PiDomain
import XCTest
@testable import WorkPi

/// 新建文件与文件夹的层级规则。
///
/// 层级是这个功能最容易出错的地方：在文件夹上右键要落在文件夹内，
/// 在文件上右键要落在同级，空白处要落在项目根。
@MainActor
final class WorkPiFileCreationTests: XCTestCase {
    private var root: URL!
    private var session: PiSessionController!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workpi-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        session = PiSessionController()
        session.workspace = WorkspaceDescriptor(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 空白处（anchor 为 nil）→ 项目根。
    func testBlankAreaCreatesAtProjectRoot() {
        let parent = session.creationParentDirectory(for: nil)
        XCTAssertEqual(parent?.path, root.path)
    }

    /// 文件夹上右键 → 文件夹内部。
    func testDirectoryAnchorCreatesInside() throws {
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let node = FileNode(url: sub, name: "sub", kind: .directory)

        XCTAssertEqual(
            session.creationParentDirectory(for: node)?.path,
            sub.path
        )
    }

    /// 文件上右键 → 同级（父目录），不是文件内部。
    func testFileAnchorCreatesAsSibling() throws {
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("a.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let node = FileNode(url: file, name: "a.md", kind: .file)

        XCTAssertEqual(
            session.creationParentDirectory(for: node)?.path,
            sub.path
        )
    }

    /// 路径分隔符必须拒绝，否则能越出目标目录。
    func testSanitizeRejectsPathTraversal() {
        XCTAssertNil(PiSessionController.sanitizedEntryName("../evil"))
        XCTAssertNil(PiSessionController.sanitizedEntryName("a/b"))
        XCTAssertNil(PiSessionController.sanitizedEntryName(".."))
        XCTAssertNil(PiSessionController.sanitizedEntryName("."))
        XCTAssertNil(PiSessionController.sanitizedEntryName(""))
        XCTAssertEqual(PiSessionController.sanitizedEntryName("notes.md"), "notes.md")
    }

    func testCreateFileWritesToDisk() throws {
        session.createFile(in: nil, name: "new.md")
        let target = root.appendingPathComponent("new.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testCreateDirectoryWritesToDisk() {
        session.createDirectory(in: nil, name: "folder")
        var isDirectory: ObjCBool = false
        let target = root.appendingPathComponent("folder")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// 重名不能覆盖已有文件，应追加序号。
    func testDuplicateNameDoesNotOverwrite() throws {
        let existing = root.appendingPathComponent("dup.md")
        try "原有内容".write(to: existing, atomically: true, encoding: .utf8)

        session.createFile(in: nil, name: "dup.md")

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "原有内容")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("dup 2.md").path
            )
        )
    }

    func testCreationRejectsSymlinkedParent() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("workpi-create-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let node = FileNode(url: link, name: "linked", kind: .directory)
        session.createFile(in: node, name: "escaped.txt")

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path))
    }
}
