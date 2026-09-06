import Foundation
import PiDomain
import WorkspaceKit

/// 目录树、预览与 FSEvents（文件系统事件）同步。
/// 这里不处理 Pi RPC；磁盘始终是工作区状态的事实源。
extension PiSessionController {
    func openWorkspace(_ url: URL) {
        let normalizedURL = WorkspaceDescriptor(rootURL: url).rootURL
        if markdownEditor.document?.isDirty == true
            || hasPendingMarkdownCollaborationChanges {
            // 有脏文档时不能在主线程同步保存；把项目切换排到同一异步闸门。
            enqueueMarkdownTransition { [weak self] in
                guard let self,
                      await self.closeWorkspaceAsync()
                else { return }
                self.openWorkspace(normalizedURL)
            }
            return
        }
        // 关闭失败通常意味着当前 Markdown 存在未解决冲突；保持旧工作区，
        // 不能在此处继续打开新项目并覆盖编辑器状态。
        guard closeWorkspace() else { return }
        let requiresAuthorization = PuraPiProjectAuthorization.requiresAuthorization(for: normalizedURL)
        if requiresAuthorization {
            projectAuthorizationState = PuraPiProjectAuthorization.isRemembered(for: normalizedURL)
                ? .approved
                : .needsDecision
        } else {
            projectAuthorizationState = .notRequired
        }
        runtimeStatus = projectAuthorizationState == .needsDecision
            ? "等待项目授权…"
            : "正在读取项目…"
        lastError = nil
        runtimeNotice = nil
        runtimeProvisioningRequired = false
        workspace = WorkspaceDescriptor(rootURL: normalizedURL)
        let loadGeneration = UUID()
        generation = loadGeneration
        idlessResponseQuarantine.removeAll()
        retiredRuntimeRequestIDs.removeAll()
        ambiguousRuntimeRequestIDs.removeAll()
        runtimeRequestSessionEpochs.removeAll()

        let services = self.services
        workspaceLoadTask = Task { [weak self] in
            do {
                let tree = try await Task.detached(priority: .utility) {
                    try services.loadTreeRoot(rootURL: normalizedURL)
                }.value
                guard let self, self.generation == loadGeneration else { return }
                self.fileTree = tree
                self.startFileMonitor(for: normalizedURL, generation: loadGeneration)

                let launchMode: PiRuntimeLaunchMode?
                switch self.projectAuthorizationState {
                case .notRequired:
                    launchMode = .fresh
                case .approved:
                    launchMode = .freshApproved
                case .needsDecision, .denied:
                    launchMode = nil
                }
                if let launchMode {
                    self.runtimeStatus = "正在启动 Pi Runtime…"
                    self.startRuntime(
                        for: normalizedURL,
                        generation: loadGeneration,
                        launchMode: launchMode
                    )
                }
            } catch {
                guard let self, self.generation == loadGeneration else { return }
                self.fileTree = nil
                self.phase = .failed
                self.runtimeStatus = "项目读取失败"
                self.lastError = PuraPiSensitiveText.redacted(error.localizedDescription)
            }
        }
    }

    func toggleDirectory(_ url: URL, _ shouldExpand: Bool) {
        guard shouldExpand,
              let workspace,
              let root = fileTree,
              let node = findNode(url: url, in: root),
              node.isDirectory
        else { return }

        // 已经读取过的目录不重复访问磁盘；FSEvents 刷新会替换其快照。
        if node.childrenLoaded { return }
        guard pendingDirectoryLoads.insert(url.standardizedFileURL).inserted else { return }

        let services = self.services
        let generation = self.generation
        Task { [weak self] in
            defer { self?.pendingDirectoryLoads.remove(url.standardizedFileURL) }
            do {
                let children = try await Task.detached(priority: .utility) {
                    try services.loadDirectoryChildren(directoryURL: url, rootURL: workspace.rootURL)
                }.value
                guard let self, self.generation == generation,
                      let currentRoot = self.fileTree,
                      let currentNode = self.findNode(url: url, in: currentRoot)
                else { return }
                self.fileTree = self.replacingNode(
                    in: currentRoot,
                    targetURL: url.standardizedFileURL,
                    with: FileNode(
                        url: currentNode.url,
                        name: currentNode.name,
                        kind: currentNode.kind,
                        children: children,
                        childrenLoaded: true
                    )
                )
            } catch {
                // 展开失败不破坏已有树；再次点击可以重试。
            }
        }
    }

