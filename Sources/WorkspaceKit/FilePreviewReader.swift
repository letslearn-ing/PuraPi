import Darwin
import Foundation
import PiDomain
import UniformTypeIdentifiers

public struct FilePreviewOptions: Sendable {
    public var maximumTextBytes: Int
    public var maximumImageBytes: Int

    public init(maximumTextBytes: Int = 2 * 1024 * 1024, maximumImageBytes: Int = 20 * 1024 * 1024) {
        self.maximumTextBytes = max(0, maximumTextBytes)
        self.maximumImageBytes = max(0, maximumImageBytes)
    }
}

public struct FilePreviewReader: Sendable {
    private struct BoundedRead {
        let data: Data
        let byteCount: Int
        let modificationDate: Date?
    }

    private enum BoundedReadError: Error {
        case tooLarge
        case outsideWorkspace
        case notAFile
    }
    public let options: FilePreviewOptions

    public init(options: FilePreviewOptions = FilePreviewOptions()) {
        self.options = options
    }

    public func read(url: URL, relativeTo workspaceURL: URL) throws -> FilePreview {
        let lexicalWorkspace = workspaceURL.standardizedFileURL
        let workspace = canonicalURL(lexicalWorkspace)
        let fileURL = url.standardizedFileURL
        let resolvedFileURL = canonicalURL(fileURL)
        // A symlink used as the workspace root is an accepted spelling. Symlinks
        // below it are still rejected by the O_NOFOLLOW openat walk below.
        guard isInside(fileURL, root: lexicalWorkspace),
              isInside(resolvedFileURL, root: workspace) else {
            throw WorkPiError.fileNotFound(fileURL)
        }
        let identityURL = resolvedFileURL.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WorkPiError.fileNotFound(fileURL)
        }

        let relativePath = relativePath(
            of: identityURL,
            root: workspace.standardizedFileURL
        )
        // Do not classify a symlink/FIFO as merely a large or binary file based
        // on followed path attributes. The final object must be a regular inode.
        var lexicalStat = stat()
        let lstatResult = fileURL.path.withCString { path in lstat(path, &lexicalStat) }
        guard lstatResult == 0 else { throw WorkPiError.fileNotFound(fileURL) }
        guard (lexicalStat.st_mode & S_IFMT) == S_IFREG else {
            return FilePreview(
                url: identityURL,
                relativePath: relativePath,
                kind: .unreadable,
                text: nil,
                byteCount: 0,
                modificationDate: nil
            )
        }
        let byteCount = lexicalStat.st_size > off_t(Int.max)
            ? Int.max
            : Int(lexicalStat.st_size)
        let modificationDate = Date(timeIntervalSince1970: TimeInterval(lexicalStat.st_mtimespec.tv_sec))

        if let type = UTType(filenameExtension: fileURL.pathExtension), type.conforms(to: .image) {
            if byteCount > options.maximumImageBytes {
                return FilePreview(
                    url: identityURL,
                    relativePath: relativePath,
                    kind: .tooLarge,
                    text: nil,
                    byteCount: byteCount,
                    modificationDate: modificationDate
                )
            }
            // 预览宿主还会读取图片，但这里先用安全 fd 验证它仍是工作区内的
            // 普通文件；FIFO/符号链接/竞态路径不能进入图片预览状态。
            guard let opened = try? readBoundedData(
                at: fileURL,
                maximumBytes: options.maximumImageBytes,
                workspaceRoot: lexicalWorkspace
            ) else {
                return FilePreview(
                    url: identityURL,
                    relativePath: relativePath,
                    kind: .unreadable,
                    text: nil,
                    byteCount: byteCount,
                    modificationDate: modificationDate
                )
            }
            return FilePreview(
                url: identityURL,
                relativePath: relativePath,
                kind: .image,
                text: nil,
                byteCount: opened.byteCount,
                modificationDate: opened.modificationDate
            )
        }

        let opened: BoundedRead
        do {
            opened = try readBoundedData(
                at: fileURL,
                maximumBytes: options.maximumTextBytes,
                workspaceRoot: lexicalWorkspace
            )
        } catch BoundedReadError.tooLarge {
            return FilePreview(
                url: identityURL,
                relativePath: relativePath,
                kind: .tooLarge,
                text: nil,
                byteCount: byteCount,
                modificationDate: modificationDate
            )
        } catch {
            return FilePreview(
                url: identityURL,
                relativePath: relativePath,
                kind: .unreadable,
                text: nil,
                byteCount: byteCount,
                modificationDate: modificationDate
            )
        }
        let data = opened.data
        guard let text = decodeText(data) else {
            return FilePreview(
                url: identityURL,
                relativePath: relativePath,
                kind: .unreadable,
                text: nil,
                byteCount: opened.byteCount,
                modificationDate: opened.modificationDate
            )
        }
        // 先解码再判断 NUL：UTF-16 文本的零字节属于编码结构，不能把整份
        // 文件误判成二进制；真正解码后的 NUL 字符仍按二进制处理。
        if text.unicodeScalars.contains(where: { $0.value == 0 }) {
            return FilePreview(
                url: identityURL,
                relativePath: relativePath,
                kind: .binary,
                text: nil,
                byteCount: opened.byteCount,
                modificationDate: opened.modificationDate
            )
        }

