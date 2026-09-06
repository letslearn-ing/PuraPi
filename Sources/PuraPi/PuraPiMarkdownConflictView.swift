import SwiftUI

/// Markdown 外部修改冲突提示和只读差异查看。
@MainActor
struct PuraPiMarkdownConflictBar: View {
    @Environment(\.puraPiTheme) private var theme
    @State private var showingDiff = false

    let conflict: PuraPiMarkdownEditorState.Conflict
    let localText: String
    let language: PuraPiInterfaceLanguage
    let onReload: () -> Void
    let onOverwrite: () -> Void
    let onDismiss: () -> Void

    private var isEnglish: Bool { language == .english }

    private var title: String {
        switch conflict.kind {
        case .modified:
            return isEnglish ? "File changed on disk" : "文件已被外部修改"
        case .deleted:
            return isEnglish ? "File was deleted" : "文件已被删除"
        case .unreadable:
            return isEnglish ? "File can no longer be read" : "文件已无法读取"
        }
    }

    private var detail: String {
        switch conflict.kind {
        case .modified:
            return isEnglish
                ? "Agent or another app edited this file while you were editing."
                : "你编辑期间，Agent 或其他程序改动了这个文件。"
        case .deleted:
            return isEnglish
                ? "The file is gone. Restore your version or discard it."
                : "文件已不存在。你可以恢复自己的版本，或放弃本地内容。"
        case .unreadable:
            return isEnglish
                ? "The file exists but its contents cannot be decoded safely."
                : "文件仍存在，但无法安全解码其内容。"
        }
    }

    private var reloadLabel: String {
        switch conflict.kind {
        case .modified: return isEnglish ? "Use disk version" : "用磁盘版本"
        case .deleted, .unreadable: return isEnglish ? "Discard local version" : "放弃本地版本"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(reloadLabel, action: onReload)
                .controlSize(.small)
            Button(isEnglish ? "Keep mine" : "保留我的", action: onOverwrite)
                .controlSize(.small)
            Button(isEnglish ? "View diff" : "查看差异") {
                showingDiff = true
            }
            .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isEnglish ? "Decide later" : "稍后决定")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.warning.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .sheet(isPresented: $showingDiff) {
            PuraPiMarkdownConflictDiffView(
                localText: localText,
                diskText: conflict.diskText,
                language: language
            )
        }
    }
}

@MainActor
private struct PuraPiMarkdownConflictDiffView: View {
    @Environment(\.dismiss) private var dismiss

    let localText: String
    let diskText: String
    let language: PuraPiInterfaceLanguage

    private let previewLimit = 128 * 1024

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isEnglish ? "Review file changes" : "查看文件差异")
                    .font(.headline)
                Spacer()
                Button(isEnglish ? "Done" : "完成") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 12) {
                column(
                    title: isEnglish ? "My version" : "我的版本",
                    text: localText
                )
                column(
                    title: isEnglish ? "Disk version" : "磁盘版本",
                    text: diskText
                )
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 460)
    }

    private func column(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(verbatim: boundedPreview(text))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func boundedPreview(_ text: String) -> String {
        guard text.utf8.count > previewLimit else { return text }
        let prefix = String(decoding: text.utf8.prefix(previewLimit), as: UTF8.self)
        return prefix + "\n…（差异预览已限制为 128 KiB）"
    }
}
