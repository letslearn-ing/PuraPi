import SwiftUI

/// WorkPi 自己承载的项目授权面板；授权只影响当前项目标签启动的 Pi Runtime。
struct WorkPiProjectAuthorizationView: View {
    @Environment(\.workPiTheme) private var theme

    let rootURL: URL
    let language: WorkPiInterfaceLanguage
    let onAllowOnce: () -> Void
    let onAllowAndRemember: () -> Void
    let onDeny: () -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(theme.accent)

                VStack(alignment: .leading, spacing: 5) {
                    Text(isEnglish ? "Authorize project?" : "授权此项目？")
                        .font(.system(size: 18, weight: .semibold))
                    Text(isEnglish
                         ? "This project contains local extensions or Pi configuration."
                         : "此项目包含本地 Extension（扩展）或 Pi 配置。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }

            Text(isEnglish
                 ? "Allowing it lets Pi load and execute project-local resources. Pura Pi will not modify Pi's global trust file; it will only launch this project's Runtime with explicit approval."
                 : "允许后，Pi 才能加载并执行项目本地资源。Pura Pi 不会修改 Pi 的全局 trust 文件，只会在明确批准后以授权参数启动当前项目的 Runtime。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(rootURL.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(isEnglish ? "Don't Allow" : "不允许", role: .cancel, action: onDeny)
                Spacer()
                Button(isEnglish ? "Allow Once" : "仅本次允许", action: onAllowOnce)
                Button(isEnglish ? "Always Allow" : "始终允许", action: onAllowAndRemember)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .workPiGlassSurface(
            role: .glass,
            cornerRadius: 18,
            interactive: true,
            tint: theme.accent.opacity(0.22)
        )
        .tint(theme.accent)
        .workPiPresentationGlassChrome()
    }
}
