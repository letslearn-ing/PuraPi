import AppKit
import Combine
import Foundation

/// Runtime 发现、安装和当前可执行文件选择的主线程状态桥。
///
/// 发现会自动执行，但安装永远只能由用户点击明确发起；安装器只写入
/// WorkPi 自己的用户级目录，不覆盖 PATH 中已有的 Pi，也不修改 Shell 配置。
@MainActor
final class WorkPiRuntimeProvisioner: ObservableObject {
    @Published private(set) var availability: WorkPiRuntimeAvailability = .checking
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var installPhase: WorkPiRuntimeInstallPhase?
    @Published private(set) var selectedExecutableURL: URL?
    @Published private(set) var discoveredNodeState: WorkPiRuntimeNodeState = .unknown
    @Published private(set) var isCancellingInstall = false

    let selection: WorkPiRuntimeSelection
    let locations: WorkPiRuntimeLocations
    private let defaults: UserDefaults
    private let client: any WorkPiRuntimeProvisioningClient
    private var discoveryTask: Task<Void, Never>?
    private var inspectTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var installTaskID: UUID?
    private var operationID = UUID()

    init(
        locations: WorkPiRuntimeLocations = WorkPiRuntimeLocations(),
        selection: WorkPiRuntimeSelection = WorkPiRuntimeSelection(),
        defaults: UserDefaults = WorkPiPreferences.shared,
        client: (any WorkPiRuntimeProvisioningClient)? = nil
    ) {
        self.locations = locations
        self.selection = selection
        self.defaults = defaults
        let preferredExecutableURL = defaults.string(forKey: WorkPiPreferences.Key.runtimeExecutablePath)
            .map { URL(fileURLWithPath: $0) }
        self.selectedExecutableURL = preferredExecutableURL
        self.client = client ?? WorkPiDefaultRuntimeProvisioningClient(
            locations: locations,
            preferredExecutableURL: preferredExecutableURL
        )
        refresh()
    }

    deinit {
        discoveryTask?.cancel()
        inspectTask?.cancel()
        installTask?.cancel()
    }

    var installation: WorkPiRuntimeInstallation? {
        availability.installation
    }

    var canInstall: Bool {
        guard !isCancellingInstall else { return false }
        switch availability {
        case .missing, .incompatible:
            return true
        case .failed(let error):
            if case .unsupportedPlatform = error { return false }
            return true
        case .checking, .available, .installing:
            return false
        }
    }

    var isInstalling: Bool {
        if case .installing = availability { return true }
        return false
    }

    var isInstallBusy: Bool {
        isInstalling || isCancellingInstall
    }

    var needsUserAction: Bool {
        switch availability {
        case .missing, .incompatible, .failed:
            return true
        case .checking, .available, .installing:
            return false
        }
    }

    var nodeState: WorkPiRuntimeNodeState {
        switch availability {
        case .missing(let node): return node
        case .available(let installation):
            if let nodeURL = installation.nodeURL {
                return .available(WorkPiRuntimeNodeInfo(
                    nodeURL: nodeURL,
                    npmURL: nil,
                    version: WorkPiRuntimePolicy.minimumNodeVersion
                ))
            }
            return discoveredNodeState
        case .incompatible, .checking, .installing, .failed:
            return discoveredNodeState
        }
    }

    /// 发现已有 Runtime。旧发现任务的结果不能覆盖较新的安装或刷新操作。
    func refresh() {
        guard installTask == nil else { return }
        discoveryTask?.cancel()
        inspectTask?.cancel()
        inspectTask = nil
        let id = UUID()
        operationID = id
        availability = .checking
        installPhase = nil
        diagnostics = []
        discoveryTask = Task { [weak self, client] in
            let snapshot = await client.discover()
            guard let self, self.operationID == id, !Task.isCancelled else { return }
            self.diagnostics = snapshot.diagnostics
            self.discoveredNodeState = snapshot.node
            if let installation = snapshot.installation {
                if installation.version >= WorkPiRuntimePolicy.minimumSupportedPiVersion {
                    self.selectedExecutableURL = installation.executableURL
                    self.availability = .available(installation)
                    self.selection.update(installation)
                } else {
                    self.selectedExecutableURL = installation.executableURL
                    self.availability = .incompatible(installation)
                    self.selection.update(nil, allowAutomaticResolution: false)
                }
            } else {
                self.availability = .missing(node: snapshot.node)
                self.selection.update(nil, allowAutomaticResolution: false)
            }
            self.discoveryTask = nil
        }
    }

