import Foundation

/// Markdown 协作差异的状态机。
///
/// 每个文件都有自己的快照和确认状态。切换文件只取消当前正在显示的 diff
/// 计算，不取消该文件的协作记录；下一次 Prompt 可以一次附加多个文件。
enum WorkPiMarkdownSubmissionChange {
    case none
    case ready([WorkPiMarkdownDiffContext])
    case needsReview
}

private enum WorkPiMarkdownDiffTaskResult {
    case success(WorkPiMarkdownDiffContext)
    case failure(WorkPiMarkdownDiffBuildFailure)
    case cancelled
}

extension PiSessionController {
    func currentMarkdownSnapshot() -> WorkPiMarkdownChangeSnapshot? {
        markdownEditor.pendingCollaborationSnapshot
    }

    func currentMarkdownSnapshot(for url: URL) -> WorkPiMarkdownChangeSnapshot? {
        let target = url.standardizedFileURL
        if markdownEditor.document?.url.standardizedFileURL == target {
            return markdownEditor.pendingCollaborationSnapshot
        }
        return pendingMarkdownSnapshots[target]
    }

    /// 把当前编辑器的协作快照放入按文件保存的账本。这个动作只复制快照，
    /// 不推进 Agent 基线；自动保存和 Agent 已知是两件不同的事。
    func captureCurrentMarkdownCollaboration() {
        guard let document = markdownEditor.document else { return }
        let url = document.url.standardizedFileURL
        if let snapshot = markdownEditor.pendingCollaborationSnapshot {
            pendingMarkdownSnapshots[url] = snapshot
        } else if approvedMarkdownChanges[url] == nil {
            pendingMarkdownSnapshots.removeValue(forKey: url)
        }
    }

    var hasPendingMarkdownCollaborationChanges: Bool {
        !allMarkdownSnapshots().isEmpty
            || !approvedMarkdownChanges.isEmpty
            || !activePromptMarkdownChanges.isEmpty
    }

    private func allMarkdownSnapshots() -> [URL: WorkPiMarkdownChangeSnapshot] {
        var snapshots = pendingMarkdownSnapshots
        if let current = markdownEditor.document?.url.standardizedFileURL,
           let snapshot = markdownEditor.pendingCollaborationSnapshot {
            snapshots[current] = snapshot
        }
        for approved in approvedMarkdownChanges.values {
            snapshots[approved.context.snapshot.url.standardizedFileURL] = approved.context.snapshot
        }
        for context in activePromptMarkdownChanges {
            snapshots[context.snapshot.url.standardizedFileURL] = context.snapshot
        }
        for item in queuedPrompts.flatMap(\.inspectorChanges) {
            snapshots[item.snapshot.url.standardizedFileURL] = item.snapshot
        }
        if let active = activeQueuedPrompt {
            for item in active.inspectorChanges {
                snapshots[item.snapshot.url.standardizedFileURL] = item.snapshot
            }
        }
        return snapshots
    }

    private func markdownURL(for url: URL?) -> URL? {
        (url ?? markdownEditor.document?.url)?.standardizedFileURL
    }

    private func isCurrentMarkdown(_ url: URL) -> Bool {
        markdownEditor.document?.url.standardizedFileURL == url.standardizedFileURL
    }

    private func hasQueuedMarkdownChange(for url: URL) -> Bool {
        let target = url.standardizedFileURL
        return queuedPrompts.contains {
            $0.inspectorChanges.contains { $0.snapshot.url.standardizedFileURL == target }
        } || activeQueuedPrompt?.inspectorChanges.contains {
            $0.snapshot.url.standardizedFileURL == target
        } == true
    }

    private func snapshotMatchesCurrentState(_ snapshot: WorkPiMarkdownChangeSnapshot) -> Bool {
        guard let current = currentMarkdownSnapshot(for: snapshot.url) else { return false }
        return current.baseHash == snapshot.baseHash
            && current.currentHash == snapshot.currentHash
            && current.currentText == snapshot.currentText
    }

