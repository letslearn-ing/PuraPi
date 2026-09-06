import Darwin
import XCTest
@testable import WorkspaceKit

final class WorkspaceKitTests: XCTestCase {
    private func makeWorkspace() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = root.appendingPathComponent("README.md")
        try "# Hello\n\n内容".write(to: markdown, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "print(\"hi\")".write(to: root.appendingPathComponent("Sources/main.swift"), atomically: true, encoding: .utf8)
        return (root, markdown)
    }

    func testLoadsDirectoriesBeforeFilesAndIgnoresBuildNoise() throws {
        let (root, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)

        let tree = try DirectoryTreeLoader().load(rootURL: root)
        XCTAssertEqual(tree.kind, .directory)
        XCTAssertEqual(tree.children?.first?.name, "Sources")
        XCTAssertFalse(tree.children?.contains(where: { $0.name == "node_modules" }) == true)
    }

    func testShallowRootDefersNestedDirectoryTraversal() throws {
        let (root, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let nestedDirectory = root.appendingPathComponent("Sources/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "deep".write(
            to: nestedDirectory.appendingPathComponent("deep.txt"),
            atomically: true,
            encoding: .utf8
        )

        let loader = DirectoryTreeLoader()
        let shallowRoot = try loader.loadRoot(rootURL: root)
        let sources = try XCTUnwrap(shallowRoot.children?.first(where: { $0.name == "Sources" }))
        XCTAssertFalse(sources.childrenLoaded)
        XCTAssertNil(sources.children)

        let sourceChildren = try loader.loadChildren(directoryURL: sources.url, rootURL: root)
        let nested = try XCTUnwrap(sourceChildren.first(where: { $0.name == "Nested" }))
        XCTAssertFalse(nested.childrenLoaded)
        XCTAssertNil(nested.children)
        XCTAssertTrue(sourceChildren.contains(where: { $0.name == "main.swift" }))
    }

    func testReadsMarkdownAndComputesRelativePath() throws {
        let (root, markdown) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try FilePreviewReader().read(url: markdown, relativeTo: root)
        XCTAssertEqual(preview.kind, .markdown)
        XCTAssertEqual(preview.relativePath, "README.md")
        XCTAssertEqual(preview.text, "# Hello\n\n内容")
    }

    func testLazyExpansionHonorsMaximumDepth() throws {
        let (root, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Sources/Nested/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let loader = DirectoryTreeLoader(options: DirectoryTreeOptions(maximumDepth: 1))
        let shallow = try loader.loadRoot(rootURL: root)
        let sources = try XCTUnwrap(shallow.children?.first(where: { $0.name == "Sources" }))
        XCTAssertEqual(try loader.loadChildren(directoryURL: sources.url, rootURL: root), [])
    }

    func testRejectsFileOutsideWorkspace() throws {
        let (root, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try FilePreviewReader().read(url: URL(fileURLWithPath: "/etc/hosts"), relativeTo: root))
    }

    func testPreviewRejectsSymlinkedAndSpecialFilesWithoutBlocking() throws {
        let (root, _) = try makeWorkspace()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-preview-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "outside".write(
            to: outside.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try FilePreviewReader().read(
                url: linkedDirectory.appendingPathComponent("note.txt"),
                relativeTo: root
            )
        )

        let fifo = root.appendingPathComponent("stream.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        let preview = try FilePreviewReader().read(url: fifo, relativeTo: root)
        XCTAssertEqual(preview.kind, .unreadable)
    }

    func testUTF16TextIsNotClassifiedAsBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-utf16-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (suffix, encoding) in [
            ("bom", String.Encoding.utf16),
            ("little", String.Encoding.utf16LittleEndian),
            ("big", String.Encoding.utf16BigEndian),
        ] {
            let url = root.appendingPathComponent("note-\(suffix).txt")
            let data = try XCTUnwrap("UTF-16 内容".data(using: encoding))
            try data.write(to: url)

            let preview = try FilePreviewReader().read(url: url, relativeTo: root)

            XCTAssertEqual(preview.kind, .text, suffix)
            XCTAssertEqual(preview.text, "UTF-16 内容", suffix)
        }
    }

    func testAllSupportedMarkdownExtensionsUseMarkdownPreviewKind() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-markdown-extensions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for extensionName in ["md", "markdown", "mdown", "mkd"] {
            let url = root.appendingPathComponent("note.\(extensionName)")
            try "# 标题".write(to: url, atomically: true, encoding: .utf8)
            let preview = try FilePreviewReader().read(url: url, relativeTo: root)
            XCTAssertEqual(preview.kind, .markdown, extensionName)
        }
    }

    func testNULTextIsNotLoadedAsEditablePreview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkPi-binary-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("binary.md")
        try Data("text\0bytes".utf8).write(to: url)

        let preview = try FilePreviewReader().read(url: url, relativeTo: root)

        XCTAssertEqual(preview.kind, .binary)
        XCTAssertNil(preview.text)
    }
}