    /// 用户手动选择一个不在常见 PATH 目录中的 `pi`；选择后先运行有界的
    /// `--version` 探测，只有验证成功才记住路径并作为 transport 入口。
    func chooseExecutable(language: WorkPiInterfaceLanguage = .chinese) {
        guard installTask == nil else { return }
        let panel = NSOpenPanel()
        let isEnglish = language == .english
        panel.title = isEnglish ? "Choose Pi executable" : "选择 Pi 可执行文件"
        panel.message = isEnglish
            ? "Choose an installed pi file. Pura Pi will only run --version to verify it."
            : "选择已安装的 pi 文件；Pura Pi 只会运行它的 --version 进行验证。"
        panel.prompt = isEnglish ? "Choose" : "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        discoveryTask?.cancel()
        inspectTask?.cancel()
        let id = UUID()
        operationID = id
        availability = .checking
        installPhase = nil
        diagnostics = []
        inspectTask = Task { [weak self, client] in
            do {
                let installation = try await client.inspect(executableURL: url)
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                self.selectedExecutableURL = installation.executableURL
                self.client.setPreferredExecutableURL(installation.executableURL)
                self.defaults.set(
                    installation.executableURL.path,
                    forKey: WorkPiPreferences.Key.runtimeExecutablePath
                )
                if installation.version >= WorkPiRuntimePolicy.minimumSupportedPiVersion {
                    self.availability = .available(installation)
                    self.selection.update(installation)
                } else {
                    self.availability = .incompatible(installation)
                    self.selection.update(nil, allowAutomaticResolution: false)
                }
                self.diagnostics = []
                self.inspectTask = nil
            } catch {
                guard let self, self.operationID == id else { return }
                self.availability = .failed(
                    .verificationFailed("无法验证所选 Pi：\(error.localizedDescription)")
                )
                self.inspectTask = nil
            }
        }
    }

    /// 用户明确确认后调用；不会在 Runtime 缺失时自动安装。
    func install() {
        guard installTask == nil, !isInstallBusy else { return }
        discoveryTask?.cancel()
        inspectTask?.cancel()
        inspectTask = nil
        let id = UUID()
        operationID = id
        installPhase = .preparing
        availability = .installing(.preparing)
        diagnostics = []
        installTaskID = id
        isCancellingInstall = false
        installTask = Task { [weak self, client] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishInstallTask(id: id)
                }
            }
            do {
                let progress = AsyncStream<WorkPiRuntimeInstallPhase>.makeStream()
                let progressGate = WorkPiRuntimeProgressGate()
                let progressTask = Task { @MainActor [weak self] in
                    for await phase in progress.stream {
                        guard progressGate.isActive(),
                              let self,
                              self.operationID == id
                        else { return }
                        self.installPhase = phase
                        self.availability = .installing(phase)
                    }
                }
                defer {
                    progressGate.deactivate()
                    progress.continuation.finish()
                    progressTask.cancel()
                }
                let installation = try await client.install { phase in
                    progress.continuation.yield(phase)
                }
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                progressGate.deactivate()
                self.selection.update(installation)
                self.selectedExecutableURL = installation.executableURL
                self.discoveredNodeState = installation.nodeURL.map {
                    .available(WorkPiRuntimeNodeInfo(
                        nodeURL: $0,
                        npmURL: nil,
                        version: WorkPiRuntimePolicy.minimumNodeVersion
                    ))
                } ?? self.discoveredNodeState
                self.installPhase = nil
                self.availability = .available(installation)
                self.diagnostics = ["Pi Runtime 已安装并通过版本验证。"]
            } catch {
                guard let self, self.operationID == id else { return }
                self.installPhase = nil
                if Task.isCancelled || (error as? WorkPiRuntimeProvisioningError) == .cancelled {
                    self.availability = .failed(.cancelled)
                } else if let provisioningError = error as? WorkPiRuntimeProvisioningError {
                    self.availability = .failed(provisioningError)
                } else {
                    self.availability = .failed(.commandFailed(
                        command: "Pi Runtime 安装",
                        detail: error.localizedDescription
                    ))
                }
                self.diagnostics = []
            }
        }
    }

    func cancelInstall() {
        guard isInstalling, installTask != nil else { return }
        operationID = UUID()
        isCancellingInstall = true
        installTask?.cancel()
        installPhase = nil
        availability = .failed(.cancelled)
    }

    private func finishInstallTask(id: UUID) {
        guard installTaskID == id else { return }
        installTaskID = nil
        installTask = nil
        isCancellingInstall = false
    }

    /// 应用真正退出时取消发现/探测/安装；关闭工作区被用户取消时不能调用，
    /// 否则会让用户失去恢复安装的机会。
    func shutdown() {
        operationID = UUID()
        discoveryTask?.cancel()
        inspectTask?.cancel()
        installTask?.cancel()
        discoveryTask = nil
        inspectTask = nil
        installPhase = nil
    }

    func openPiWebsite() {
        NSWorkspace.shared.open(WorkPiRuntimePolicy.piWebsiteURL)
    }

    func openNodeDownloadPage() {
        NSWorkspace.shared.open(WorkPiRuntimePolicy.nodeDownloadURL)
    }

    /// 只复制官方 npm 命令，不把它静默执行；适合用户希望在自己的终端审阅命令时使用。
    func copyOfficialInstallCommand() {
        let command = "npm install -g --ignore-scripts \(WorkPiRuntimePolicy.piPackageName)@\(WorkPiRuntimePolicy.managedPiVersion)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

private final class WorkPiRuntimeProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