    func scheduleMarkdownApprovalReconciliation() {
        guard !markdownApprovalReconcileScheduled else { return }
        markdownApprovalReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markdownApprovalReconcileScheduled = false
            for (url, approved) in self.approvedMarkdownChanges
                where self.isCurrentMarkdown(url)
                && !self.snapshotMatchesCurrentState(approved.context.snapshot) {
                self.revokeApprovedMarkdownChange(for: url)
                self.markdownDiffReviewError = "Markdown 在确认后发生了变化，请重新审阅差异；原消息已保留。"
            }
        }
    }

    var markdownCollaborationDisplayState: WorkPiMarkdownCollaborationDisplayState {
        let snapshots = allMarkdownSnapshots()
        let urls = Set(snapshots.keys)
            .union(approvedMarkdownChanges.keys)
            .union(queuedPrompts.flatMap { $0.inspectorChanges.map { $0.snapshot.url.standardizedFileURL } })
            .union(activeQueuedPrompt?.inspectorChanges.map { $0.snapshot.url.standardizedFileURL } ?? [])
        let currentURL = markdownEditor.document?.url.standardizedFileURL
        let items = urls.sorted { $0.path < $1.path }.compactMap { url -> WorkPiMarkdownCollaborationItem? in
            guard let snapshot = snapshots[url]
                ?? approvedMarkdownChanges[url]?.context.snapshot
            else { return nil }
            let approved = approvedMarkdownChanges[url]
            let approvalIsStale = approved.map {
                isCurrentMarkdown(url)
                    && !snapshotMatchesCurrentState($0.context.snapshot)
            } ?? false
            return WorkPiMarkdownCollaborationItem(
                id: url,
                fileName: url.lastPathComponent,
                changedBlockCount: max(1, snapshot.changedBlockIDs.count),
                isCurrent: currentURL == url,
                isApproved: approved != nil && !approvalIsStale,
                hasQueuedChange: hasQueuedMarkdownChange(for: url),
                isBuildingReview: markdownDiffBuildURL == url && isBuildingMarkdownDiffReview
            )
        }
        let primary = items.first(where: { $0.isCurrent }) ?? items.first
        let approvalIsStale = currentURL.flatMap { url in
            guard let approved = approvedMarkdownChanges[url] else { return false }
            return !snapshotMatchesCurrentState(approved.context.snapshot)
        } ?? false
        return WorkPiMarkdownCollaborationDisplayState(
            items: items,
            fileName: primary?.fileName ?? "Markdown",
            changedBlockCount: primary?.changedBlockCount ?? 0,
            hasPendingChanges: !items.isEmpty,
            isApproved: primary?.isApproved == true,
            approvalIsStale: approvalIsStale,
            hasQueuedChange: primary?.hasQueuedChange == true,
            closeBlocked: markdownCollaborationCloseBlocked,
            isBuildingReview: isBuildingMarkdownDiffReview,
            errorMessage: markdownDiffReviewError
        )
    }

    /// 用户点击某个文件的“审阅差异”。未传 URL 时兼容旧入口，优先审阅当前文件。
    func presentMarkdownDiffReview(for requestedURL: URL? = nil) {
        _ = markdownEditor.refreshExternalConflict()
        captureCurrentMarkdownCollaboration()
        let targetURL = markdownURL(for: requestedURL)
            ?? allMarkdownSnapshots().keys.sorted(by: { $0.path < $1.path }).first
        guard let targetURL,
              let snapshot = currentMarkdownSnapshot(for: targetURL),
              let workspaceRoot = markdownEditor.workspaceRootURL
        else {
            markdownDiffReviewError = "当前没有待附加的 Markdown 修改。"
            return
        }
        if isCurrentMarkdown(targetURL), markdownEditor.conflict != nil {
            markdownDiffReviewError = "请先处理 Markdown 外部修改冲突，再审阅差异。"
            return
        }
        if let approved = approvedMarkdownChanges[targetURL] {
            if snapshotMatchesCurrentState(approved.context.snapshot) {
                markdownDiffReviewError = "这份 Markdown 修改已经确认，将随下一条普通消息发送。"
                return
            }
            revokeApprovedMarkdownChange(for: targetURL)
        }
        guard !hasQueuedMarkdownChange(for: targetURL) else {
            markdownDiffReviewError = "这份 Markdown 修改已经随排队消息冻结，请等待它完成或取消排队。"
            return
        }

        markdownDiffReview = nil
        markdownDiffReviewError = nil
        isBuildingMarkdownDiffReview = true
        markdownDiffCancellationToken?.cancel()
        markdownDiffBuildTask?.cancel()
        markdownDiffBuildURL = targetURL
        let token = UUID()
        markdownDiffBuildToken = token
        let revision = markdownEditor.collaborationRevision
        let validateDisk = !isCurrentMarkdown(targetURL)
        let cancellation = WorkPiMarkdownDiffCancellationToken()
        markdownDiffCancellationToken = cancellation
        let worker = Task.detached(priority: .userInitiated) {
            () -> WorkPiMarkdownDiffTaskResult in
            do {
                if validateDisk {
                    try cancellation.checkCancellation()
                    try WorkPiMarkdownDiffBuilder.validateSavedSnapshot(
                        snapshot,
                        workspaceRoot: workspaceRoot
                    )
                }
                return .success(try WorkPiMarkdownDiffBuilder.build(
                    snapshot: snapshot,
                    workspaceRoot: workspaceRoot,
                    cancellationCheck: cancellation.checkCancellation
                ))
            } catch is CancellationError {
                return .cancelled
            } catch let failure as WorkPiMarkdownDiffBuildFailure {
                return .failure(failure)
            } catch {
                return .failure(.encodingFailed)
            }
        }
        markdownDiffBuildTask = Task { [weak self] in
            let result = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: {
                cancellation.cancel()
                worker.cancel()
            })
            guard let self,
                  !Task.isCancelled,
                  self.markdownDiffBuildToken == token
            else { return }
            self.markdownDiffBuildTask = nil
            self.markdownDiffBuildURL = nil
            if self.markdownDiffCancellationToken === cancellation {
                self.markdownDiffCancellationToken = nil
            }
            self.isBuildingMarkdownDiffReview = false
            guard self.snapshotMatchesCurrentState(snapshot),
                  self.markdownEditor.conflict == nil,
                  self.markdownEditor.workspaceRootURL == workspaceRoot
            else {
                self.markdownDiffReviewError = "Markdown 在审阅期间发生了变化，请重新审阅。"
                return
            }
            guard case .success(let context) = result else {
                if case .failure(let failure) = result {
                    self.markdownDiffReviewError = failure.message
                }
                return
            }
            self.markdownDiffReview = WorkPiMarkdownDiffReview(
                context: context,
                editorRevision: revision
            )
        }
    }

    func presentMarkdownDiffReview() {
        presentMarkdownDiffReview(for: nil)
    }

    func dismissMarkdownDiffReview() {
        markdownDiffReview = nil
    }

    /// 用户明确选择某个文件附加到下一条普通消息。
    func approveMarkdownDiffReview(id: UUID) {
        guard let review = markdownDiffReview, review.id == id else { return }
        let url = review.context.snapshot.url.standardizedFileURL
        guard markdownEditor.conflict == nil,
              snapshotMatchesCurrentState(review.context.snapshot)
        else {
            markdownDiffReview = nil
            markdownDiffReviewError = "Markdown 在确认前发生了变化，请重新审阅。"
            return
        }
        let confirmationToken = UUID()
        let approved = WorkPiMarkdownApprovedChange(
            context: review.context,
            editorRevision: review.editorRevision,
            confirmationToken: confirmationToken
        )
        approvedMarkdownChanges[url] = approved
        issuedMarkdownApprovalTokens[confirmationToken] = review.context.approvalFingerprint
        trimMarkdownApprovalTokens()
        markdownCollaborationCloseBlocked = false
        markdownDiffReview = nil
        markdownDiffReviewError = nil
    }

    func discardPendingMarkdownCollaboration(for requestedURL: URL? = nil) {
        guard let url = markdownURL(for: requestedURL) else {
            markdownDiffReviewError = "没有可放弃同步的 Markdown 修改。"
            return
        }
        guard !hasQueuedMarkdownChange(for: url) else {
            markdownDiffReviewError = "已有冻结的 Markdown 差异正在排队，请等待它发送或取消排队。"
            return
        }
        if isCurrentMarkdown(url) {
            guard markdownEditor.discardPendingCollaboration() else {
                markdownDiffReviewError = markdownEditor.conflict != nil
                    ? "存在未解决的 Markdown 冲突，暂不能放弃同步。"
                    : "Markdown 尚未成功保存，暂不能放弃同步。"
                return
            }
        }
        revokeApprovedMarkdownChange(for: url)
        pendingMarkdownSnapshots.removeValue(forKey: url)
        if markdownDiffReview?.context.snapshot.url.standardizedFileURL == url {
            markdownDiffReview = nil
        }
        markdownDiffReviewError = nil
        markdownCollaborationCloseBlocked = false
        revokeUnusedMarkdownApprovalTokens()
    }

    func discardPendingMarkdownCollaboration() {
        discardPendingMarkdownCollaboration(for: nil)
    }

    func handleMarkdownCloseFailure() {
        if markdownEditor.isCloseBlockedByPendingCollaboration
            || hasPendingMarkdownCollaborationChanges {
            markdownCollaborationCloseBlocked = true
            markdownDiffReviewError = "Markdown 已保存，但尚未通知 Agent；请审阅需要发送的文件，或逐个放弃同步。"
        } else {
            markdownCollaborationCloseBlocked = false
        }
    }

    func cancelApprovedMarkdownDiff(for requestedURL: URL? = nil) {
        guard let url = markdownURL(for: requestedURL) else { return }
        revokeApprovedMarkdownChange(for: url)
        markdownDiffReviewError = nil
        markdownCollaborationCloseBlocked = false
    }

    func cancelApprovedMarkdownDiff() {
        cancelApprovedMarkdownDiff(for: nil)
    }

    /// 校验一个已经确认的文件差异是否仍然对应当前账本。
    func canSendExplicitMarkdownChange(_ context: WorkPiMarkdownDiffContext) -> Bool {
        canSendExplicitMarkdownChanges([context])
    }

    func canSendExplicitMarkdownChanges(
        _ contexts: [WorkPiMarkdownDiffContext],
        requireCurrentSnapshot: Bool = true
    ) -> Bool {
        for context in contexts {
            guard let token = context.approvalToken,
                  issuedMarkdownApprovalTokens[token] == context.approvalFingerprint,
                  !requireCurrentSnapshot || snapshotMatchesCurrentState(context.snapshot)
            else {
                markdownDiffReviewError = "Markdown 差异已变化或没有来自当前确认流程的有效票据，未发送。"
                return false
            }
            if isCurrentMarkdown(context.snapshot.url), markdownEditor.conflict != nil {
                markdownDiffReviewError = "Markdown 存在未解决的外部修改冲突，差异暂未发送。"
                return false
            }
        }
        return true
    }

    func markdownChangeForNextPrompt() -> WorkPiMarkdownSubmissionChange {
        _ = markdownEditor.refreshExternalConflict()
        captureCurrentMarkdownCollaboration()
        let approvals = approvedMarkdownChanges.values.sorted {
            $0.context.envelope.path < $1.context.envelope.path
        }
        guard !approvals.isEmpty else { return .none }
        var contexts: [WorkPiMarkdownDiffContext] = []
        for approved in approvals {
            let context = approved.context.approvedCopy(with: approved.confirmationToken)
            guard canSendExplicitMarkdownChanges([context]) else {
                revokeApprovedMarkdownChange(for: context.snapshot.url)
                markdownDiffReviewError = "Markdown 在确认后发生了变化，请重新审阅差异；原消息已保留。"
                return .needsReview
            }
            contexts.append(context)
        }
        return .ready(contexts)
    }

    /// 发送前消费“已确认”标记，但保留 token 和快照直到 Runtime 接受。
    func consumeApprovedMarkdownDiff(for contexts: [WorkPiMarkdownDiffContext]? = nil) {
        let targets = contexts?.map { $0.snapshot.url.standardizedFileURL }
            ?? markdownURL(for: nil).map { [$0] }
            ?? []
        for url in targets {
            approvedMarkdownChanges.removeValue(forKey: url)
        }
        markdownDiffReviewError = nil
        revokeUnusedMarkdownApprovalTokens()
    }

    func acknowledgeActiveMarkdownDiff() {
        let active = activePromptMarkdownChanges
        activePromptMarkdownChanges = []
        for context in active {
            let url = context.snapshot.url.standardizedFileURL
            let acknowledged: Bool
            if isCurrentMarkdown(url) {
                acknowledged = markdownEditor.acknowledgePendingCollaboration(context.snapshot)
            } else if pendingMarkdownSnapshots[url] == context.snapshot {
                pendingMarkdownSnapshots.removeValue(forKey: url)
                acknowledged = true
            } else {
                acknowledged = false
            }
            if let token = context.approvalToken {
                issuedMarkdownApprovalTokens.removeValue(forKey: token)
            }
            approvedMarkdownChanges.removeValue(forKey: url)
            if !acknowledged {
                markdownDiffReviewError = "Markdown 基线在发送期间发生变化，已保留待审阅修改。"
            }
        }
        revokeUnusedMarkdownApprovalTokens()
    }

    /// 发送失败、取消或 Runtime 断开时只清掉“发送中”标记，不确认协作基线。
    func discardActiveMarkdownDiff() {
        let active = activePromptMarkdownChanges
        activePromptMarkdownChanges = []
        for context in active {
            guard let token = context.approvalToken,
                  !hasQueuedMarkdownChange(with: token)
            else { continue }
            issuedMarkdownApprovalTokens.removeValue(forKey: token)
        }
        revokeUnusedMarkdownApprovalTokens()
    }

    /// 文件切换时只清理当前审阅界面；按文件保存的快照和已确认状态继续保留。
    func resetMarkdownReviewUI() {
        markdownDiffCancellationToken?.cancel()
        markdownDiffCancellationToken = nil
        markdownDiffBuildTask?.cancel()
        markdownDiffBuildTask = nil
        markdownDiffBuildURL = nil
        markdownDiffBuildToken = UUID()
        markdownDiffReview = nil
        markdownDiffReviewError = nil
        isBuildingMarkdownDiffReview = false
        markdownCollaborationCloseBlocked = false
        revokeUnusedMarkdownApprovalTokens()
    }

    /// 工作区真正关闭时清理所有协作层 UI/快照；调用方必须先通过关闭闸门。
    func resetMarkdownCollaborationIntent() {
        resetMarkdownReviewUI()
        for approved in approvedMarkdownChanges.values {
            issuedMarkdownApprovalTokens.removeValue(forKey: approved.confirmationToken)
        }
        approvedMarkdownChanges.removeAll()
        pendingMarkdownSnapshots.removeAll()
        activePromptMarkdownChanges.removeAll()
        revokeUnusedMarkdownApprovalTokens()
    }

    func revokeUnusedMarkdownApprovalTokens() {
        var retainedTokens = Set(approvedMarkdownChanges.values.map(\.confirmationToken))
        retainedTokens.formUnion(queuedPrompts.flatMap { $0.inspectorChanges.compactMap(\.approvalToken) })
        retainedTokens.formUnion(activeQueuedPrompt?.inspectorChanges.compactMap(\.approvalToken) ?? [])
        retainedTokens.formUnion(activePromptMarkdownChanges.compactMap(\.approvalToken))
        issuedMarkdownApprovalTokens = issuedMarkdownApprovalTokens.filter {
            retainedTokens.contains($0.key)
        }
    }

    private func trimMarkdownApprovalTokens() {
        revokeUnusedMarkdownApprovalTokens()
        guard issuedMarkdownApprovalTokens.count > 2_048 else { return }
        let protected = Set(approvedMarkdownChanges.values.map(\.confirmationToken))
            .union(queuedPrompts.flatMap { $0.inspectorChanges.compactMap(\.approvalToken) })
            .union(activeQueuedPrompt?.inspectorChanges.compactMap(\.approvalToken) ?? [])
            .union(activePromptMarkdownChanges.compactMap(\.approvalToken))
        let removable = issuedMarkdownApprovalTokens.keys.filter { !protected.contains($0) }
        for token in removable where issuedMarkdownApprovalTokens.count > 2_048 {
            issuedMarkdownApprovalTokens.removeValue(forKey: token)
        }
    }

    private func revokeApprovedMarkdownChange(for url: URL) {
        if let approved = approvedMarkdownChanges.removeValue(forKey: url.standardizedFileURL) {
            issuedMarkdownApprovalTokens.removeValue(forKey: approved.confirmationToken)
        }
    }

    private func hasQueuedMarkdownChange(with token: UUID) -> Bool {
        queuedPrompts.contains {
            $0.inspectorChanges.contains { $0.approvalToken == token }
        } || activeQueuedPrompt?.inspectorChanges.contains {
            $0.approvalToken == token
        } == true
    }
}
