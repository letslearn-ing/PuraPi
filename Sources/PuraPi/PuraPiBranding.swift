import AppKit
import SwiftUI

/// PuraPi 的用户可见品牌常量。
///
/// SwiftPM target、内部类型、窗口和资源都已统一使用 `PuraPi`；这里只集中管理
/// 用户会在窗口、菜单和空工作区中看到的产品品牌，避免名称再次散落在源码里。
enum PuraPiBranding {
    static let name = "PuraPi"
    static let subtitle = "A native macOS client for Pi"
    static let markResourceName = "PuraPiMark"
    static let markWhiteResourceName = "PuraPiMarkWhite"
    static let appIconResourceName = "PuraPiAppIcon"

    /// SwiftPM executable 没有 Xcode Asset Catalog 时，主动把导出的 App Icon
    /// 安装到 NSApplication，保证 `swift run` 预览也能显示新的 Dock 图标。
    static func installApplicationIcon() {
        guard let url = Bundle.module.url(
                  forResource: appIconResourceName,
                  withExtension: "png"
              ),
              let image = NSImage(contentsOf: url)
        else { return }

        image.isTemplate = false
        NSApp.applicationIconImage = image
    }
}

/// 可复用的 PuraPi Logo lockup（标志与字标组合），用于 App 空工作区等
/// 没有项目内容的品牌入口。浅色/深色外观分别使用对应的单色资源。
struct PuraPiBrandLockup: View {
    @Environment(\.colorScheme) private var colorScheme
    var markSize: CGFloat = 58
    var showsSubtitle = true

    private var markResourceName: String {
        colorScheme == .dark
            ? PuraPiBranding.markWhiteResourceName
            : PuraPiBranding.markResourceName
    }

    private var markImage: NSImage? {
        guard let url = Bundle.module.url(
                  forResource: markResourceName,
                  withExtension: "png"
              )
        else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let markImage {
                Image(nsImage: markImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
                    .accessibilityLabel(PuraPiBranding.name)
            }

            Text(PuraPiBranding.name)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.35)

            if showsSubtitle {
                Text(PuraPiBranding.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            showsSubtitle
                ? "\(PuraPiBranding.name)，\(PuraPiBranding.subtitle)"
                : PuraPiBranding.name
        )
    }
}
