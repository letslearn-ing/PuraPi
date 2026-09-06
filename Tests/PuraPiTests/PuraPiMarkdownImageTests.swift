import AppKit
import Foundation
import PiDomain
import XCTest
@testable import PuraPi

@MainActor
final class PuraPiMarkdownImageTests: XCTestCase {
    func testOutlineIncludesNonEmptyHeadingsInDocumentOrder() {
        let first = MarkdownBlock(kind: .heading(level: 1), source: "# 第一", lineRange: 0..<1)
        let paragraph = MarkdownBlock(kind: .paragraph, source: "正文", lineRange: 1..<2)
        let second = MarkdownBlock(kind: .heading(level: 3), source: "### 第二", lineRange: 2..<3)
        let empty = MarkdownBlock(kind: .heading(level: 2), source: "## ", lineRange: 3..<4)
        XCTAssertEqual(
            PuraPiMarkdownOutline.items(from: [first, paragraph, second, empty]),
            [
                PuraPiMarkdownOutlineItem(id: first.id, level: 1, title: "第一"),
                PuraPiMarkdownOutlineItem(id: second.id, level: 3, title: "第二"),
            ]
        )
    }

    func testImageInsertionUsesWorkspaceRelativePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("images/logo.png")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let data = try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
        try data.write(to: imageURL)
        XCTAssertNotNil(PuraPiMarkdownImageInsertion.safePreviewData(from: data))

        XCTAssertEqual(
            PuraPiMarkdownImageInsertion.markdown(for: imageURL, workspaceRoot: root),
            "![logo](<images/logo.png>)"
        )
        XCTAssertTrue(PuraPiMarkdownImageInsertion.hasSafeImageDimensions(at: imageURL))
    }

    func testEmbeddedImageReferenceResolvesOnlyWorkspaceImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-image-reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("assets/pixel.png")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        try XCTUnwrap(bitmap?.representation(using: .png, properties: [:])).write(to: imageURL)

        let reference = try XCTUnwrap(
            PuraPiMarkdownImageReference.parse("![像素](<assets/pixel.png>)")
        )
        XCTAssertEqual(reference.altText, "像素")
        XCTAssertEqual(reference.relativePath, "assets/pixel.png")
        XCTAssertEqual(
            reference.resolvedURL(workspaceRoot: root),
            imageURL.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertNil(
            PuraPiMarkdownImageReference.parse("说明 ![像素](<assets/pixel.png>)")
        )
        let traversal = try XCTUnwrap(
            PuraPiMarkdownImageReference.parse("![越界](<../pixel.png>)")
        )
        XCTAssertNil(traversal.resolvedURL(workspaceRoot: root))
    }

    func testImageReferenceParsesDestinationAndTitleForms() throws {
        let plain = try XCTUnwrap(
            PuraPiMarkdownImageReference.parse("![alt](assets/photo(1).png \"preview\")")
        )
        XCTAssertEqual(plain.altText, "alt")
        XCTAssertEqual(plain.relativePath, "assets/photo(1).png")

        let quoted = try XCTUnwrap(
            PuraPiMarkdownImageReference.parse("![a\\]b](<assets/a\\>b.png> 'title')")
        )
        XCTAssertEqual(quoted.altText, "a]b")
        XCTAssertEqual(quoted.relativePath, "assets/a>b.png")
        XCTAssertNil(PuraPiMarkdownImageReference.parse("![alt](assets/photo.png bad title)"))
    }

    func testImageInsertionEscapesSpecialFilename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-image-special-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("a [b] > c.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [],
            bytesPerRow: 0, bitsPerPixel: 0
        )
        try XCTUnwrap(bitmap?.representation(using: .png, properties: [:])).write(to: imageURL)
        XCTAssertEqual(
            PuraPiMarkdownImageInsertion.markdown(for: imageURL, workspaceRoot: root),
            "![a \\[b\\] > c](<a [b] \\> c.png>)"
        )
    }

    func testImageOutsideWorkspaceIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-image-root-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("purapi-markdown-image-outside-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        try XCTUnwrap(bitmap?.representation(using: .png, properties: [:])).write(to: outside)

        XCTAssertNil(PuraPiMarkdownImageInsertion.markdown(for: outside, workspaceRoot: root))
    }
}
