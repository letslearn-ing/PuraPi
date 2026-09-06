import Darwin
import Foundation
import PiDomain

public struct DirectoryTreeOptions: Sendable {
    public var ignoredDirectoryNames: Set<String>
    public var includeHiddenFiles: Bool
    public var maximumDepth: Int

    public init(
        ignoredDirectoryNames: Set<String> = [
            ".git",
            ".build",
            "build",
            "DerivedData",
            "node_modules",
            ".swiftpm",
            "Pods",
            "target",
            ".venv",
            "venv",
        ],
        includeHiddenFiles: Bool = true,
        maximumDepth: Int = 32
    ) {
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.includeHiddenFiles = includeHiddenFiles
        self.maximumDepth = maximumDepth
    }
}

public struct DirectoryTreeLoader: Sendable {
    public let options: DirectoryTreeOptions

    public init(options: DirectoryTreeOptions = DirectoryTreeOptions()) {
        self.options = options
    }

    /// 兼容完整快照场景（测试、后续索引器）；UI 目录树应优先使用 `loadRoot` + `loadChildren`。
    public func load(rootURL: URL) throws -> FileNode {
        let root = try validatedRoot(rootURL)
        return try loadNodeRecursively(url: root, depth: 0, isRoot: true, rootURL: root)
    }

    /// 只读取根目录的直接子项。目录节点的 `childrenLoaded` 为 false，
    /// 展开时再通过 `loadChildren` 读取，避免大项目启动时遍历全部文件。
    public func loadRoot(rootURL: URL) throws -> FileNode {
        let root = try validatedRoot(rootURL)
        return try directoryNode(
            url: root,
            isRoot: true,
            loadRecursively: false,
            depth: 0,
            rootURL: root
        )
    }

