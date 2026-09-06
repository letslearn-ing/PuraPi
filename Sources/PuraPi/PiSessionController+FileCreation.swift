import AppKit
import Darwin
import Foundation
import PiDomain
import WorkspaceKit

/// 在文件树中新建文件与文件夹。
///
/// 层级规则：在文件夹上右键创建的项落在该文件夹**内部**；在文件上右键创建的项
/// 落在它的**同级**（父目录）；在空白处创建的项落在项目根目录下。
extension PiSessionController {
    /// 计算新建项的父目录。
    ///
    /// - Parameter anchor: 右键点击的节点；nil 表示空白处。
    func creationParentDirectory(for anchor: FileNode?) -> URL? {
        guard let workspace else { return nil }
        guard let anchor else { return workspace.rootURL }
        // 文件的兄弟位置是它的父目录；目录本身就是容器。
        return anchor.isDirectory ? anchor.url : anchor.url.deletingLastPathComponent()
    }

    func createFile(in anchor: FileNode?, name: String) {
        guard let parent = creationParentDirectory(for: anchor) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let safeName = Self.sanitizedEntryName(trimmed) else {
            lastError = "文件名不合法。"
            return
        }
        do {
            let (parentDescriptor, createdName) = try createEntryParent(
                parent: parent,
                preferredName: safeName,
                directory: false
            )
            defer { close(parentDescriptor) }
            let targetDescriptor = createdName.withCString { name in
                openat(parentDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, mode_t(0o644))
            }
            guard targetDescriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            close(targetDescriptor)
            let target = parent.appendingPathComponent(createdName)
            refreshFileTree(expanding: parent)
            selectFile(target)
        } catch {
            lastError = "无法创建文件：\(error.localizedDescription)"
        }
    }

    func createDirectory(in anchor: FileNode?, name: String) {
        guard let parent = creationParentDirectory(for: anchor) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let safeName = Self.sanitizedEntryName(trimmed) else {
            lastError = "文件夹名不合法。"
            return
        }
        do {
            let (parentDescriptor, createdName) = try createEntryParent(
                parent: parent,
                preferredName: safeName,
                directory: true
            )
            defer { close(parentDescriptor) }
            let result = createdName.withCString { name in
                mkdirat(parentDescriptor, name, mode_t(0o755))
            }
            guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
            refreshFileTree(expanding: parent.appendingPathComponent(createdName))
        } catch {
            lastError = "无法创建文件夹：\(error.localizedDescription)"
        }
    }

    /// Opens the parent directory once and chooses a free name without a path
    /// existence check. The final create/mkdir is therefore the race winner and
    /// cannot be redirected by a parent symlink replacement.
    private func createEntryParent(
        parent: URL,
        preferredName: String,
        directory: Bool
    ) throws -> (Int32, String) {
        guard let workspace,
              isInside(parent.standardizedFileURL, root: workspace.rootURL) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let root = workspace.rootURL.standardizedFileURL
        let parentURL = parent.standardizedFileURL
        let suffix = String(parentURL.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        var descriptor = root.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        for component in components {
            let next = component.withCString { name in
                openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else { close(descriptor); throw CocoaError(.fileWriteNoPermission) }
            close(descriptor)
            descriptor = next
        }

        let baseURL = parentURL.appendingPathComponent(preferredName)
        let base = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        for index in 1..<1_000 {
            let candidate = index == 1
                ? preferredName
                : (ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
            let probe = candidate.withCString { name in openat(descriptor, name, flags) }
            if probe < 0, errno == ENOENT { return (descriptor, candidate) }
            if probe >= 0 { close(probe) }
        }
        close(descriptor)
        throw CocoaError(.fileWriteUnknown)
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    /// 拒绝路径分隔符与特殊名，避免越出目标目录。
    static func sanitizedEntryName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        guard !name.contains("/"),
              !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        return name
    }

    /// 只重载受影响的那个目录。
    ///
    /// 不做整树重载：目录是懒加载的，整树重载会把用户已展开的层级全部收起。
    private func refreshFileTree(expanding directory: URL) {
        guard let workspace else { return }
        let services = self.services
        let root = workspace.rootURL
        let generation = self.generation
        let target = directory.standardizedFileURL

        Task { [weak self] in
            let children = try? await Task.detached(priority: .userInitiated) {
                try services.loadDirectoryChildren(directoryURL: target, rootURL: root)
            }.value
            guard let self, self.generation == generation,
                  let children,
                  let currentRoot = self.fileTree,
                  let node = self.findNode(url: target, in: currentRoot)
            else { return }

            self.fileTree = self.replacingNode(
                in: currentRoot,
                targetURL: target,
                with: FileNode(
                    url: node.url,
                    name: node.name,
                    kind: node.kind,
                    children: children,
                    childrenLoaded: true
                )
            )
            // 通知文件树展开该目录，用户才能看到新建的项。
            self.directoryToReveal = target
        }
    }
}