    /// 将需要等待磁盘保存的文件切换串行化。新的点击不会打断正在进行的保存，
    /// 但会让旧的“打开目标”意图失效；旧文件的快照仍会留在账本中。
    func enqueueMarkdownTransition(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previous = markdownTransitionTask
        let requestID = UUID()
        markdownTransitionRequestID = requestID
        let task = Task { @MainActor [weak self, previous] in
            await previous?.value
            guard let self,
                  self.markdownTransitionRequestID == requestID
            else { return }
            await operation()
            if self.markdownTransitionRequestID == requestID {
                self.markdownTransitionTask = nil
            }
        }
        markdownTransitionTask = task
    }

    private func leaveCurrentMarkdownForTransition() async -> Bool {
        guard markdownEditor.isEditing else {
            resetMarkdownReviewUI()
            return true
        }
        // 先显式等待保存，关闭动作本身不再同步触碰磁盘。
        if markdownEditor.document?.isDirty == true,
           !(await markdownEditor.save()) {
            handleMarkdownCloseFailure()
            return false
        }
        captureCurrentMarkdownCollaboration()
        guard await markdownEditor.close(preservingPendingCollaboration: true) else {
            handleMarkdownCloseFailure()
            return false
        }
        resetMarkdownReviewUI()
        return true
    }

    func clearFileSelection() {
        if markdownEditor.document?.isDirty != true, markdownTransitionTask == nil {
            captureCurrentMarkdownCollaboration()
            guard markdownEditor.close(preservingPendingCollaboration: true) else {
                handleMarkdownCloseFailure()
                return
            }
            resetMarkdownReviewUI()
            markdownCollaborationCloseBlocked = false
            previewTask?.cancel()
            previewTask = nil
            previewRequestID = UUID()
            selectedFileURL = nil
            selectedPreview = nil
            previewError = nil
            hideInspectorLiftHint()
            reattachInspector()
            return
        }
        enqueueMarkdownTransition { [weak self] in
            guard let self else { return }
            guard await self.leaveCurrentMarkdownForTransition() else { return }
            self.markdownCollaborationCloseBlocked = false
            self.previewTask?.cancel()
            self.previewTask = nil
            self.previewRequestID = UUID()
            self.selectedFileURL = nil
            self.selectedPreview = nil
            self.previewError = nil
            // 关闭文件也结束其 Inspector 展示位置；窗口协调器会据此关闭独立窗口，
            // 而不是留下一个没有文档的浮动壳。
            self.hideInspectorLiftHint()
            self.reattachInspector()
        }
    }

    private func selectFileImmediately(_ url: URL) {
        guard let workspace else { return }
        let selectedURL = url.standardizedFileURL
        let isMarkdown = PuraPiMarkdownEditorState.canEdit(selectedURL)
        let isCurrentMarkdown = isMarkdown
            && markdownEditor.isEditing
            && markdownEditor.document?.url.standardizedFileURL == selectedURL
        if !isCurrentMarkdown {
            captureCurrentMarkdownCollaboration()
            guard markdownEditor.close(preservingPendingCollaboration: true) else {
                handleMarkdownCloseFailure()
                return
            }
            resetMarkdownReviewUI()
        }
        if isMarkdown, !isCurrentMarkdown {
            guard markdownEditor.open(url: selectedURL, workspaceRoot: workspace.rootURL) else { return }
            if let snapshot = pendingMarkdownSnapshots[selectedURL] {
                _ = markdownEditor.restorePendingCollaborationSnapshot(snapshot)
            }
        }
        selectedFileURL = selectedURL
        selectedPreview = nil
        previewError = nil
        loadPreview(for: selectedURL, workspaceRoot: workspace.rootURL)
    }

