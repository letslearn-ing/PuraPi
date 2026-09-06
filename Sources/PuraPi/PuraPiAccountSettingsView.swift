import SwiftUI

/// 账号与认证设置页。凭据由 Pi 官方 `AuthStorage` 保存，PuraPi 只展示非敏感状态。
@MainActor
struct PuraPiAccountSettingsView: View {
    @Environment(\.puraPiTheme) private var theme
    @ObservedObject var coordinator: PuraPiAuthCoordinator
    let language: PuraPiInterfaceLanguage

    @State private var showingOtherProviders = false
    @State private var showingModels = false
    @State private var logoutProviderID: String?
    @State private var showingLogoutConfirmation = false
    @State private var loginProviderID: String?
    @State private var loginType: PuraPiAuthType?
    @State private var showingLoginConfirmation = false

    private var isEnglish: Bool { language == .english }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusArea
                featuredProviderList
                otherProviderList
                orphanedCredentialList
                modelList
                storageNote
            }
            .padding(20)
        }
        .onAppear {
            coordinator.refreshStatus()
        }
        .sheet(item: Binding<PuraPiAuthPrompt?>(
            get: { coordinator.pendingPrompt },
            // 关闭动作由 sheet 内容的 onDisappear 按 Prompt ID 处理；不能在这里
            // 无条件取消当前 Prompt，否则旧 sheet 的关闭回调可能取消新请求。
            set: { _ in }
        )) { prompt in
            PuraPiAuthPromptSheet(
                coordinator: coordinator,
                prompt: prompt,
                language: language
            )
            .id(prompt.id)
            .onDisappear {
                coordinator.cancelPendingPrompt(for: prompt.id)
            }
        }
        .confirmationDialog(
            isEnglish ? "Replace the current authentication method?" : "替换当前认证方式？",
            isPresented: $showingLoginConfirmation,
            titleVisibility: .visible
        ) {
            Button(isEnglish ? "Continue" : "继续") {
                guard let loginProviderID, let loginType else { return }
                coordinator.login(providerID: loginProviderID, type: loginType)
                self.loginProviderID = nil
                self.loginType = nil
            }
            Button(isEnglish ? "Cancel" : "取消", role: .cancel) {
                loginProviderID = nil
                loginType = nil
            }
        } message: {
            Text(
                isEnglish
                    ? "Pi keeps one credential per provider. Continuing replaces the currently stored method for this provider."
                    : "Pi 每个 Provider 只保存一种凭据。继续操作会替换该 Provider 当前保存的认证方式。"
            )
        }
        .confirmationDialog(
            isEnglish ? "Sign out of this provider?" : "退出这个 Provider 的登录？",
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(isEnglish ? "Sign Out" : "退出登录", role: .destructive) {
                guard let logoutProviderID else { return }
                coordinator.logout(providerID: logoutProviderID)
                self.logoutProviderID = nil
            }
            Button(isEnglish ? "Cancel" : "取消", role: .cancel) {
                logoutProviderID = nil
            }
        } message: {
            Text(
                isEnglish
                    ? "This removes the credential saved by Pi. Environment variables and models.json are not changed."
                    : "这只会删除 Pi 保存的凭据，不会修改环境变量或 models.json。"
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                isEnglish ? "Accounts & Authentication" : "账号与认证",
                systemImage: "person.badge.key"
            )
            .font(.system(size: 18, weight: .semibold))

            Text(
                isEnglish
                    ? "Sign in with a subscription or configure an API key through Pi's official authentication runtime."
                    : "通过 Pi 官方认证运行时登录订阅账号，或配置 API Key。"
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if coordinator.isBusy {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(phaseTitle)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(isEnglish ? "Cancel" : "取消") {
                    coordinator.cancelOperation()
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(themeSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
        }

        if let event = coordinator.currentEvent {
            PuraPiAuthEventView(event: event, language: language)
        }

        if let message = coordinator.operationMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: messageIsError ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(messageIsError ? .red : .secondary)
                Text(message)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                (messageIsError ? theme.error : theme.info).opacity(0.09),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }

        if messageIsError {
            Button(isEnglish ? "Dismiss" : "关闭提示") {
                coordinator.clearMessage()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }

        if !coordinator.refreshWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    isEnglish ? "Some model catalogs could not be refreshed" : "部分模型目录刷新失败",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11.5, weight: .medium))
                ForEach(Array(coordinator.refreshWarnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }

        if coordinator.runtimeRestartRequired {
            HStack(alignment: .top, spacing: 8) {
                Label(
                    isEnglish
                        ? "Running project Runtimes need reconnecting to use the updated credential."
                        : "正在运行的项目需要重新连接 Runtime 才会使用更新后的凭据。",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(isEnglish ? "Dismiss" : "关闭提示") {
                    coordinator.acknowledgeRuntimeRestartRequirement()
                }
                .buttonStyle(.link)
                .font(.system(size: 10.5))
            }
        }
    }

    private var featuredProviderList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(isEnglish ? "Recommended providers" : "推荐 Provider")
            if coordinator.featuredProviders.isEmpty {
                emptyProviderText
            } else {
                ForEach(coordinator.featuredProviders) { provider in
                    PuraPiAuthProviderCard(
                        provider: provider,
                        language: language,
                        isDisabled: coordinator.isBusy,
                        onLogin: { type in beginLogin(provider: provider, type: type) },
                        onLogout: {
                            logoutProviderID = provider.id
                            showingLogoutConfirmation = true
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var otherProviderList: some View {
        if !coordinator.otherProviders.isEmpty {
            DisclosureGroup(
                isExpanded: $showingOtherProviders,
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.otherProviders) { provider in
                            PuraPiAuthProviderCard(
                                provider: provider,
                                language: language,
                                compact: true,
                                isDisabled: coordinator.isBusy,
                                onLogin: { type in beginLogin(provider: provider, type: type) },
                                onLogout: {
                                    logoutProviderID = provider.id
                                    showingLogoutConfirmation = true
                                }
                            )
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    sectionTitle(isEnglish ? "Other Pi providers" : "其他 Pi Provider")
                }
            )
        }
    }

    @ViewBuilder
    private var orphanedCredentialList: some View {
        if !coordinator.orphanedCredentials.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(isEnglish ? "Stored credentials without an auth method" : "没有认证入口的已存凭据")
                Text(
                    isEnglish
                        ? "These credentials are still stored by Pi, but the current SDK has no usable authentication method for them."
                        : "这些凭据仍由 Pi 保存，但当前 SDK 没有可用的认证入口。"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(coordinator.orphanedCredentials) { credential in
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(theme.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credential.providerId)
                                .font(.system(size: 11.5, design: .monospaced))
                            Text(credential.type.shortTitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Button(isEnglish ? "Remove" : "删除", role: .destructive) {
                            logoutProviderID = credential.providerId
                            showingLogoutConfirmation = true
                        }
                        .controlSize(.small)
                        .disabled(coordinator.isBusy)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
            .background(theme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    @ViewBuilder
    private var modelList: some View {
        if !coordinator.snapshot.models.isEmpty {
            DisclosureGroup(
                isExpanded: $showingModels,
                content: {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(coordinator.snapshot.models.prefix(40)), id: \.stableID) { model in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: 5, height: 5)
                                Text(model.selectionKey)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if model.reasoning {
                                    Text(isEnglish ? "Thinking" : "推理")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if coordinator.snapshot.models.count > 40 || coordinator.snapshot.modelsTruncated {
                            Text(isEnglish ? "More models are available in the Runtime model picker." : "还有更多模型，可在 Runtime 模型菜单中选择。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    HStack {
                        sectionTitle(isEnglish ? "Available models" : "可用模型")
                        Spacer()
                        Text("\(coordinator.snapshot.models.count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            )
        } else if !coordinator.isBusy {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(isEnglish ? "Available models" : "可用模型")
                Text(
                    isEnglish
                        ? "Sign in or configure a provider to load its available models."
                        : "登录或配置 Provider 后，这里会显示可用模型。"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                Button(isEnglish ? "Refresh status" : "刷新状态") {
                    coordinator.refreshStatus()
                }
                .controlSize(.small)
            }
        }
    }

    private var storageNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text(
                    isEnglish
                        ? "Pi stores credentials in its official auth storage (\(coordinator.authStorageDisplayPath)) with user-only permissions. PuraPi never puts tokens or API keys in Session JSONL, project files, logs, or its own preferences."
                        : "Pi 会将凭据保存在官方认证存储中（\(coordinator.authStorageDisplayPath)），并使用仅用户可读写的权限。PuraPi 不会把令牌或 API Key 写入 Session JSONL、项目文件、日志或 PuraPi 偏好。"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(isEnglish ? "Check credentials" : "检查认证") {
                    coordinator.validateCredentials()
                }
                .controlSize(.small)
                .disabled(coordinator.isBusy)
                Button(isEnglish ? "Refresh models" : "刷新模型目录") {
                    coordinator.refreshAvailableModels()
                }
                .controlSize(.small)
                .disabled(coordinator.isBusy)
                Button(isEnglish ? "Refresh status" : "刷新认证状态") {
                    coordinator.refreshStatus()
                }
                .controlSize(.small)
                .disabled(coordinator.isBusy)
            }
        }
    }

    private func beginLogin(provider: PuraPiAuthProvider, type: PuraPiAuthType) {
        guard !coordinator.isBusy else { return }
        if provider.isConfigured {
            loginProviderID = provider.id
            loginType = type
            showingLoginConfirmation = true
        } else {
            coordinator.login(providerID: provider.id, type: type)
        }
    }

    private var phaseTitle: String {
        switch coordinator.phase {
        case .loggingIn(let providerID, let type):
            let name = coordinator.snapshot.provider(id: providerID)?.name ?? providerID
            return isEnglish ? "Signing in to \(name) (\(type.shortTitle))…" : "正在登录 \(name)（\(type.shortTitle)）…"
        case .loggingOut(let providerID):
            let name = coordinator.snapshot.provider(id: providerID)?.name ?? providerID
            return isEnglish ? "Signing out of \(name)…" : "正在退出 \(name)…"
        case .checking:
            return isEnglish ? "Reading Pi authentication status…" : "正在读取 Pi 认证状态…"
        case .refreshing:
            return isEnglish ? "Refreshing available models…" : "正在刷新可用模型…"
        case .idle, .failed:
            return ""
        }
    }

    private var messageIsError: Bool {
        if case .failed = coordinator.phase { return true }
        return false
    }

    private var themeSurface: Color { Color.primary.opacity(0.06) }

    private var emptyProviderText: some View {
        Text(isEnglish ? "No Pi authentication providers were found." : "没有找到可用的 Pi 认证 Provider。")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
    }
}

@MainActor
private struct PuraPiAuthProviderCard: View {
    @Environment(\.puraPiTheme) private var theme
    let provider: PuraPiAuthProvider
    let language: PuraPiInterfaceLanguage
    var compact = false
    let isDisabled: Bool
    let onLogin: (PuraPiAuthType) -> Void
    let onLogout: () -> Void

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: provider.isConfigured ? "checkmark.seal.fill" : "person.crop.circle")
                    .foregroundStyle(provider.isConfigured ? theme.success : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedProviderName)
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                    Text(provider.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let status = provider.status, status.configured {
                    Text(status.sourceLabel(language: language) ?? (isEnglish ? "Configured" : "已配置"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.success)
                        .lineLimit(1)
                } else {
                    Text(isEnglish ? "Not configured" : "未配置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(provider.authTypes) { method in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(methodTitle(method))
                            .font(.system(size: 11.5))
                        Text(method.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if provider.configuredType == method.type && provider.hasStoredCredential {
                        HStack(spacing: 6) {
                            Button(method.type == .oauth
                                ? (isEnglish ? "Sign In Again" : "重新登录")
                                : (isEnglish ? "Replace" : "替换")) {
                                onLogin(method.type)
                            }
                            .controlSize(.small)
                            .disabled(isDisabled)
                            Button(isEnglish ? "Sign Out" : "退出") {
                                onLogout()
                            }
                            .controlSize(.small)
                            .disabled(isDisabled)
                        }
                    } else if method.canLogin {
                        Button(method.type == .oauth
                            ? (isEnglish ? "Sign In" : "登录")
                            : (isEnglish ? "Configure" : "配置")) {
                            onLogin(method.type)
                        }
                        .controlSize(.small)
                        .disabled(isDisabled)
                    } else {
                        Text(isEnglish ? "Configured outside Pi" : "由外部环境配置")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(compact ? 10 : 12)
        .background(
            Color.primary.opacity(provider.isConfigured ? 0.075 : 0.045),
            in: RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localizedProviderName)
    }

    private var localizedProviderName: String {
        switch provider.id {
        case "openai-codex":
            return isEnglish ? "ChatGPT Plus / Pro (Codex)" : "ChatGPT Plus / Pro（Codex）"
        case "openai":
            return isEnglish ? "OpenAI API" : "OpenAI API"
        case "anthropic":
            return isEnglish ? "Anthropic / Claude" : "Anthropic / Claude"
        default:
            return provider.name
        }
    }

    private func methodTitle(_ method: PuraPiAuthMethod) -> String {
        if method.type == .oauth {
            if provider.id == "anthropic" {
                return isEnglish ? "Claude Pro / Max subscription" : "Claude Pro / Max 订阅"
            }
            if provider.id == "openai-codex" {
                return isEnglish ? "ChatGPT subscription" : "ChatGPT 订阅"
            }
            return method.loginLabel ?? method.type.title(language: language)
        }
        return isEnglish ? "API key" : "API Key"
    }
}

@MainActor
private struct PuraPiAuthEventView: View {
    @Environment(\.puraPiTheme) private var theme
    let event: PuraPiAuthEvent
    let language: PuraPiInterfaceLanguage

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: event.isAuthURL || event.isDeviceCode ? "safari" : "ellipsis.circle")
                    .foregroundStyle(theme.info)
                Text(eventTitle)
                    .font(.system(size: 11.5, weight: .medium))
            }
            if let message = event.message {
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let instructions = event.instructions {
                Text(instructions)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let code = event.userCode {
                Text(code)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let url = event.url ?? event.verificationUri {
                Link(
                    isEnglish ? "Open authentication page" : "打开认证页面",
                    destination: url
                )
                .font(.system(size: 11))
            }
            ForEach(event.links) { link in
                Link(
                    link.label ?? link.url.absoluteString,
                    destination: link.url
                )
                .font(.system(size: 10.5))
            }
        }
        .padding(10)
        .background(theme.info.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    private var eventTitle: String {
        if event.isAuthURL { return isEnglish ? "Browser authentication" : "浏览器认证" }
        if event.isDeviceCode { return isEnglish ? "Device code authentication" : "设备码认证" }
        return isEnglish ? "Authentication progress" : "认证进度"
    }
}

@MainActor
private struct PuraPiAuthPromptSheet: View {
    @ObservedObject var coordinator: PuraPiAuthCoordinator
    let prompt: PuraPiAuthPrompt
    let language: PuraPiInterfaceLanguage
    @State private var value = ""
    @State private var selectedOption: String?

    private var isEnglish: Bool { language == .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEnglish ? "Pi authentication" : "Pi 认证")
                .font(.system(size: 17, weight: .semibold))
            Text(prompt.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            if prompt.kind == .select {
                Picker(isEnglish ? "Method" : "方式", selection: Binding(
                    get: { selectedOption ?? prompt.options.first?.id ?? "" },
                    set: { selectedOption = $0 }
                )) {
                    ForEach(prompt.options) { option in
                        VStack(alignment: .leading) {
                            Text(option.label)
                            if let description = option.description {
                                Text(description).foregroundStyle(.secondary)
                            }
                        }
                        .tag(option.id)
                    }
                }
                .pickerStyle(.radioGroup)
            } else if prompt.kind == .secret {
                SecureField(
                    prompt.placeholder ?? (isEnglish ? "API key" : "API Key"),
                    text: $value
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            } else {
                TextField(
                    prompt.placeholder ?? (isEnglish ? "Enter value" : "输入内容"),
                    text: $value,
                    axis: prompt.kind == .manualCode ? .vertical : .horizontal
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(prompt.kind == .manualCode ? 3 : 1)
                .onSubmit(submit)
            }

            if let validation = coordinator.promptValidationMessage {
                Text(validation)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isEnglish ? "Cancel" : "取消", role: .cancel) {
                    value.removeAll()
                    coordinator.cancelPendingPrompt(for: prompt.id)
                }
                Button(isEnglish ? "Continue" : "继续") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.kind == .select && prompt.options.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            selectedOption = prompt.options.first?.id
        }
    }

    private func submit() {
        if prompt.kind == .select {
            coordinator.submitPrompt(
                selectedOption ?? prompt.options.first?.id ?? "",
                for: prompt.id
            )
        } else {
            let submittedValue = value
            value.removeAll()
            coordinator.submitPrompt(submittedValue, for: prompt.id)
        }
    }
}
