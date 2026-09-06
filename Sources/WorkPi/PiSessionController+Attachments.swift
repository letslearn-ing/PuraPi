import AppKit
import Darwin
import Foundation
import PiDomain
import PiRPC

/// 附件输入：图片与 `@文件` 引用。
///
/// 图片走 Pi 的 `prompt.images`（base64 + MIME）；文件引用则把内容读成文本
/// 拼进消息——Pi 的 prompt 只接受图片附件，没有通用文件通道，
/// 因此文本文件必须由客户端读取后并入消息正文。
extension PiSessionController {
    /// 支持的图片扩展名。不在此列的文件按文本引用处理。
    static let attachableImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    /// 单个文本附件的读取上限。
    ///
    /// 超过就截断：整份大文件塞进 prompt 会挤爆上下文，而用户通常只需要片段。
    static let maximumTextAttachmentBytes = 64 * 1024
    static let maximumImageAttachmentBytes = 20 * 1024 * 1024
    /// 单条 Prompt 的原始附件上限；保留这个限制是为了控制上下文体积。
    static let maximumTotalAttachmentBytes = 24 * 1024 * 1024
    /// 发送时还会同时保留原始数据、Base64/正文和 JSON 对象，因此用更接近
    /// 实际峰值的内存预算再拦一次。
    static let maximumTotalAttachmentMemoryBytes = 64 * 1024 * 1024
    /// 多条排队任务共享的估算内存上限，避免 immutable 快照无限累积图片数据。
    static let maximumQueuedAttachmentBytes = 128 * 1024 * 1024

    var hasPendingAttachments: Bool { !pendingAttachments.isEmpty }

    private var pendingAttachmentBytes: Int {
        pendingAttachments.reduce(0) { $0 + $1.byteCount }
    }

    private var pendingAttachmentMemoryBytes: Int {
        pendingAttachments.reduce(0) { $0 + $1.estimatedMemoryByteCount }
    }

    /// 添加附件。目录会被忽略；无法读取的文件给出提示而不是静默丢弃。
    func attachFiles(_ urls: [URL]) {
        for url in urls {
            guard attachmentURLIsSafe(url) else {
                lastError = "工作区内的符号链接不能作为附件：\(url.lastPathComponent)"
                continue
            }
            var lexicalStat = stat()
            guard url.path.withCString({ lstat($0, &lexicalStat) }) == 0 else { continue }
            // Keep the existing UX for directories (silently ignore them), but
            // never follow a directory/symlink just to inspect its contents.
            if (lexicalStat.st_mode & S_IFMT) == S_IFDIR { continue }
            let ext = url.pathExtension.lowercased()
            if Self.attachableImageExtensions.contains(ext) {
                guard let image = PiPromptImage(
                    fileURL: url,
                    maximumBytes: Self.maximumImageAttachmentBytes
                ) else {
                    lastError = "无法读取图片：\(url.lastPathComponent)"
                    continue
                }
                let attachment = WorkPiAttachment(url: url, kind: .image(image))
                guard pendingAttachmentBytes + attachment.byteCount <= Self.maximumTotalAttachmentBytes,
                      pendingAttachmentMemoryBytes + attachment.estimatedMemoryByteCount <= Self.maximumTotalAttachmentMemoryBytes
                else {
                    lastError = "附件总大小或发送内存预算超限：\(url.lastPathComponent)"
                    continue
                }
                pendingAttachments.append(attachment)
            } else {
                guard pendingAttachmentBytes + Self.maximumTextAttachmentBytes <= Self.maximumTotalAttachmentBytes else {
                    lastError = "附件原始大小超过 24 MB：\(url.lastPathComponent)"
                    continue
                }
                guard let text = readTextAttachment(url) else {
                    lastError = "无法作为文本读取：\(url.lastPathComponent)"
                    continue
                }
                let attachment = WorkPiAttachment(url: url, kind: .text(text))
                guard pendingAttachmentBytes + attachment.byteCount <= Self.maximumTotalAttachmentBytes,
                      pendingAttachmentMemoryBytes + attachment.estimatedMemoryByteCount <= Self.maximumTotalAttachmentMemoryBytes
                else {
                    lastError = "附件总大小或发送内存预算超限：\(url.lastPathComponent)"
                    continue
                }
                pendingAttachments.append(attachment)
            }
        }
    }