    func selectFile(_ url: URL) {
        if markdownEditor.document?.isDirty != true, markdownTransitionTask == nil {
            selectFileImmediately(url)
            return
        }
        enqueueMarkdownTransition { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            let selectedURL = url.standardizedFileURL
            let isMarkdown = PuraPiMarkdownEditorState.canEdit(selectedURL)
            let isCurrentMarkdown = isMarkdown
                && self.markdownEditor.isEditing
                && self.markdownEditor.document?.url.standardizedFileURL == selectedURL

            if !isCurrentMarkdown {
                guard await self.leaveCurrentMarkdownForTransition() else { return }
            }

            if isMarkdown, !isCurrentMarkdown {
                guard await self.markdownEditor.open(
                    url: selectedURL,
                    workspaceRoot: workspace.rootURL
                ) else { return }
                if let snapshot = self.pendingMarkdownSnapshots[selectedURL] {
                    // 只有磁盘仍是保存后的当前文本时才能恢复旧协作基线；否则
                    // 保留当前编辑器并让外部修改冲突流程接管。
                    _ = self.markdownEditor.restorePendingCollaborationSnapshot(snapshot)
                }
            }

            self.selectedFileURL = selectedURL
            self.selectedPreview = nil
            self.previewError = nil
            self.loadPreview(for: selectedURL, workspaceRoot: workspace.rootURL)
        }
    }

    func retryFilePreview() {
        guard let selectedFileURL, let workspace else { return }
        let isMarkdown = PuraPiMarkdownEditorState.canEdit(selectedFileURL)
        // 首次 Markdown 读取失败时，旧实现只重试了只读预览，导致文件修复后
        // 仍停留在预览错误页。这里先重新打开编辑器，再刷新共享预览任务；
        // 已在编辑的文档不能重复 open，否则会丢失本地状态。
        if isMarkdown, !markdownEditor.isEditing {
            guard markdownEditor.open(
                url: selectedFileURL,
                workspaceRoot: workspace.rootURL
            ) else { return }
        }
        selectedPreview = nil
        previewError = nil
        loadPreview(for: selectedFileURL, workspaceRoot: workspace.rootURL)
    }

