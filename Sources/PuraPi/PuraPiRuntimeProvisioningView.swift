import SwiftUI

private enum PuraPiRuntimeProvisioningPresentation {
    case compact
    case settings
}

/// Runtime 供应状态的可见入口。安装按钮只触发确认弹窗后的显式安装，不会在
/// View 出现时执行网络请求或 Shell；发现任务由 `PuraPiRuntimeProvisioner` 管理。
@MainActor
struct PuraPiRuntimeProvisioningView: View {
    @Environment(\.puraPiTheme) private var theme
    @ObservedObject var provisioner: PuraPiRuntimeProvisioner
    let language: PuraPiInterfaceLanguage
    private let presentation: PuraPiRuntimeProvisioningPresentation
    private let showsManualChoice: Bool
    @State private var isConfirmingInstall = false

    init(
        provisioner: PuraPiRuntimeProvisioner,
        language: PuraPiInterfaceLanguage,
        compact: Bool = false,
        showsManualChoice: Bool = false
    ) {
        self.provisioner = provisioner
        self.language = language
        presentation = compact ? .compact : .settings
        self.showsManualChoice = showsManualChoice
    }

    private var isEnglish: Bool { language == .english }

    var body: some View {
        Group {
            switch presentation {
            case .compact:
                compactBody
            case .settings:
                ScrollView {
                    settingsBody
                }
            }
        }
        .alert(
            isEnglish ? "Install Pi Runtime?" : "安装 Pi Runtime？",
            isPresented: $isConfirmingInstall
        ) {
            Button(isEnglish ? "Install" : "安装") {
                provisioner.install()
            }
            Button(isEnglish ? "Cancel" : "取消", role: .cancel) {}
        } message: {
            Text(
                isEnglish
                    ? "PuraPi will install the pinned Pi version in its user-level Application Support directory. If needed, it will also download and verify a private Node.js copy. It will not replace an existing Pi or edit your shell profile."
                    : "PuraPi 会把已验证版本安装到自己的用户级 Application Support 目录；必要时还会下载并校验私有 Node.js。不会覆盖已有 Pi，也不会修改 Shell 配置。"
            )
        }
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 12.5, weight: .medium))
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            actionButtons(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(size: 16, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            if let installation = provisioner.installation {
                VStack(alignment: .leading, spacing: 5) {
                    detailRow(
                        label: isEnglish ? "Version" : "版本",
                        value: installation.version.description
                    )
                    detailRow(
                        label: isEnglish ? "Executable" : "可执行文件",
                        value: installation.displayPath
                    )
                    detailRow(
                        label: isEnglish ? "Source" : "来源",
                        value: isEnglish
                            ? (installation.source == .existing ? "Existing installation" : "Managed by PuraPi")
                            : installation.source.title
                    )
                }
                .textSelection(.enabled)
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if provisioner.isInstallBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if provisioner.isCancellingInstall {
                        Text(isEnglish ? "Stopping installation…" : "正在取消安装…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if let phase = provisioner.installPhase {
                        Text(isEnglish ? phaseEnglishTitle(phase) : phase.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !provisioner.isCancellingInstall {
                        Button(isEnglish ? "Cancel" : "取消") {
                            provisioner.cancelInstall()
                        }
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 8) {
                actionButtons(compact: false)
                Spacer()
            }

            if shouldShowNodeHelp {
                Text(
                    isEnglish
                        ? "If automatic Node.js setup is unavailable, install Node.js 22.19.0 or newer from nodejs.org, then check again."
                        : "如果自动准备 Node.js 失败，请从 nodejs.org 安装 Node.js 22.19.0 或更高版本，然后重新检查。"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button(isEnglish ? "Open Node.js downloads" : "打开 Node.js 下载页") {
                    provisioner.openNodeDownloadPage()
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }

            if case .failed(let error) = provisioner.availability {
                Text(error.localizedDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(compact: Bool) -> some View {
        if provisioner.isInstallBusy {
            EmptyView()
        } else if provisioner.availability.isAvailable {
            Button(isEnglish ? "Check again" : "重新检查") {
                provisioner.refresh()
            }
            .controlSize(compact ? .small : .regular)
            if !compact || showsManualChoice {
                Button(isEnglish ? "Choose pi…" : "选择 pi…") {
                    provisioner.chooseExecutable(language: language)
                }
                .controlSize(compact ? .small : .regular)
            }
        } else {
            Button(isEnglish ? "Install Pi Runtime" : "安装 Pi Runtime") {
                isConfirmingInstall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .disabled(!provisioner.canInstall)

            if !compact {
                Button(isEnglish ? "Check again" : "重新检查") {
                    provisioner.refresh()
                }
                .controlSize(.regular)
                Button(isEnglish ? "Copy official command" : "复制官方命令") {
                    provisioner.copyOfficialInstallCommand()
                }
                .controlSize(.regular)
            }
            if !compact || showsManualChoice {
                Button(isEnglish ? "Choose pi…" : "选择 pi…") {
                    provisioner.chooseExecutable(language: language)
                }
                .controlSize(compact ? .small : .regular)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch provisioner.availability {
            case .checking, .installing:
                ProgressView()
                    .controlSize(.small)
            case .available:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
            case .missing, .incompatible, .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var statusTitle: String {
        switch provisioner.availability {
        case .checking:
            return isEnglish ? "Checking Pi Runtime…" : "正在检查 Pi Runtime…"
        case .available(let installation):
            return isEnglish
                ? "Pi Runtime is ready (\(installation.version))"
                : "Pi Runtime 已就绪（\(installation.version)）"
        case .missing:
            return isEnglish ? "Pi Runtime not found" : "未找到 Pi Runtime"
        case .incompatible(let installation):
            return isEnglish
                ? "Pi Runtime needs an update (\(installation.version))"
                : "Pi Runtime 版本过低（\(installation.version)）"
        case .installing(let phase):
            return isEnglish ? phaseEnglishTitle(phase) : phase.title
        case .failed:
            return isEnglish ? "Pi Runtime setup failed" : "Pi Runtime 安装失败"
        }
    }

    private var statusSubtitle: String {
        switch provisioner.availability {
        case .checking:
            return isEnglish ? "Looking for an existing installation." : "正在查找用户已有的 Pi 安装。"
        case .available(let installation):
            return installation.displayPath
        case .missing(let node):
            return nodeSubtitle(node)
        case .incompatible:
            return isEnglish
                ? "PuraPi will leave the existing installation untouched and install a managed copy."
                : "PuraPi 不会覆盖已有安装，而会准备一份独立的用户级版本。"
        case .installing:
            return isEnglish ? "The existing Pi installation is not being modified." : "不会修改用户已有的 Pi 安装。"
        case .failed:
            return isEnglish ? "Retry after fixing the reported prerequisite or network issue." : "解决前置条件或网络问题后可以重试。"
        }
    }

    private var shouldShowNodeHelp: Bool {
        switch provisioner.availability {
        case .missing(let node):
            switch node {
            case .missing, .incompatible: return true
            case .unknown, .available: return false
            }
        case .failed(let error):
            switch error {
            case .nodeMissing, .npmMissing, .nodeTooOld, .unsupportedPlatform: return true
            default: return false
            }
        case .checking, .available, .incompatible, .installing:
            return false
        }
    }

    private func nodeSubtitle(_ node: PuraPiRuntimeNodeState) -> String {
        switch node {
        case .unknown:
            return isEnglish ? "Node.js status is not known yet." : "尚未取得 Node.js 状态。"
        case .missing:
            return isEnglish
                ? "Node.js 22.19.0+ will be prepared in PuraPi's user directory if needed."
                : "如果需要，PuraPi 会把 Node.js 22.19.0+ 准备到自己的用户目录。"
        case .incompatible(let info):
            return isEnglish
                ? "Found Node.js \(info.version); a newer private copy may be installed."
                : "检测到 Node.js \(info.version)；必要时会安装独立的新版本。"
        case .available(let info):
            return isEnglish ? "Node.js \(info.version) and npm are available." : "Node.js \(info.version) 与 npm 已就绪。"
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5))
    }

    private func phaseEnglishTitle(_ phase: PuraPiRuntimeInstallPhase) -> String {
        switch phase {
        case .preparing: return "Preparing installation…"
        case .installingNode: return "Installing Node.js…"
        case .installingPi: return "Installing Pi…"
        case .verifying: return "Verifying Runtime…"
        case .activating: return "Activating Runtime…"
        }
    }
}
