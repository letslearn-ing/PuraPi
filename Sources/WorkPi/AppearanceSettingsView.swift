import SwiftUI
import UniformTypeIdentifiers

enum WorkPiSettingsTab: Hashable {
    case appearance
    case themes
    case runtime
    case accounts
}

/// WorkPi 的设置窗口，使用持久化状态控制外观、主题、Runtime 和账号认证。
@MainActor
struct WorkPiAppearanceSettingsView: View {
    @ObservedObject var appearanceState: WorkPiAppearanceState
    @ObservedObject var runtimeProvisioner: WorkPiRuntimeProvisioner
    @ObservedObject var authCoordinator: WorkPiAuthCoordinator
    @State private var selectedTab: WorkPiSettingsTab = .appearance

    init(
        appearanceState: WorkPiAppearanceState,
        runtimeProvisioner: WorkPiRuntimeProvisioner,
        authCoordinator: WorkPiAuthCoordinator,
        initialTab: WorkPiSettingsTab = .appearance
    ) {
        self.appearanceState = appearanceState
        self.runtimeProvisioner = runtimeProvisioner
        self.authCoordinator = authCoordinator
        _selectedTab = State(initialValue: initialTab)
    }

    init(
        appearanceState: WorkPiAppearanceState,
        runtimeProvisioner: WorkPiRuntimeProvisioner
    ) {
        self.init(
            appearanceState: appearanceState,
            runtimeProvisioner: runtimeProvisioner,
            authCoordinator: WorkPiAuthCoordinator(
                selection: runtimeProvisioner.selection
            )
        )
    }

