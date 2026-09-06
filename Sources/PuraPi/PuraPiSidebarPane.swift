import PiDomain
import SwiftUI

/// Sidebar 的两种模式。
enum PuraPiSidebarMode: String, CaseIterable, Identifiable {
    case files
    case sessions

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .files: return "folder"
        case .sessions: return "bubble.left.and.bubble.right"
        }
    }

    /// 工具栏图标的 tooltip。工具栏项在语言切换时不重建，因此这里给双语合并文案。
    var helpText: String {
        switch self {
        case .files: return "文件 / Files"
        case .sessions: return "会话 / Sessions"
        }
    }

    func title(language: PuraPiInterfaceLanguage) -> String {
        let english = language == .english
        switch self {
        case .files: return english ? "Files" : "文件"
        case .sessions: return english ? "Sessions" : "会话"
        }
    }
}

/// Sidebar 容器：在文件树与会话树之间切换。
///
/// 两种模式共用同一套滚动与材质语言，用户不需要学新交互。
struct PuraPiSidebarPane: View {
    @Environment(\.puraPiSidebarTint) private var sidebarTint
    @Environment(\.puraPiTheme) private var theme
    @ObservedObject var session: PiSessionController
    @ObservedObject var layoutState: PuraPiLayoutState
    let language: PuraPiInterfaceLanguage
    let usesNativeSidebarChrome: Bool

    /// 模式由标题栏工具栏项切换，因此状态存在 `PuraPiLayoutState` 上而非本地。
    private var mode: PuraPiSidebarMode { layoutState.sidebarMode }
    /// 待命名的新建项。
    struct CreationRequest: Identifiable {
        let id = UUID()
        let anchor: FileNode?
        let isDirectory: Bool
    }