        let kind: FilePreviewKind = ["md", "markdown", "mdown", "mkd"].contains(
            fileURL.pathExtension.lowercased()
        ) ? .markdown : .text
        return FilePreview(
            url: identityURL,
            relativePath: relativePath,
            kind: kind,
            text: text,
            byteCount: opened.byteCount,
            modificationDate: opened.modificationDate
        )
    }

    private func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian)
        }

        // 不带 BOM 的 UTF-16 ASCII 文本每隔一个字节就有一个零字节，同时整体
        // 可能仍被 UTF-8 判定为有效。必须先识别这种形状，否则会得到含嵌入式
        // NUL 字符的 String，随后被错误归类为二进制文件。
        if let encoding = likelyUTF16Encoding(bytes) {
            return String(data: data, encoding: encoding)
        }
        return String(data: data, encoding: .utf8)
    }

    private func likelyUTF16Encoding(_ bytes: [UInt8]) -> String.Encoding? {
        guard bytes.count >= 4, bytes.count.isMultiple(of: 2) else { return nil }
        let sampleCount = min(bytes.count, 4096)
        var evenZeroCount = 0
        var oddZeroCount = 0
        for index in 0..<sampleCount {
            if bytes[index] == 0 {
                if index.isMultiple(of: 2) {
                    evenZeroCount += 1
                } else {
                    oddZeroCount += 1
                }
            }
        }
        let threshold = max(2, sampleCount / 4)
        if oddZeroCount >= threshold, oddZeroCount > evenZeroCount * 2 {
            return .utf16LittleEndian
        }
        if evenZeroCount >= threshold, evenZeroCount > oddZeroCount * 2 {
            return .utf16BigEndian
        }
        return nil
    }

    private func readBoundedData(
        at url: URL,
        maximumBytes: Int,
        workspaceRoot: URL
    ) throws -> BoundedRead {
        let descriptor = try openReadableDescriptor(
            at: url,
            workspaceRoot: workspaceRoot,
            maximumBytes: maximumBytes
        )
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else {
            close(descriptor)
            throw BoundedReadError.notAFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        let readCount = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        let data: Data
        do {
            data = try handle.read(upToCount: readCount) ?? Data()
        } catch {
            throw BoundedReadError.notAFile
        }
        guard data.count <= maximumBytes else { throw BoundedReadError.tooLarge }
        let byteCount = fileStat.st_size > off_t(Int.max)
            ? Int.max
            : Int(fileStat.st_size)
        return BoundedRead(
            data: data,
            byteCount: byteCount,
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(fileStat.st_mtimespec.tv_sec)
            )
        )
    }

    private func openReadableDescriptor(
        at url: URL,
        workspaceRoot: URL,
        maximumBytes: Int
    ) throws -> Int32 {
        let target = url.standardizedFileURL
        let lexicalRoot = workspaceRoot.standardizedFileURL
        guard isInside(target, root: lexicalRoot) else {
            throw BoundedReadError.outsideWorkspace
        }
        let resolvedRoot = canonicalURL(lexicalRoot)
        let resolvedTarget = canonicalURL(target)
        guard isInside(resolvedTarget, root: resolvedRoot) else {
            throw BoundedReadError.outsideWorkspace
        }
        let suffix = String(target.path.dropFirst(lexicalRoot.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { throw BoundedReadError.notAFile }

        let rootDescriptor = resolvedRoot.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard rootDescriptor >= 0 else { throw BoundedReadError.notAFile }
        var currentDescriptor = rootDescriptor
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let nextDescriptor = component.withCString { name in
                openat(currentDescriptor, name, flags)
            }
            guard nextDescriptor >= 0 else {
                close(currentDescriptor)
                throw BoundedReadError.notAFile
            }
            close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        var fileStat = stat()
        guard fstat(currentDescriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG
        else {
            close(currentDescriptor)
            throw BoundedReadError.notAFile
        }
        if maximumBytes != Int.max,
           fileStat.st_size > off_t(maximumBytes) {
            close(currentDescriptor)
            throw BoundedReadError.tooLarge
        }
        return currentDescriptor
    }

    private func canonicalURL(_ url: URL) -> URL {
        let resolvedPath: String? = url.path.withCString { path in
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        return URL(
            fileURLWithPath: resolvedPath ?? url.resolvingSymlinksInPath().path,
            isDirectory: false
        )
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path == root.path { return "." }
        return String(url.path.dropFirst(rootPath.count))
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        if root.path == "/" { return url.path.hasPrefix("/") }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }
}
