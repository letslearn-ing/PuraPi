import Foundation
import PiDomain

public struct WorkspaceServices: Sendable {
    public let treeLoader: DirectoryTreeLoader
    public let previewReader: FilePreviewReader

    public init(
        treeLoader: DirectoryTreeLoader = DirectoryTreeLoader(),
        previewReader: FilePreviewReader = FilePreviewReader()
    ) {
        self.treeLoader = treeLoader
        self.previewReader = previewReader
    }

    public func loadTree(rootURL: URL) throws -> FileNode {
        try treeLoader.load(rootURL: rootURL)
    }

    public func loadTreeRoot(rootURL: URL) throws -> FileNode {
        try treeLoader.loadRoot(rootURL: rootURL)
    }

    public func loadDirectoryChildren(directoryURL: URL, rootURL: URL) throws -> [FileNode] {
        try treeLoader.loadChildren(directoryURL: directoryURL, rootURL: rootURL)
    }

    public func preview(fileURL: URL, rootURL: URL) throws -> FilePreview {
        try previewReader.read(url: fileURL, relativeTo: rootURL)
    }
}
