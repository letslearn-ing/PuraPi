import SwiftUI

/// 首次启动向导当前所处的阶段。它只组合 Runtime 供应和账号状态，
/// 不拥有安装器或认证凭据，避免向导关闭后留下第二份生命周期。
enum PuraPiFirstLaunchStep: Equatable {
    case checkingRuntime
    case runtimeSetup
    case checkingAuthentication
    case authenticationSetup
    case ready
}

enum PuraPiFirstLaunchStepResolver {
    static func resolve(
        runtime: PuraPiRuntimeAvailability,
        authenticationLoaded: Bool,
        authenticationPhase: PuraPiAuthPhase,
        authentication: PuraPiAuthSnapshot
    ) -> PuraPiFirstLaunchStep {
        switch runtime {
        case .checking, .installing:
            return .checkingRuntime
        case .missing, .incompatible, .failed:
            return .runtimeSetup
        case .available:
            switch authenticationPhase {
            case .checking, .refreshing, .loggingIn, .loggingOut:
                return .checkingAuthentication
            case .failed:
                return .authenticationSetup
            case .idle:
                guard authenticationLoaded else { return .checkingAuthentication }
                return authentication.configuredProviderCount > 0
                    ? .ready
                    : .authenticationSetup
            }
        }
    }
}

/// 将已有 Runtime、账号设置和项目入口串成一条可操作的首次启动路径。
/// 认证仍可稍后完成，向导不会阻止用户先打开项目查看文件。
@MainActor
struct PuraPiFirstLaunchWizard: View {
    @Environment(\.puraPiTheme) private var theme

    @ObservedObject var runtimeProvisioner: PuraPiRuntimeProvisioner
    @ObservedObject var authCoordinator: PuraPiAuthCoordinator
    let language: PuraPiInterfaceLanguage
    let onCreateProject: () -> Void
    let onOpenProject: () -> Void
    let onOpenAccountSettings: () -> Void

    private var isEnglish: Bool { language == .english }

    private var step: PuraPiFirstLaunchStep {
        PuraPiFirstLaunchStepResolver.resolve(
            runtime: runtimeProvisioner.availability,
            authenticationLoaded: authCoordinator.hasLoadedStatus,
            authenticationPhase: authCoordinator.phase,
            authentication: authCoordinator.snapshot
        )
    }