    private func loadPreview(for url: URL, workspaceRoot: URL) {
        previewTask?.cancel()
        let services = self.services
        let generation = self.generation
        let requestID = UUID()
        previewRequestID = requestID
        previewTask = Task { [weak self] in
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try services.preview(fileURL: url, rootURL: workspaceRoot)
                }.value
                guard let self,
                      self.generation == generation,
                      self.previewRequestID == requestID,
                      self.selectedFileURL?.standardizedFileURL == url.standardizedFileURL
                else { return }
                self.selectedPreview = preview
                self.previewError = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.generation == generation,
                      self.previewRequestID == requestID,
                      self.selectedFileURL?.standardizedFileURL == url.standardizedFileURL
                else { return }
                self.selectedPreview = nil
                self.previewError = error.localizedDescription
            }
        }
    }

    func startFileMonitor(for workspaceURL: URL, generation: UUID) {
        let newMonitor = FSEventsWorkspaceFileMonitor(rootURL: workspaceURL)
        monitor = newMonitor
        let stream = newMonitor.start()
        monitorTask = Task { [weak self] in
            for await change in stream {
                guard !Task.isCancelled else { break }
                self?.consume(change, generation: generation)
            }
        }
    }

    func consume(_ change: WorkspaceFileChange, generation: UUID) {
        guard self.generation == generation else { return }
        let changedURL = change.url.standardizedFileURL
        if let selectedFileURL,
           selectedFileURL.standardizedFileURL == changedURL,
           let workspace {
            // Markdown 的脏文档必须走冲突处理；只读文件则只重载预览，不能通过
            // selectFile 间接关闭并重开当前编辑器。
            if markdownEditor.isEditing,
               markdownEditor.document?.url.standardizedFileURL == selectedFileURL.standardizedFileURL {
                markdownEditor.handleExternalChange(at: selectedFileURL)
            }
            // 同一批写入可能产生多个 FSEvents；预览任务自身会取消旧读取，
            // 这里不重新扫描整个树。
            loadPreview(for: selectedFileURL, workspaceRoot: workspace.rootURL)
        }
        if let workspace,
           changedURL.path == workspace.rootURL.path
            || changedURL.path.hasPrefix(workspace.rootURL.path + "/"),
           change.kind != .modified {
            let parentURL = changedURL == workspace.rootURL
                ? workspace.rootURL
                : changedURL.deletingLastPathComponent().standardizedFileURL
            scheduleTreeRefresh(
                rootURL: workspace.rootURL,
                changedDirectoryURL: parentURL,
                generation: generation
            )
        }
    }

    func scheduleTreeRefresh(
        rootURL: URL,
        changedDirectoryURL: URL,
        generation: UUID
    ) {
        pendingTreeRefreshDirectories.insert(changedDirectoryURL.standardizedFileURL)
        guard treeRefreshTask == nil else { return }
        let services = self.services
        treeRefreshTask = Task { @MainActor [weak self] in
            defer { self?.treeRefreshTask = nil }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(180))
                    guard let self, self.generation == generation else { return }
                    let directories = self.pendingTreeRefreshDirectories
                    self.pendingTreeRefreshDirectories.removeAll()
                    guard !directories.isEmpty else { return }

                    for changedDirectoryURL in directories {
                        guard !Task.isCancelled,
                              self.generation == generation,
                              let currentRoot = self.fileTree,
                              let directory = self.findNode(url: changedDirectoryURL, in: currentRoot),
                              directory.isDirectory,
                              directory.childrenLoaded
                        else { continue }

                        let shallowChildren = try await Task.detached(priority: .utility) {
                            try services.loadDirectoryChildren(
                                directoryURL: directory.url,
                                rootURL: rootURL
                            )
                        }.value
                        guard !Task.isCancelled,
                              self.generation == generation,
                              let latestRoot = self.fileTree,
                              let latestDirectory = self.findNode(url: directory.url, in: latestRoot)
                        else { return }

                        let children = self.mergingLoadedChildren(
                            shallowChildren,
                            previousChildren: latestDirectory.children ?? []
                        )
                        self.fileTree = self.replacingNode(
                            in: latestRoot,
                            targetURL: directory.url,
                            with: FileNode(
                                url: latestDirectory.url,
                                name: latestDirectory.name,
                                kind: latestDirectory.kind,
                                children: children,
                                childrenLoaded: true
                            )
                        )
                    }
                }
            } catch {
                // 文件在通知和扫描之间消失时不覆盖现有树；下一批事件会重试。
            }
        }
    }

    func mergingLoadedChildren(
        _ shallowChildren: [FileNode],
        previousChildren: [FileNode]
    ) -> [FileNode] {
        let previousByURL = Dictionary(uniqueKeysWithValues: previousChildren.map { ($0.url, $0) })
        return shallowChildren.map { fresh in
            guard fresh.isDirectory,
                  let previous = previousByURL[fresh.url],
                  previous.childrenLoaded
            else { return fresh }
            return FileNode(
                url: fresh.url,
                name: fresh.name,
                kind: fresh.kind,
                children: previous.children,
                childrenLoaded: true
            )
        }
    }

    func findNode(url: URL, in node: FileNode) -> FileNode? {
        let target = url.standardizedFileURL
        if node.url == target { return node }
        guard node.isDirectory, let children = node.children else { return nil }
        for child in children {
            if let match = findNode(url: target, in: child) { return match }
        }
        return nil
    }

    func replacingNode(in node: FileNode, targetURL: URL, with replacement: FileNode) -> FileNode {
        if node.url == targetURL { return replacement }
        guard node.isDirectory, let children = node.children else { return node }
        let updatedChildren = children.map { child in
            replacingNode(in: child, targetURL: targetURL, with: replacement)
        }
        if updatedChildren == children { return node }
        return FileNode(
            url: node.url,
            name: node.name,
            kind: node.kind,
            children: updatedChildren,
            childrenLoaded: node.childrenLoaded
        )
    }

    func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.path }
        return String(url.path.dropFirst(rootPath.count))
    }
}