    /// 从剪贴板粘贴图片。
    func attachImageFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        // 先看文件 URL：从 Finder 拷贝的图片是 URL 而不是位图。
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            attachFiles(urls)
            return true
        }
        // Validate the original representation before AppKit decodes it. This
        // rejects malformed data and oversized pixel dimensions before an
        // attacker-controlled compressed image can expand in memory.
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.webp"),
        ]
        guard let sourceData = imageTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).first else {
            return false
        }
        guard sourceData.count <= Self.maximumImageAttachmentBytes,
              WorkPiMarkdownImageInsertion.hasSafeImageDimensions(data: sourceData)
        else {
            lastError = "粘贴的图片超过附件大小或像素限制。"
            return false
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return false }

        let attachment = WorkPiAttachment(
            url: nil,
            kind: .image(PiPromptImage(data: png, mimeType: "image/png"))
        )
        guard png.count <= Self.maximumImageAttachmentBytes,
              pendingAttachmentBytes + attachment.byteCount <= Self.maximumTotalAttachmentBytes,
              pendingAttachmentMemoryBytes + attachment.estimatedMemoryByteCount <= Self.maximumTotalAttachmentMemoryBytes
        else {
            lastError = "粘贴的图片超过附件大小或发送内存预算。"
            return false
        }
        pendingAttachments.append(attachment)
        return true
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    /// 待发送的图片附件，交给 `prompt.images`。
    var pendingPromptImages: [PiPromptImage] {
        promptImages(from: pendingAttachments)
    }

    func promptImages(from attachments: [WorkPiAttachment]) -> [PiPromptImage] {
        attachments.compactMap { attachment in
            guard case .image(let image) = attachment.kind else { return nil }
            return image
        }
    }

    /// 把文本附件拼到消息正文前。
    ///
    /// 用围栏包住并标注文件名，模型才能分清哪段是附件、哪段是用户的话。
    func messageWithTextAttachments(_ message: String) -> String {
        messageWithTextAttachments(message, attachments: pendingAttachments)
    }

    func messageWithTextAttachments(
        _ message: String,
        attachments: [WorkPiAttachment]
    ) -> String {
        let textAttachments = attachments.compactMap { attachment -> (String, String)? in
            guard case .text(let content) = attachment.kind else { return nil }
            return (attachment.displayName, content)
        }
        guard !textAttachments.isEmpty else { return message }

        var blocks: [String] = []
        for (name, content) in textAttachments {
            let escapedName = escapeAttachmentAttribute(name)
            blocks.append("<file name=\"\(escapedName)\">\n\(content)\n</file>")
        }
        blocks.append(message)
        return blocks.joined(separator: "\n\n")
    }

    private func escapeAttachmentAttribute(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            switch character {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&apos;")
            case "\n": result.append("&#10;")
            case "\r": result.append("&#13;")
            default: result.append(character)
            }
        }
    }

    /// 工作区内的附件不允许任何路径组件是符号链接，也不允许解析后越出
    /// 工作区；工作区外的文件仍可由用户显式拖入作为附件。
    private func attachmentURLIsSafe(_ url: URL) -> Bool {
        guard let workspace else { return true }
        let root = workspace.rootURL.standardizedFileURL
        let lexical = url.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard lexical.path == root.path || lexical.path.hasPrefix(rootPrefix) else {
            return true
        }
        let resolved = lexical.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPrefix) else {
            return false
        }
        let suffix = String(lexical.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var current = root
        for component in suffix.split(separator: "/", omittingEmptySubsequences: true) {
            current.appendPathComponent(String(component))
            var fileStat = stat()
            guard current.path.withCString({ lstat($0, &fileStat) }) == 0,
                  fileStat.st_mode & S_IFMT != S_IFLNK
            else { return false }
        }
        return true
    }

    private func readTextAttachment(_ url: URL) -> String? {
        guard let descriptor = openRegularAttachmentDescriptor(at: url) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        do {
            var fileStat = stat()
            guard fstat(descriptor, &fileStat) == 0,
                  (fileStat.st_mode & S_IFMT) == S_IFREG else { return nil }
            let limit = Self.maximumTextAttachmentBytes + 1
            let data = try handle.read(upToCount: limit) ?? Data()
            let isTruncated = data.count > Self.maximumTextAttachmentBytes
            var limited = Data(
                isTruncated ? data.prefix(Self.maximumTextAttachmentBytes) : data
            )
            // 截断点可能落在多字节 UTF-8 字符中；退回到最近的有效边界，
            // 不因文件恰好在边界处包含中文而误报不可读。
            while String(data: limited, encoding: .utf8) == nil, !limited.isEmpty {
                limited.removeLast()
            }
            guard let text = String(data: limited, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.value == 0 })
            else { return nil }
            return isTruncated
                ? text + "\n…（文件已截断，仅包含前 64 KB）"
                : text
        } catch {
            return nil
        }
    }

    private func openRegularAttachmentDescriptor(at url: URL) -> Int32? {
        // Resolve ancestor links (for example /tmp -> /private/tmp), but
        // reject a symlink at the final component before resolving the path.
        let lexicalURL = url.standardizedFileURL
        var lexicalStat = stat()
        guard lstat(lexicalURL.path, &lexicalStat) == 0,
              (lexicalStat.st_mode & S_IFMT) != S_IFLNK
        else { return nil }
        let parentPath = lexicalURL.deletingLastPathComponent().path
        guard let resolvedParent = parentPath.withCString({ realpath($0, nil) }) else {
            return nil
        }
        defer { free(resolvedParent) }
        let path = String(cString: resolvedParent) + "/" + lexicalURL.lastPathComponent
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else { return nil }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = component.withCString { name in openat(current, name, flags) }
            guard next >= 0 else {
                close(current)
                return nil
            }
            close(current)
            current = next
        }
        var fileStat = stat()
        guard fstat(current, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG
        else {
            close(current)
            return nil
        }
        return current
    }
}
