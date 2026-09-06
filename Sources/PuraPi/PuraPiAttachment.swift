import Foundation
import PiRPC

/// 待发送的附件。
///
/// 放在 PuraPi 层而不是 `PiDomain`：图片类型直接用 `PiRPC.PiPromptImage`，
/// 而 `PiDomain` 不允许依赖 `PiRPC`（下层不得反向依赖上层）。
struct PuraPiAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 图片走 Pi 的 `prompt.images`。
        case image(PiPromptImage)
        /// 文本内容拼进消息正文——Pi 的 prompt 没有通用文件通道。
        case text(String)
    }

    let id: UUID
    /// 剪贴板粘贴的图片没有来源文件。
    let url: URL?
    let kind: Kind

    init(id: UUID = UUID(), url: URL?, kind: Kind) {
        self.id = id
        self.url = url
        self.kind = kind
    }

    var displayName: String {
        url?.lastPathComponent ?? "剪贴板图片.png"
    }

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }

    var byteCount: Int {
        switch kind {
        case .image(let image):
            return image.data.count
        case .text(let text):
            return text.utf8.count
        }
    }

    /// 估算附件在发送和排队期间的实际内存：原始数据、Base64/正文副本、
    /// JSON 字段以及少量对象开销。只用 byteCount 会漏算图片 Base64 的约 4/3 膨胀。
    var estimatedMemoryByteCount: Int {
        let encodedBytes: Int
        switch kind {
        case .image:
            encodedBytes = ((byteCount + 2) / 3) * 4
        case .text:
            encodedBytes = byteCount
        }
        return byteCount + encodedBytes + 8 * 1024
    }
}