    /// 读取一个目录的直接子项，不递归进入子目录。
    public func loadChildren(directoryURL: URL, rootURL: URL) throws -> [FileNode] {
        let root = try validatedRoot(rootURL)
        let directory = directoryURL.standardizedFileURL
        guard isInside(directory, root: root) else {
            throw WorkPiError.invalidWorkspace(rootURL)
        }

        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WorkPiError.invalidWorkspace(directoryURL)
        }
        // `loadRoot` and lazy expansion have the same depth contract: root is depth
        // zero and its direct children are depth one.  Do not let an expansion bypass
        // the limit merely because it happens later.
        let depth = pathDepth(of: directory, relativeTo: root)
        guard depth < max(0, options.maximumDepth) else { return [] }
        return try shallowChildren(
            of: directory,
            isRoot: directory == root,
            rootURL: root
        )
    }

    private func validatedRoot(_ rootURL: URL) throws -> URL {
        let root = WorkspaceDescriptor(rootURL: rootURL).rootURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WorkPiError.invalidWorkspace(root)
        }
        return root
    }

    private func loadNodeRecursively(
        url: URL,
        depth: Int,
        isRoot: Bool = false,
        rootURL: URL
    ) throws -> FileNode {
        let resourceValues = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        let isDirectory = resourceValues.isDirectory == true
        let isSymbolicLink = resourceValues.isSymbolicLink == true

        if isSymbolicLink {
            return FileNode(url: url, name: url.lastPathComponent, kind: .symbolicLink)
        }
        guard isDirectory else {
            return FileNode(url: url, name: url.lastPathComponent, kind: .file)
        }
        return try directoryNode(
            url: url,
            isRoot: isRoot,
            loadRecursively: true,
            depth: depth,
            rootURL: rootURL
        )
    }

    private func directoryNode(
        url: URL,
        isRoot: Bool,
        loadRecursively: Bool,
        depth: Int,
        rootURL: URL
    ) throws -> FileNode {
        guard depth < max(0, options.maximumDepth) else {
            return FileNode(
                url: url,
                name: url.lastPathComponent,
                kind: .directory,
                children: [],
                childrenLoaded: true
            )
        }

        if loadRecursively {
            let childrenURLs = try sortedChildrenURLs(
                of: url,
                isRoot: isRoot,
                rootURL: rootURL
            )
            let children = try childrenURLs.map {
                try loadNodeRecursively(
                    url: $0,
                    depth: depth + 1,
                    rootURL: rootURL
                )
            }
            return FileNode(
                url: url,
                name: url.lastPathComponent,
                kind: .directory,
                children: children,
                childrenLoaded: true
            )
        }

        return FileNode(
            url: url,
            name: url.lastPathComponent,
            kind: .directory,
            children: try shallowChildren(
                of: url,
                isRoot: isRoot,
                rootURL: rootURL
            ),
            childrenLoaded: true
        )
    }

    private func shallowChildren(
        of directory: URL,
        isRoot: Bool,
        rootURL: URL
    ) throws -> [FileNode] {
        try sortedChildrenURLs(
            of: directory,
            isRoot: isRoot,
            rootURL: rootURL
        ).compactMap { url in
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else { return nil }
            let kind = fileStat.st_mode & S_IFMT
            if kind == S_IFLNK {
                return FileNode(url: url, name: url.lastPathComponent, kind: .symbolicLink)
            }
            if kind == S_IFDIR {
                return FileNode(
                    url: url,
                    name: url.lastPathComponent,
                    kind: .directory,
                    children: nil,
                    childrenLoaded: false
                )
            }
            guard kind == S_IFREG else { return nil }
            return FileNode(url: url, name: url.lastPathComponent, kind: .file)
        }
    }

    private func sortedChildrenURLs(
        of directory: URL,
        isRoot: Bool,
        rootURL: URL
    ) throws -> [URL] {
        let childrenURLs = try directoryEntries(of: directory, rootURL: rootURL)

        let entries: [(url: URL, isDirectory: Bool)] = childrenURLs.compactMap { url in
            guard shouldInclude(url, isRootChild: isRoot) else { return nil }
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else { return nil }
            let kind = fileStat.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK else {
                // FIFO/socket/device nodes are not previewable files and must
                // not be surfaced as regular files to later UI actions.
                return nil
            }
            return (url, kind == S_IFDIR)
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }.map(\.url)
    }

    /// Enumerate from a directory descriptor so replacing the directory path
    /// after validation cannot redirect the listing to a symlink target.
    private func directoryEntries(of directory: URL, rootURL: URL) throws -> [URL] {
        var lexicalStat = stat()
        guard lstat(directory.path, &lexicalStat) == 0,
              lexicalStat.st_mode & S_IFMT == S_IFDIR,
              let resolvedDirectory = realPath(directory),
              let resolvedRoot = realPath(rootURL),
              isInside(resolvedDirectory, root: resolvedRoot)
        else {
            throw WorkPiError.invalidWorkspace(directory)
        }
        let components = resolvedDirectory.split(separator: "/", omittingEmptySubsequences: true)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw WorkPiError.invalidWorkspace(directory)
        }
        for component in components {
            let next = component.withCString { name in
                openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard next >= 0 else {
                close(descriptor)
                throw WorkPiError.invalidWorkspace(directory)
            }
            close(descriptor)
            descriptor = next
        }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            throw WorkPiError.invalidWorkspace(directory)
        }
        defer { closedir(stream) }

        var result: [URL] = []
        while let entry = readdir(stream) {
            var rawName = entry.pointee.d_name
            let name = withUnsafePointer(to: &rawName) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.isEmpty else { continue }
            result.append(directory.appendingPathComponent(name))
        }
        return result
    }

    private func realPath(_ url: URL) -> String? {
        url.path.withCString { path in
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
    }

    private func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func shouldInclude(_ url: URL, isRootChild: Bool) -> Bool {
        let name = url.lastPathComponent
        if !options.includeHiddenFiles && name.hasPrefix(".") {
            return false
        }
        if options.ignoredDirectoryNames.contains(name) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory { return false }
        }
        _ = isRootChild
        return true
    }

    private func pathDepth(of url: URL, relativeTo root: URL) -> Int {
        guard url.path != root.path else { return 0 }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { return Int.max }
        return url.path.dropFirst(prefix.count).split(separator: "/").count
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }
}
