import CryptoKit
import Darwin
import Foundation
import PiDomain

/// Markdown 文档的唯一读写入口。
///
/// 之所以要求"唯一"：未来的人机协作机制需要在这里挂变更广播，UI 若绕过它直接
/// 写文件，协作层就看不到变更。
///
/// 写入采用原子替换，并在写前校验基线，因为 Pi 的 `file-mutation-queue` 只在
/// Pi 进程内串行化写入，它不知道 WorkPi 的写入。「Agent 正在写 + 用户正在编辑
/// 同一文件」的丢失风险必须由客户端防。
public struct MarkdownDocumentStore: Sendable {
    private enum AtomicWriteResult {
        case saved
        case conflict(Data)
        case deleted
        case unreadable
    }

    private struct FileMetadata {
        let mode: mode_t
        let extendedAttributes: [(String, Data)]
    }

    private enum MetadataCapture {
        case existing(FileMetadata)
        case missing
        case failed
    }

    /// 可编辑的体积上限。超过仍走只读预览。
    public let maximumEditableBytes: Int

    public init(maximumEditableBytes: Int = 2 * 1024 * 1024) {
        self.maximumEditableBytes = max(0, maximumEditableBytes)
    }

    public enum LoadFailure: Error, Equatable, Sendable {
        case outsideWorkspace
        case notAFile
        case tooLarge(byteCount: Int)
        case notUTF8
    }

    public enum SaveFailure: Error, Equatable, Sendable {
        case tooLarge(byteCount: Int)
        case deleted
        case outsideWorkspace
    }

    /// 磁盘相对于文档基线的状态。
    public enum ExternalChange: Equatable, Sendable {
        case unchanged
        case modified(diskHash: String, diskText: String)
        case deleted
        case unreadable
    }

    /// 保存前的冲突判定结果。
    public enum SaveOutcome: Equatable, Sendable {
        case saved(hash: String, modificationDate: Date?)
        /// 磁盘内容已被外部改动（通常是 Agent）。不覆盖，交由用户决定。
        case conflict(diskHash: String, diskText: String)
        /// 目标文件在保存前被删除；默认不自动复活文件。
        case deleted
        /// 目标文件存在但无法以 UTF-8 文本读取；默认不覆盖未知内容。
        case unreadable
    }

    // MARK: - 读取

    public func load(url: URL, workspaceRoot: URL) throws -> MarkdownDocument {
        let lexicalWorkspaceRoot = workspaceRoot.standardizedFileURL
        let root = standardizedResolvedDirectoryURL(lexicalWorkspaceRoot)
        let resolvedRoot = canonicalDirectoryURL(lexicalWorkspaceRoot)
        let lexicalTarget = url.standardizedFileURL
        let resolvedTarget = resolvedExistingURL(lexicalTarget)
        guard isInside(resolvedTarget, root: resolvedRoot) else {
            throw LoadFailure.outsideWorkspace
        }

        // Read through the lexical spelling so a symlinked child is rejected by
        // openat(O_NOFOLLOW); only the workspace-root symlink is canonicalized.
        let data = try readBoundedData(
            at: lexicalTarget,
            maximumBytes: maximumEditableBytes,
            workspaceRoot: lexicalWorkspaceRoot
        )
        let target = resolvedTarget
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            // UTF-8 可合法包含 NUL，但 Markdown 编辑器不能把这种二进制内容
            // 当作普通源码载入；只读预览会负责展示为 binary。
            throw LoadFailure.notUTF8
        }

