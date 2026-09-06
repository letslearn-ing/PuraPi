import Foundation
import PiRPC
import SwiftUI

/// 一个项目标签。标签的生命周期与一个文件夹及其 Pi Runtime 一一对应。
@MainActor
final class WorkPiProjectTab: ObservableObject, Identifiable {
    let id = UUID()
    let rootURL: URL
    let session: PiSessionController

    init(
        rootURL: URL,
        makeTransport: @escaping PiTransportFactory = { mode in
            makeDefaultPiTransport(for: mode)
        }
    ) {
        self.rootURL = WorkspaceDescriptor(rootURL: rootURL).rootURL
        self.session = PiSessionController(makeTransport: makeTransport)
        self.session.openWorkspace(self.rootURL)
    }

    convenience init(
        rootURL: URL,
        makeTransport: @escaping @Sendable () -> any PiRPCTransport
    ) {
        self.init(rootURL: rootURL, makeTransport: { _ in makeTransport() })
    }

    var title: String {
        rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
    }

    var isWorking: Bool {
        if session.runSettlementPending
            || session.runtimeSettlementQuarantined
            || session.sessionRebuildInFlight
            || session.sessionOperationInFlight {
            return true
        }
        switch session.phase {
        case .preparing, .requesting, .streaming, .executingTool, .settling, .cancelled:
            return true
        default:
            return false
        }
    }

    var recentSessionRestoreState: PiRecentSessionRestoreState {
        session.recentSessionRestoreState
    }

    var hasError: Bool {
        session.lastError != nil
            || session.runtimeNotice != nil
            || session.runtimeProvisioningRequired
            || (session.phase == .failed && session.runOutcome != .cancelled)
    }

    @discardableResult
    func close() -> Bool {
        session.closeWorkspace()
    }

    @discardableResult
    func closeAsync() async -> Bool {
        guard await session.closeWorkspaceAsync() else { return false }
        await session.waitForRuntimeStop()
        return true
    }
}

/// 管理项目标签，不把多个工作区状态揉进一个 Session。
@MainActor
final class WorkPiTabManager: ObservableObject {
    @Published private(set) var tabs: [WorkPiProjectTab] = []
    @Published private(set) var selectedTabID: UUID?

    private let makeTransport: PiTransportFactory
    private var closingTabIDs: Set<UUID> = []
    private var closingTasks: [UUID: Task<Bool, Never>] = [:]
    init(makeTransport: @escaping PiTransportFactory = { mode in
        makeDefaultPiTransport(for: mode)
    }) {
        self.makeTransport = makeTransport
    }

    convenience init(makeTransport: @escaping @Sendable () -> any PiRPCTransport) {
        self.init(makeTransport: { _ in makeTransport() })
    }

    var selectedTab: WorkPiProjectTab? {
        guard let selectedTabID else { return nil }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    func openProject(at url: URL) {
        let normalized = WorkspaceDescriptor(rootURL: url).rootURL
        if let existing = tabs.first(where: { $0.rootURL == normalized }) {
            selectedTabID = existing.id
            return
        }

        let tab = WorkPiProjectTab(rootURL: normalized, makeTransport: makeTransport)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func continueRecentSession(for tab: WorkPiProjectTab? = nil) {
        let target = tab ?? selectedTab
        target?.session.continueRecentSession()
    }

    /// 安装器完成后重新尝试因“找不到可执行文件”而失败的标签。
    func retryRuntimesWaitingForProvisioning() {
        for tab in tabs where tab.session.runtimeProvisioningRequired {
            tab.session.retryAfterRuntimeProvisioning()
        }
    }

    /// Pi 官方 auth.json 改变后，通知每个活动标签在安全的空闲时机重连。
    /// 不在运行中的 Agent 上强制重启，也不触碰草稿/队列。
    func markRuntimeAuthenticationChanged() {
        for tab in tabs {
            tab.session.markRuntimeAuthenticationChanged()
        }
    }

    func select(_ tab: WorkPiProjectTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        selectedTabID = tab.id
    }

    func close(_ tab: WorkPiProjectTab) {
        guard tabs.contains(where: { $0.id == tab.id }),
              !closingTabIDs.contains(tab.id)
        else { return }

        // 只要可能需要保存，就把关闭动作放到异步闸门；干净且没有待同步
        // Markdown 的标签仍走快速路径，不必创建无意义的 Task。
        if tab.session.markdownEditor.document?.isDirty == true
            || tab.session.hasPendingMarkdownCollaborationChanges {
            closingTabIDs.insert(tab.id)
            let task = Task { @MainActor [weak self, tab] in
                guard let self else { return false }
                defer {
                    self.closingTabIDs.remove(tab.id)
                    self.closingTasks.removeValue(forKey: tab.id)
                }
                return await self.performCloseAsync(tab)
            }
            closingTasks[tab.id] = task
            return
        }
        closeSynchronously(tab)
    }

    private func closeSynchronously(_ tab: WorkPiProjectTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasSelected = selectedTabID == tab.id
        // 文档冲突或保存失败时保留标签，避免关闭动作把编辑器状态一起丢掉；
        // 如果关闭的是非当前标签，先切过去让用户能看到冲突条。
        guard tab.close() else {
            selectedTabID = tab.id
            return
        }
        tabs.remove(at: index)
        updateSelectionAfterRemoval(index: index, wasSelected: wasSelected)
    }

    @discardableResult
    func closeAsync(_ tab: WorkPiProjectTab) async -> Bool {
        if let task = closingTasks[tab.id] {
            return await task.value
        }
        return await performCloseAsync(tab)
    }

    private func performCloseAsync(_ tab: WorkPiProjectTab) async -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        let wasSelected = selectedTabID == tab.id
        guard await tab.closeAsync() else {
            selectedTabID = tab.id
            return false
        }
        tabs.remove(at: index)
        updateSelectionAfterRemoval(index: index, wasSelected: wasSelected)
        return true
    }

    private func updateSelectionAfterRemoval(index: Int, wasSelected: Bool) {
        guard wasSelected else { return }
        if tabs.isEmpty {
            selectedTabID = nil
        } else {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelected() {
        guard let selectedTab else { return }
        close(selectedTab)
    }

    @discardableResult
    func closeAll() -> Bool {
        var closedIDs = Set<UUID>()
        var firstBlockedTabID: UUID?
        for tab in tabs {
            if tab.close() {
                closedIDs.insert(tab.id)
            } else if firstBlockedTabID == nil {
                firstBlockedTabID = tab.id
            }
        }
        tabs.removeAll { closedIDs.contains($0.id) }
        if let firstBlockedTabID,
           tabs.contains(where: { $0.id == firstBlockedTabID }) {
            selectedTabID = firstBlockedTabID
            return false
        }
        selectedTabID = tabs.first?.id
        return tabs.isEmpty
    }

    /// 退出应用时逐个等待异步 Markdown 保存和 Runtime stop 屏障。
    @discardableResult
    func closeAllAsync() async -> Bool {
        var closedIDs = Set<UUID>()
        var firstBlockedTabID: UUID?
        for tab in tabs {
            if await closeAsync(tab) {
                closedIDs.insert(tab.id)
            } else if firstBlockedTabID == nil {
                firstBlockedTabID = tab.id
            }
        }
        tabs.removeAll { closedIDs.contains($0.id) }
        if let firstBlockedTabID,
           tabs.contains(where: { $0.id == firstBlockedTabID }) {
            selectedTabID = firstBlockedTabID
            return false
        }
        selectedTabID = tabs.first?.id
        return tabs.isEmpty
    }
}