    @State private var creationRequest: CreationRequest?
    @State private var creationName = ""
    @State private var previewedSessionID: String?
    @State private var renameTarget: PiSessionSummary?
    @State private var renameText = ""

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(spacing: 0) {
            // 交通灯与模式切换图标都在标题栏工具栏那一层；原生路径只保留
            // 交通灯下方的紧凑安全区，legacy 路径保留完整标题栏安全区。
            Color.clear
                .frame(
                    height: usesNativeSidebarChrome
                        ? PuraPiLayoutState.nativeSidebarContentTopInset
                        : PuraPiLayoutState.sidebarContentTopInset
                )

            switch mode {
            case .files:
                FileTreePane(
                    root: session.fileTree,
                    selectedURL: session.selectedFileURL,
                    onSelect: session.selectFile,
                    onToggleDirectory: session.toggleDirectory,
                    onClearSelection: session.clearFileSelection,
                    onReveal: session.revealInFinder,
                    onOpen: session.openWithDefaultApplication,
                    onCopyPath: { session.copyPath($0, relative: false) },
                    onCopyRelativePath: { session.copyPath($0, relative: true) },
                    onCreateFile: { anchor in
                        creationRequest = CreationRequest(anchor: anchor, isDirectory: false)
                    },
                    onCreateDirectory: { anchor in
                        creationRequest = CreationRequest(anchor: anchor, isDirectory: true)
                    },
                    directoryToReveal: session.directoryToReveal,
                    usesNativeSidebarChrome: usesNativeSidebarChrome,
                    reservesTopSafeArea: false,
                    providesOwnSurface: false
                )
                .layoutPriority(1)
            case .sessions:
                SessionTreePane(
                    sessions: session.sessionSummaries,
                    turns: session.sessionTurns,
                    activeSessionPath: session.activeSessionFilePath,
                    previewedSessionID: previewedSessionID,
                    language: language,
                    onPreview: { summary in
                        previewedSessionID = summary.id
                        session.loadTurns(for: summary)
                    },
                    onRequestTurns: { session.loadTurns(for: $0) },
                    onSwitch: { session.switchToSession($0) },
                    onFork: { session.forkSession(from: $0) },
                    onRename: { beginRename($0) },
                    onClone: { _ in session.cloneCurrentSession() },
                    onOpenTurn: { summary, turn in
                        session.openTurn(turn, in: summary)
                    }
                )
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 表面在容器这一层绘制，让交通灯安全区、文件树与会话树共用同一底色。
        .puraPiSidebarSurface(tint: sidebarTint)
        .sheet(isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            if let renameTarget {
                renameSheet(for: renameTarget)
            }
        }
        .sheet(item: $creationRequest) { request in
            PuraPiCreateEntrySheet(
                isDirectory: request.isDirectory,
                parentName: creationParentName(for: request.anchor),
                name: $creationName,
                language: language,
                onCancel: {
                    creationRequest = nil
                    creationName = ""
                },
                onConfirm: {
                    if request.isDirectory {
                        session.createDirectory(in: request.anchor, name: creationName)
                    } else {
                        session.createFile(in: request.anchor, name: creationName)
                    }
                    creationRequest = nil
                    creationName = ""
                }
            )
        }
        // 切到会话树时刷新一次，避免显示过期列表。切换动作发生在工具栏项里，
        // 因此这里观察共享状态，而不是写在按钮回调。
        .onChange(of: mode) { _, newMode in
            if newMode == .sessions {
                session.reloadSessionList()
            }
        }
    }

    /// 目标父目录的显示名，用于让用户确认层级。
    private func creationParentName(for anchor: FileNode?) -> String {
        guard let url = session.creationParentDirectory(for: anchor) else {
            return isEnglish ? "project root" : "项目根目录"
        }
        return url.lastPathComponent
    }

    private func beginRename(_ summary: PiSessionSummary) {
        // 预填当前实际显示的标题而不是只填 `name`：未命名会话的标题来自首条
        // 用户消息，只填 `name` 会给出空框，用户得从零重写。
        renameText = summary.name ?? summary.displayTitle(dateFormatter: Self.renameDateFormatter)
        renameTarget = summary
    }

    private static let renameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private func renameSheet(for target: PiSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEnglish ? "Rename Session" : "重命名会话")
                .font(.system(size: 13, weight: .semibold))

            TextField(
                isEnglish ? "Session name" : "会话名称",
                text: $renameText
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)

            Text(
                isEnglish
                    ? "Pi currently requires a non-empty session name."
                    : "Pi 当前要求会话名称不能为空。"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button(isEnglish ? "Cancel" : "取消") {
                    renameTarget = nil
                }
                Button(isEnglish ? "Save" : "保存") {
                    session.renameCurrentSession(to: renameText)
                    if !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        renameTarget = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
        // 与授权弹窗同一套玻璃语言；macOS 14–25 由修饰器内部降级。
        // 纯玻璃：不加 tint。给 Glass 上色会让材质变成一块不透明底板，
        // 失去液态玻璃透出背后内容的特征。强调色只用在控件（保存按钮）上。
        .puraPiGlassSurface(
            role: .glass,
            cornerRadius: 18,
            interactive: true
        )
        .tint(theme.accent)
        .puraPiPresentationGlassChrome()
    }
}


/// 新建文件/文件夹的命名弹窗。
///
/// 明确显示目标父目录，避免用户误以为创建在了别处——层级关系是这个功能
/// 最容易出错的地方。
@MainActor
struct PuraPiCreateEntrySheet: View {
    @Environment(\.puraPiTheme) private var theme

    let isDirectory: Bool
    let parentName: String
    @Binding var name: String
    let language: PuraPiInterfaceLanguage
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(
                isEnglish
                    ? "Will be created in \(parentName)"
                    : "将创建在 \(parentName)"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(onConfirm)

            HStack {
                Spacer()
                Button(isEnglish ? "Cancel" : "取消", action: onCancel)
                Button(isEnglish ? "Create" : "创建", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
        .puraPiGlassSurface(role: .glass, cornerRadius: 18, interactive: true)
        .tint(theme.accent)
        .puraPiPresentationGlassChrome()
    }

    private var title: String {
        if isDirectory {
            return isEnglish ? "New Folder" : "新建文件夹"
        }
        return isEnglish ? "New File" : "新建文件"
    }

    private var placeholder: String {
        if isDirectory {
            return isEnglish ? "Folder name" : "文件夹名称"
        }
        return isEnglish ? "File name, e.g. notes.md" : "文件名，例如 notes.md"
    }
}