    var body: some View {
        ZStack {
            PuraPiAdaptiveContentBackground(legacyColor: theme.workspaceBackground)

            ScrollView {
                VStack(spacing: 18) {
                    PuraPiBrandLockup(markSize: 64)
                        .padding(.bottom, 2)

                    header
                    progress
                    stepContent
                    projectActions
                }
                .frame(maxWidth: 620)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshAuthenticationIfPossible()
        }
        .onChange(of: runtimeProvisioner.availability) { _, availability in
            guard availability.isAvailable else { return }
            refreshAuthenticationIfPossible()
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text(isEnglish ? "Set up PuraPi" : "开始使用 PuraPi")
                .font(.system(size: 22, weight: .semibold))
            Text(
                isEnglish
                    ? "PuraPi will check the local Runtime first, then help you configure an account before opening a project."
                    : "PuraPi 会先检查本机 Runtime，再帮助你配置账号，然后打开项目。"
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            progressItem(
                title: isEnglish ? "Runtime" : "运行时",
                active: [.checkingRuntime, .runtimeSetup].contains(step),
                complete: [.checkingAuthentication, .authenticationSetup, .ready].contains(step)
            )
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 28, height: 1)
            progressItem(
                title: isEnglish ? "Account" : "账号",
                active: [.checkingAuthentication, .authenticationSetup].contains(step),
                complete: step == .ready
            )
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 28, height: 1)
            progressItem(
                title: isEnglish ? "Project" : "项目",
                active: step == .ready,
                complete: false
            )
        }
        .font(.system(size: 11, weight: .medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isEnglish ? "First launch setup progress" : "首次启动设置进度")
    }

    private func progressItem(title: String, active: Bool, complete: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(active || complete ? theme.accent : .secondary.opacity(0.45))
            Text(title)
                .foregroundStyle(active || complete ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .checkingRuntime:
            setupCard(
                title: isEnglish ? "Checking Pi Runtime" : "正在检查 Pi Runtime",
                subtitle: isEnglish
                    ? "Looking for a compatible Pi installation on this Mac."
                    : "正在查找这台 Mac 上可复用的 Pi 安装。",
                systemImage: "magnifyingglass"
            ) {
                PuraPiRuntimeProvisioningView(
                    provisioner: runtimeProvisioner,
                    language: language,
                    compact: true
                )
            }
        case .runtimeSetup:
            setupCard(
                title: isEnglish ? "Prepare Pi Runtime" : "准备 Pi Runtime",
                subtitle: isEnglish
                    ? "Use an existing installation, choose one manually, or install a private verified copy."
                    : "可以复用已有安装、手动选择 Pi，或安装一份经过验证的用户级副本。",
                systemImage: "shippingbox"
            ) {
                PuraPiRuntimeProvisioningView(
                    provisioner: runtimeProvisioner,
                    language: language,
                    compact: true,
                    showsManualChoice: true
                )
            }
        case .checkingAuthentication:
            setupCard(
                title: isEnglish ? "Checking account setup" : "正在检查账号配置",
                subtitle: isEnglish
                    ? "Reading non-sensitive authentication status through Pi's official runtime."
                    : "正在通过 Pi 官方运行时读取非敏感认证状态。",
                systemImage: "person.badge.key"
            ) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isEnglish ? "Checking…" : "正在检查…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case .authenticationSetup:
            setupCard(
                title: isEnglish ? "Configure an account" : "配置账号",
                subtitle: authenticationSubtitle,
                systemImage: "person.badge.key"
            ) {
                HStack(spacing: 8) {
                    Button(isEnglish ? "Open account settings" : "打开账号设置") {
                        onOpenAccountSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(isEnglish ? "Check again" : "重新检查") {
                        authCoordinator.refreshStatus()
                    }
                    .controlSize(.regular)
                }
            }
        case .ready:
            setupCard(
                title: isEnglish ? "Everything is ready" : "准备完成",
                subtitle: isEnglish
                    ? "Runtime and account setup are ready. Open a project to start using Pi."
                    : "Runtime 和账号已经准备好。打开项目即可开始使用 Pi。",
                systemImage: "checkmark.circle.fill"
            ) {
                Label(
                    isEnglish
                        ? "Configured providers: \(authCoordinator.snapshot.configuredProviderCount)"
                        : "已配置 Provider：\(authCoordinator.snapshot.configuredProviderCount)",
                    systemImage: "checkmark"
                )
                .font(.system(size: 12))
                .foregroundStyle(theme.success)
            }
        }
    }

    private var authenticationSubtitle: String {
        if case .failed(let message) = authCoordinator.phase {
            return isEnglish
                ? "The account check needs attention: \(message)"
                : "账号检查需要处理：\(message)"
        }
        return isEnglish
            ? "Sign in with a subscription or configure an API key. Credentials stay in Pi's official secure storage."
            : "登录订阅账号或配置 API Key。凭据只会保存在 Pi 官方安全存储中。"
    }

    private var projectActions: some View {
        PuraPiGlassContainer(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    PuraPiEmptyActionButton(
                        title: isEnglish ? "Create project folder" : "新建项目文件夹",
                        systemImage: "folder.badge.plus",
                        prominent: step == .ready,
                        action: onCreateProject
                    )
                    PuraPiEmptyActionButton(
                        title: isEnglish ? "Open project folder" : "打开项目文件夹",
                        systemImage: "folder",
                        prominent: false,
                        action: onOpenProject
                    )
                }

                if step != .ready {
                    Button(isEnglish ? "Open a project first" : "先打开项目，稍后配置") {
                        onOpenProject()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
            }
        }
    }

    private func setupCard<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.accent.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.18), lineWidth: 0.5)
        }
    }

    private func refreshAuthenticationIfPossible() {
        guard runtimeProvisioner.availability.isAvailable,
              !authCoordinator.hasLoadedStatus,
              !authCoordinator.isBusy
        else { return }
        authCoordinator.refreshStatus()
    }
}