    @MainActor
    init(appearanceState: WorkPiAppearanceState) {
        self.init(
            appearanceState: appearanceState,
            runtimeProvisioner: WorkPiRuntimeProvisioner()
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            appearancePage
                .tag(WorkPiSettingsTab.appearance)
                .tabItem {
                    Label(
                        appearanceState.language == .english ? "Appearance" : "外观",
                        systemImage: "sun.max"
                    )
                }

            WorkPiThemeSettingsView(appearanceState: appearanceState)
                .tag(WorkPiSettingsTab.themes)
                .tabItem {
                    Label(
                        appearanceState.language == .english ? "Themes" : "主题",
                        systemImage: "paintpalette"
                    )
                }

            WorkPiRuntimeProvisioningView(
                provisioner: runtimeProvisioner,
                language: appearanceState.language
            )
            .tag(WorkPiSettingsTab.runtime)
            .padding(20)
            .tabItem {
                Label(
                    appearanceState.language == .english ? "Runtime" : "运行时",
                    systemImage: "shippingbox"
                )
            }

            WorkPiAccountSettingsView(
                coordinator: authCoordinator,
                language: appearanceState.language
            )
            .tag(WorkPiSettingsTab.accounts)
            .tabItem {
                Label(
                    appearanceState.language == .english ? "Accounts" : "账号",
                    systemImage: "person.badge.key"
                )
            }
        }
        .frame(width: 500, height: 680)
        .workPiTheme(appearanceState.theme)
        .onChange(of: runtimeProvisioner.availability) { _, availability in
            guard availability.isAvailable else { return }
            authCoordinator.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workPiOpenAccountSettings)) { _ in
            selectedTab = .accounts
        }
    }

    @ViewBuilder
    private var appearancePage: some View {
        Form {
            Section("外观") {
                Picker(
                    "界面外观",
                    selection: Binding(
                        get: { appearanceState.mode },
                        set: { appearanceState.setMode($0) }
                    )
                ) {
                    ForEach(WorkPiAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("跟随系统会根据 macOS 当前的浅色或深色外观自动切换。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("语言 / Language") {
                Picker(
                    "界面语言",
                    selection: Binding(
                        get: { appearanceState.language },
                        set: { appearanceState.setLanguage($0) }
                    )
                ) {
                    ForEach(WorkPiInterfaceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("命令选择器会根据此设置显示中文或英文说明。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(
                appearanceState.language == .english ? "Pane Colors" : "栏颜色 / Pane Colors"
            ) {
                WorkPiPaneTintPicker(
                    title: appearanceState.language == .english ? "Sidebar" : "左侧 Sidebar",
                    selection: appearanceState.sidebarTint,
                    language: appearanceState.language,
                    onSelect: appearanceState.setSidebarTint
                )

                WorkPiPaneTintPicker(
                    title: appearanceState.language == .english ? "Inspector" : "右侧 Inspector",
                    selection: appearanceState.inspectorTint,
                    language: appearanceState.language,
                    onSelect: appearanceState.setInspectorTint
                )

                Text(
                    appearanceState.language == .english
                        ? "Choose a swatch to tint each pane independently. No color leaves the Sidebar as system glass; the Inspector uses a neutral surface without the blue system tint."
                        : "可分别设置两栏的颜色。选择“无颜色”时，左栏显示系统材质；右栏使用不带蓝色系统底光的中性表面。"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("项目授权") {
                WorkPiTrustedProjectsSettings()
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

/// 主题选择页。主题定义是数据而不是可执行插件；外部 `.workpitheme` 包只会
/// 经过 `WorkPiThemeStore` 校验后加入列表。
struct WorkPiThemeSettingsView: View {
    @Environment(\.workPiTheme) private var theme
    @ObservedObject var appearanceState: WorkPiAppearanceState
    @State private var isImporting = false
    @State private var importError: String?

    private var isEnglish: Bool { appearanceState.language == .english }
    private var externalThemes: [WorkPiTheme] {
        let builtInIDs = Set(WorkPiThemeCatalog.builtInThemes.map(\.id))
        return appearanceState.availableThemes.filter { !builtInIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isEnglish ? "Choose a theme" : "选择主题")
                        .font(.system(size: 18, weight: .semibold))
                    Text(
                        isEnglish
                            ? "Themes change semantic colors while preserving Pura Pi's layout and interactions."
                            : "主题只改变语义颜色和视觉令牌，不改变 Pura Pi 的布局与交互。"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    ForEach(appearanceState.availableThemes) { theme in
                        WorkPiThemeCard(
                            theme: theme,
                            language: appearanceState.language,
                            isSelected: appearanceState.theme.id == theme.id,
                            onSelect: { appearanceState.setTheme(theme) }
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            isEnglish ? "Theme packages" : "主题包",
                            systemImage: "shippingbox"
                        )
                        .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Button(isEnglish ? "Import…" : "导入…") {
                            isImporting = true
                        }
                        .controlSize(.small)
                    }
                    Text(
                        isEnglish
                            ? "Packages contain data and assets only. Pura Pi validates their schema, paths, sizes, permissions, and optional checksums; packages cannot access sessions, files, commands, or security settings."
                            : "主题包只包含数据和资源。Pura Pi 会校验 schema、路径、大小、权限和可选校验和；主题包不能访问会话、文件、命令或安全设置。"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(externalThemes) { theme in
                        HStack(spacing: 8) {
                            Text(theme.title(language: appearanceState.language))
                                .font(.system(size: 11.5))
                            Spacer()
                            Button(isEnglish ? "Delete" : "删除") {
                                _ = appearanceState.deleteTheme(id: theme.id)
                            }
                            .controlSize(.small)
                        }
                    }
                    if let importError {
                        Text(importError)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.error)
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            appearanceState.reloadThemes()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                if !appearanceState.importThemePackage(from: url) {
                    importError = isEnglish ? "The theme package is invalid." : "主题包无效，未能导入。"
                } else {
                    importError = nil
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }
}

private struct WorkPiThemeCard: View {
    let theme: WorkPiTheme
    let language: WorkPiInterfaceLanguage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.workspaceBackground)
                        .frame(height: 82)

                    HStack(alignment: .bottom, spacing: 5) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.accent.opacity(0.25))
                            .frame(width: 43, height: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.accent.opacity(0.72))
                                .frame(width: 75, height: 9)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.panelBorder)
                                .frame(width: 93, height: 7)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.panelBorder.opacity(0.55))
                                .frame(width: 64, height: 7)
                        }
                        .padding(.bottom, 14)
                    }
                    .padding(10)
                }

                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(theme.title(language: language))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(theme.summary(language: language))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.08 : 0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title(language: language))
        .accessibilityValue(isSelected ? (language == .english ? "Selected" : "已选择") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 一行可直接点击的颜色小方格。
///
/// `none` 不是一种颜色：它用带斜线的中性方格表示。选中后，Sidebar 会保留
/// 系统材质；Inspector 则会主动盖掉系统玻璃的蓝色底光，避免“无颜色”仍带蓝调。
private struct WorkPiPaneTintPicker: View {
    @Environment(\.workPiTheme) private var theme

    let title: String
    let selection: WorkPiPaneTint
    let language: WorkPiInterfaceLanguage
    let onSelect: (WorkPiPaneTint) -> Void

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))

            HStack(alignment: .center, spacing: 12) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(WorkPiPaneTint.allCases) { tint in
                        Button {
                            onSelect(tint)
                        } label: {
                            swatch(for: tint)
                        }
                        .buttonStyle(.plain)
                        .help(tint.title(language: language))
                        .accessibilityLabel(tint.title(language: language))
                        .accessibilityValue(
                            tint == selection
                                ? (language == .english ? "Selected" : "已选择")
                                : ""
                        )
                        .accessibilityAddTraits(tint == selection ? .isSelected : [])
                    }
                }

                Text(selection.title(language: language))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 42, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func swatch(for tint: WorkPiPaneTint) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    tint == .none
                        ? theme.windowBackground
                        : (tint.resolvedColor(using: theme) ?? theme.accent)
                )

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)

            if tint == .none {
                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 2, height: 25)
                    .rotationEffect(.degrees(45))
            }

            if tint == selection {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint == .none ? Color.primary : Color.white)
                    .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
            }
        }
        .frame(width: 28, height: 28)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    tint == selection ? theme.accent : Color.clear,
                    lineWidth: tint == selection ? 2 : 0
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 已授权项目的撤销入口。
///
/// 「始终允许」会把项目路径写进本地偏好，之后启动 Pi 时自动带 `--approve`。
/// 没有撤销入口的话，用户一旦误点「始终允许」就无法反悔——这属于安全相关的
/// 决定，必须可见且可逆。
struct WorkPiTrustedProjectsSettings: View {
    @Environment(\.workPiTheme) private var theme
    @State private var paths: [String] = WorkPiProjectAuthorization.rememberedProjectPaths()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if paths.isEmpty {
                Text("还没有始终允许的项目。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("这些项目在启动 Pi 时会自动授予命令执行权限。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accent)
                        Text(abbreviated(path))
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer(minLength: 8)
                        Button("撤销") {
                            revoke(path)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onAppear {
            // 设置窗口可能在授权变更后重新打开，每次显示都重读。
            paths = WorkPiProjectAuthorization.rememberedProjectPaths()
        }
    }

    private func revoke(_ path: String) {
        WorkPiProjectAuthorization.forget(URL(fileURLWithPath: path))
        paths = WorkPiProjectAuthorization.rememberedProjectPaths()
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