        return MarkdownDocument(
            url: target,
            workspaceRoot: root,
            blocks: MarkdownBlockParser.parse(text),
            baselineHash: Self.hash(text),
            baselineModificationDate: attributes[.modificationDate] as? Date,
            usesCRLF: MarkdownBlockParser.detectCRLF(text),
            hasTrailingNewline: MarkdownBlockParser.detectTrailingNewline(text)
        )
    }

    // MARK: - 写入

    /// 保存文档。基线不一致时不写入，返回冲突让调用方处理。
    ///
    /// - Parameter force: 用户在冲突界面选择"保留我的"时传 true，跳过基线校验。
    public func save(
        _ document: MarkdownDocument,
        force: Bool = false,
        expectedCurrentHash: String? = nil
    ) throws -> SaveOutcome {
        let target = document.url

        if !force {
            switch externalChange(
                for: document,
                acceptingCurrentHash: expectedCurrentHash
            ) {
            case .unchanged:
                break
            case .modified(let diskHash, let diskText):
                return .conflict(diskHash: diskHash, diskText: diskText)
            case .deleted:
                return .deleted
            case .unreadable:
                return .unreadable
            }
        }

        let text = MarkdownBlockParser.serialize(
            document.blocks,
            usesCRLF: document.usesCRLF,
            hasTrailingNewline: document.hasTrailingNewline
        )

        // 序列化可能涉及大量块，期间 Agent 仍可能写入文件；在真正替换前再做
        // 一次检查，缩短 TOCTOU（检查与使用之间竞态）窗口。外部进程不参与
        // NSFileCoordinator，因此仍不能声称这是跨进程硬锁，但不会把明显的中途
        // 修改误当成安全写入。
        let data = Data(text.utf8)
        guard data.count <= maximumEditableBytes else {
            throw SaveFailure.tooLarge(byteCount: data.count)
        }
        if !force {
            switch externalChange(
                for: document,
                acceptingCurrentHash: expectedCurrentHash
            ) {
            case .unchanged:
                break
            case .modified(let diskHash, let diskText):
                return .conflict(diskHash: diskHash, diskText: diskText)
            case .deleted:
                return .deleted
            case .unreadable:
                return .unreadable
            }
        }
        let newHash = Self.hash(text)
        switch try writeAtomically(
            data,
            to: target,
            allowCreate: force,
            workspaceRoot: document.workspaceRoot,
            expectedBaseHash: expectedCurrentHash ?? document.baselineHash,
            newHash: newHash
        ) {
        case .saved:
            let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
            return .saved(
                hash: newHash,
                modificationDate: attributes?[.modificationDate] as? Date
            )
        case .conflict(let diskData):
            guard let diskText = String(data: diskData, encoding: .utf8),
                  !diskText.unicodeScalars.contains(where: { $0.value == 0 })
            else { return .unreadable }
            return .conflict(
                diskHash: Self.hash(diskText),
                diskText: diskText
            )
        case .deleted:
            return .deleted
        case .unreadable:
            return .unreadable
        }
    }

    /// 原子写：在安全的目录描述符中创建临时文件，再用 `renameat` 替换目标项。
    ///
    /// 不使用“先拼临时路径、再按路径 replace”的流程，避免 `force` 保存期间父目录
    /// 被替换成符号链接后把写入导向工作区外。目录句柄固定后，后续操作不会重新
    /// 解析可变的父路径。
    private func writeAtomically(
        _ data: Data,
        to target: URL,
        allowCreate: Bool,
        workspaceRoot: URL?,
        expectedBaseHash: String,
        newHash: String
    ) throws -> AtomicWriteResult {
        let (directoryDescriptor, targetName) = try openParentDirectory(
            for: target,
            workspaceRoot: workspaceRoot
        )
        let temporaryName = ".workpi-\(UUID().uuidString).tmp"
        var temporaryDescriptor: Int32 = -1
        var didCommit = false
        var temporaryContainsOriginal = false
        defer {
            if temporaryDescriptor >= 0 { close(temporaryDescriptor) }
            if !didCommit && !temporaryContainsOriginal {
                _ = temporaryName.withCString { name in
                    unlinkat(directoryDescriptor, name, 0)
                }
            }
            close(directoryDescriptor)
        }

        temporaryDescriptor = temporaryName.withCString { name in
            openat(
                directoryDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o644)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        // Atomic replacement otherwise silently resets the mode and all xattrs
        // (including the macOS ACL xattr). Capture the old inode through the
        // already-fixed parent fd and apply what the platform permits to the
        // temporary inode before it becomes visible. If an existing target's
        // metadata cannot be captured or restored, fail closed rather than
        // replacing a private file with a broadly readable one.
        switch captureMetadata(in: directoryDescriptor, name: targetName) {
        case .missing:
            break
        case .failed:
            throw CocoaError(.fileWriteNoPermission)
        case .existing(let metadata):
            guard fchmod(temporaryDescriptor, metadata.mode) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            for (name, value) in metadata.extendedAttributes {
                let result = value.withUnsafeBytes { bytes in
                    name.withCString { attribute in
                        fsetxattr(
                            temporaryDescriptor,
                            attribute,
                            bytes.baseAddress,
                            value.count,
                            0,
                            0
                        )
                    }
                }
                guard result == 0 else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        }

        let handle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            temporaryDescriptor = -1
            throw error
        }
        temporaryDescriptor = -1

        var targetStat = stat()
        let targetExists = targetName.withCString { name in
            fstatat(directoryDescriptor, name, &targetStat, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard targetExists || allowCreate else { return .deleted }
        if targetExists, (targetStat.st_mode & S_IFMT) == S_IFDIR {
            return .deleted
        }

        if allowCreate {
            let renameResult = renameTemporary(
                temporaryName,
                to: targetName,
                in: directoryDescriptor
            )
            guard renameResult == 0 else { throw CocoaError(.fileWriteUnknown) }
            didCommit = true
            return .saved
        }

        // 非 force 保存使用交换式替换：旧目标先被保留在临时名称下，随后校验
        // 它仍是预期基线；若 Agent 在最后检查后改过文件，立即交换回去，避免
        // 把外部修改永久覆盖。APFS/HFS+ 等 macOS 文件系统支持此原子操作。
        let swapResult = renameatx_np(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            targetName,
            UInt32(RENAME_SWAP)
        )
        guard swapResult == 0 else {
            if errno == ENOENT { return .deleted }
            throw CocoaError(.fileWriteUnknown)
        }
        temporaryContainsOriginal = true
        let oldData = readDataAt(
            directoryDescriptor,
            name: temporaryName,
            maximumBytes: maximumEditableBytes
        )
        let newData = readDataAt(
            directoryDescriptor,
            name: targetName,
            maximumBytes: maximumEditableBytes
        )
        let oldMatchesBaseline = oldData.map {
            Self.matchesTextHash($0, expected: expectedBaseHash)
        } == true
        let newMatchesWrite = newData.map {
            Self.matchesTextHash($0, expected: newHash)
        } == true
        if oldMatchesBaseline && newMatchesWrite {
            let unlinkResult = temporaryName.withCString { name in
                unlinkat(directoryDescriptor, name, 0)
            }
            if unlinkResult == 0 {
                temporaryContainsOriginal = false
                didCommit = true
                return .saved
            }
            // 删除旧内容失败时先恢复原目标；否则不能把一次保存误报为成功。
            let restoreAfterUnlinkFailure = renameatx_np(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                targetName,
                UInt32(RENAME_SWAP)
            )
            if restoreAfterUnlinkFailure == 0 {
                temporaryContainsOriginal = false
            }
            throw CocoaError(.fileWriteUnknown)
        }

        // 如果目标在交换后已被外部再次替换，不能把它交换回旧内容；否则会
        // 覆盖外部刚写入的版本。保留当前目标，只清理暂存的旧版本。
        if !newMatchesWrite {
            var currentTargetStat = stat()
            let targetStillExists = targetName.withCString { name in
                fstatat(
                    directoryDescriptor,
                    name,
                    &currentTargetStat,
                    AT_SYMLINK_NOFOLLOW
                ) == 0
            }
            let cleanupResult = temporaryName.withCString { name in
                unlinkat(directoryDescriptor, name, 0)
            }
            if cleanupResult == 0 { temporaryContainsOriginal = false }
            if let newData,
               Self.isValidUTF8Text(newData) {
                return .conflict(newData)
            }
            return targetStillExists ? .unreadable : .deleted
        }

        // 恢复原目标；defer 会删除仍留在 temporaryName 的新内容。
        let restoreResult = renameatx_np(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            targetName,
            UInt32(RENAME_SWAP)
        )
        guard restoreResult == 0 else {
            // 无法恢复时宁可留下可见错误和临时文件，也不假装保存成功；临时项
            // 此时包含原目标内容，defer 会刻意保留它，避免再次丢失外部修改。
            throw CocoaError(.fileWriteUnknown)
        }
        temporaryContainsOriginal = false
        if let oldData,
           MarkdownDocumentStore.isValidUTF8Text(oldData) {
            return .conflict(oldData)
        }
        return .unreadable
    }

    private func renameTemporary(
        _ temporaryName: String,
        to targetName: String,
        in directoryDescriptor: Int32
    ) -> Int32 {
        temporaryName.withCString { temporary in
            targetName.withCString { destination in
                renameat(
                    directoryDescriptor,
                    temporary,
                    directoryDescriptor,
                    destination
                )
            }
        }
    }

    private func captureMetadata(in directoryDescriptor: Int32, name: String) -> MetadataCapture {
        let descriptor = name.withCString { entry in
            openat(directoryDescriptor, entry, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            return errno == ENOENT ? .missing : .failed
        }
        defer { close(descriptor) }

        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG
        else { return .failed }

        var attributes: [(String, Data)] = []
        let size = flistxattr(descriptor, nil, 0, 0)
        guard size >= 0 || errno == ENOTSUP else { return .failed }
        if size > 0 {
            var names = [CChar](repeating: 0, count: Int(size))
            let actual = flistxattr(descriptor, &names, names.count, 0)
            guard actual >= 0 else { return .failed }
            var start = 0
            for index in 0..<Int(actual) where names[index] == 0 {
                if index > start {
                    let attributeName = String(
                        decoding: names[start..<index].map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                    let valueSize = fgetxattr(descriptor, attributeName, nil, 0, 0, 0)
                    guard valueSize >= 0 else { return .failed }
                    var value = Data(count: Int(valueSize))
                    let valueCount = value.count
                    let read = value.withUnsafeMutableBytes { bytes in
                        fgetxattr(
                            descriptor,
                            attributeName,
                            bytes.baseAddress,
                            valueCount,
                            0,
                            0
                        )
                    }
                    guard read >= 0 else { return .failed }
                    attributes.append((attributeName, value))
                }
                start = index + 1
            }
        }
        return .existing(
            FileMetadata(
                mode: fileStat.st_mode & 0o7777,
                extendedAttributes: attributes
            )
        )
    }

    private func readDataAt(
        _ directoryDescriptor: Int32,
        name: String,
        maximumBytes: Int
    ) -> Data? {
        let descriptor = name.withCString { entry in
            openat(directoryDescriptor, entry, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              maximumBytes == Int.max || fileStat.st_size <= off_t(maximumBytes)
        else {
            close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        let readCount = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        let data: Data
        do {
            data = try handle.read(upToCount: readCount) ?? Data()
        } catch {
            return nil
        }
        guard data.count <= maximumBytes else { return nil }
        return data
    }

    private static func isValidUTF8Text(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return !text.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func matchesTextHash(_ data: Data, expected: String) -> Bool {
        guard isValidUTF8Text(data),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return hash(text) == expected
    }

    /// 打开目标的父目录并逐级拒绝符号链接；返回的 fd 在整个原子写期间保持有效。
    private func openParentDirectory(
        for target: URL,
        workspaceRoot: URL?
    ) throws -> (descriptor: Int32, targetName: String) {
        let lexicalTarget = target.standardizedFileURL
        let targetName = lexicalTarget.lastPathComponent
        guard !targetName.isEmpty, targetName != ".", targetName != ".." else {
            throw SaveFailure.deleted
        }

        if let workspaceRoot {
            let lexicalRoot = workspaceRoot.standardizedFileURL
            guard isInside(lexicalTarget, root: lexicalRoot) else {
                throw SaveFailure.outsideWorkspace
            }
            let resolvedRoot = canonicalDirectoryURL(lexicalRoot)
            let resolvedTarget = resolvedExistingURL(lexicalTarget)
            guard isInside(resolvedTarget, root: resolvedRoot) else {
                throw SaveFailure.outsideWorkspace
            }
            let suffix = String(lexicalTarget.path.dropFirst(lexicalRoot.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count >= 1 else { throw SaveFailure.deleted }

            let rootDescriptor = resolvedRoot.path.withCString { path in
                open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            }
            guard rootDescriptor >= 0 else { throw SaveFailure.deleted }
            var currentDescriptor = rootDescriptor
            for component in components.dropLast() {
                let nextDescriptor = component.withCString { name in
                    openat(currentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                }
                guard nextDescriptor >= 0 else {
                    close(currentDescriptor)
                    throw SaveFailure.outsideWorkspace
                }
                close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }
            return (currentDescriptor, targetName)
        }

        let parent = lexicalTarget.deletingLastPathComponent()
        let descriptor = parent.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SaveFailure.deleted }
        return (descriptor, targetName)
    }

    // MARK: - 外部变更

    /// 磁盘内容相对于文档基线的状态。
    public func externalChange(for document: MarkdownDocument) -> ExternalChange {
        externalChange(for: document, acceptingCurrentHash: nil)
    }

    private func externalChange(
        for document: MarkdownDocument,
        acceptingCurrentHash: String?
    ) -> ExternalChange {
        let url = document.url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .deleted
        }
        guard !isDirectory.boolValue else { return .unreadable }
        // 外部文件可能在用户编辑期间突然膨胀；冲突检查不能为了生成提示而把
        // 未受限的大文件完整读入内存。
        guard let data = try? readBoundedData(
            at: url,
            maximumBytes: maximumEditableBytes,
            workspaceRoot: document.workspaceRoot
        ),
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            return .unreadable
        }
        let diskHash = Self.hash(text)
        guard diskHash != document.baselineHash,
              diskHash != acceptingCurrentHash
        else { return .unchanged }
        return .modified(diskHash: diskHash, diskText: text)
    }

    /// 磁盘内容是否已偏离文档基线。
    public func hasExternalChange(_ document: MarkdownDocument) -> Bool {
        if case .unchanged = externalChange(for: document) {
            return false
        }
        return true
    }

    /// 读取磁盘当前文本，用于冲突对比或重载。
    public func readDiskText(_ url: URL) -> String? {
        guard let data = try? readBoundedData(
            at: url,
            maximumBytes: maximumEditableBytes
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 工具

    public static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func readBoundedData(
        at url: URL,
        maximumBytes: Int,
        workspaceRoot: URL? = nil
    ) throws -> Data {
        let descriptor = try openReadableDescriptor(
            at: url,
            workspaceRoot: workspaceRoot
        )
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        let readCount = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        let data = try handle.read(upToCount: readCount) ?? Data()
        guard data.count <= maximumBytes else {
            throw LoadFailure.tooLarge(byteCount: data.count)
        }
        return data
    }

    /// 以 root fd + 逐级 `openat` 打开文件，避免校验路径后再跟随被替换的目录/链接。
    private func openReadableDescriptor(
        at url: URL,
        workspaceRoot: URL?
    ) throws -> Int32 {
        let target = url.standardizedFileURL
        guard let workspaceRoot else {
            let components = target.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { throw LoadFailure.notAFile }
            var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard current >= 0 else { throw LoadFailure.notAFile }
            for (index, component) in components.enumerated() {
                let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                    | (index == components.count - 1 ? 0 : O_DIRECTORY)
                let next = component.withCString { name in openat(current, name, flags) }
                guard next >= 0 else {
                    close(current)
                    throw LoadFailure.notAFile
                }
                close(current)
                current = next
            }
            return try validateRegularDescriptor(current)
        }

        let lexicalRoot = workspaceRoot.standardizedFileURL
        guard isInside(target, root: lexicalRoot) else {
            throw LoadFailure.outsideWorkspace
        }
        let resolvedRoot = canonicalDirectoryURL(lexicalRoot)
        let resolvedTarget = resolvedExistingURL(target)
        guard isInside(resolvedTarget, root: resolvedRoot) else {
            throw LoadFailure.outsideWorkspace
        }
        let suffix = String(target.path.dropFirst(lexicalRoot.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !suffix.isEmpty else { throw LoadFailure.notAFile }
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { throw LoadFailure.notAFile }

        let rootDescriptor = resolvedRoot.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard rootDescriptor >= 0 else { throw LoadFailure.notAFile }
        var currentDescriptor = rootDescriptor
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (isLast ? 0 : O_DIRECTORY)
            let nextDescriptor = component.withCString { name in
                openat(currentDescriptor, name, flags)
            }
            guard nextDescriptor >= 0 else {
                close(currentDescriptor)
                throw LoadFailure.notAFile
            }
            close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return try validateRegularDescriptor(currentDescriptor)
    }

    private func validateRegularDescriptor(_ descriptor: Int32) throws -> Int32 {
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG
        else {
            close(descriptor)
            throw LoadFailure.notAFile
        }
        if maximumEditableBytes != Int.max,
           fileStat.st_size > off_t(maximumEditableBytes) {
            let byteCount = fileStat.st_size > off_t(Int.max)
                ? Int.max
                : Int(fileStat.st_size)
            close(descriptor)
            throw LoadFailure.tooLarge(byteCount: byteCount)
        }
        return descriptor
    }

    private func resolvedExistingURL(_ url: URL) -> URL {
        let resolvedPath: String? = url.path.withCString { path in
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        return URL(fileURLWithPath: resolvedPath ?? url.path).standardizedFileURL
    }

    private func standardizedResolvedDirectoryURL(_ url: URL) -> URL {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private func canonicalDirectoryURL(_ url: URL) -> URL {
        resolvedExistingURL(url)
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        guard url.path != root.path else { return true }
        if root.path == "/" { return url.path.hasPrefix("/") }
        return url.path.hasPrefix(root.path + "/")
    }
}
