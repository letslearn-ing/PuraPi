import AppKit
import SwiftUI

/// 只读 Inspector 图片的安全预览宿主。
///
/// 文件读取和缩略图生成在后台完成；主线程只解码有界的预览数据，避免 20 MB
/// 以内的高压缩图片把 UI 线程拖住。工作区根目录存在时，读取还会经过逐级边界校验。
@MainActor
struct PuraPiSafeImageView: View {
    @Environment(\.puraPiTheme) private var theme

    let url: URL
    let workspaceRoot: URL?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("图片预览")
            } else if failed {
                Label("图片无法预览", systemImage: "photo.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(8)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.panelBorder.opacity(0.65), lineWidth: 0.7)
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        image = nil
        failed = false
        let previewData: Data? = await Task.detached(priority: .utility) { () async -> Data? in
            await Task.yield()
            guard !Task.isCancelled else { return nil }
            let data: Data?
            if let workspaceRoot {
                data = PuraPiMarkdownImageInsertion.readImageData(
                    at: url,
                    workspaceRoot: workspaceRoot
                )
            } else {
                data = PuraPiMarkdownImageInsertion.readImageData(at: url)
            }
            guard let data else { return nil }
            return PuraPiMarkdownImageInsertion.safePreviewData(from: data)
        }.value
        guard !Task.isCancelled,
              let previewData,
              let decoded = NSImage(data: previewData)
        else {
            failed = true
            return
        }
        image = decoded
    }
}
