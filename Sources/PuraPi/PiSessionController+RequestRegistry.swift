import Foundation
import PiRPC

/// Runtime 请求的用途。`generation` 负责隔离旧 Runtime，`id` 负责隔离同一
/// Runtime 内并发请求；两者缺一不可。
enum PuraPiRuntimeRequestPurpose: String, Hashable, Sendable {
    case bootstrap
    case refresh
    case rebuild
    case operation
    case status
    case extensionUI
}

struct PuraPiRuntimeRequest: Equatable, Sendable {
    /// 即使调用方错误地复用同一个 RPC id，每次登记仍有独立身份；旧 timeout
    /// 不能因结构体字段相同而结算新请求。
    let registrationID: UUID
    let id: String
    let command: String
    let purpose: PuraPiRuntimeRequestPurpose
    let generation: UUID
    let sessionEpoch: UUID
    let itemID: UUID?
    let queuedPrompt: PuraPiQueuedPrompt?
}

extension PiSessionController {
    /// 登记一个带 id 的 RPC 请求，并安排统一超时。所有调用发生在主 actor，
    /// 因此字典本身不需要额外锁；Task 只负责在到期后回到同一 actor。
    @discardableResult
    func registerRuntimeRequest(
        _ command: PiRPCCommand,
        purpose: PuraPiRuntimeRequestPurpose,
        itemID: UUID? = nil,
        queuedPrompt: PuraPiQueuedPrompt? = nil,
        timeout: Duration = .seconds(30)
    ) -> String? {
        guard let id = command.id else { return nil }
        if runtimeRequests[id] != nil
            || retiredRuntimeRequestIDs.contains(id)
            || ambiguousRuntimeRequestIDs.contains(id) {
            // 同一个 RPC id 的旧/新响应不可区分；从第一次复用开始，当前
            // generation 内永久拒绝该 id，不能把旧结果误配给后续请求。
            ambiguousRuntimeRequestIDs.insert(id)
        }
        let request = PuraPiRuntimeRequest(
            registrationID: UUID(),
            id: id,
            command: command.type,
            purpose: purpose,
            generation: generation,
            sessionEpoch: sessionEpoch,
            itemID: itemID,
            queuedPrompt: queuedPrompt
        )
        runtimeRequestTimeoutTasks[id]?.cancel()
        // Preserve the first epoch if a caller accidentally registers the same
        // command value twice; an old send must never be retargeted to a later
        // Session by overwriting this immutable ticket's mapping.
        if runtimeRequestSessionEpochs[command.runtimeTicketID] == nil {
            runtimeRequestSessionEpochs[command.runtimeTicketID] = sessionEpoch
        }
        runtimeRequests[id] = request
        let requestGeneration = generation
        runtimeRequestTimeoutTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self,
                  self.generation == requestGeneration,
                  let current = self.runtimeRequests[id],
                  current == request
            else { return }
            self.handleRuntimeRequestTimeout(request)
        }
        return id
    }

    /// 查找当前 generation 中与响应匹配的请求。
    ///
    /// 有 id 时必须精确匹配；无 id 仅在候选唯一时兼容接受。这样既兼容旧版
    /// Pi 的无 id 响应，也不会让一个迟到响应随机结算并发请求。
    func runtimeRequestCandidates(
        for command: String,
        purposes: Set<PuraPiRuntimeRequestPurpose> = []
    ) -> [PuraPiRuntimeRequest] {
        runtimeRequests.values.filter { request in
            request.generation == generation
                && request.sessionEpoch == sessionEpoch
                && request.command == command
                && (purposes.isEmpty || purposes.contains(request.purpose))
        }
    }

    func shouldIgnoreRuntimeResponse(_ record: PiRPCRecord) -> Bool {
        if let id = record.id {
            return retiredRuntimeRequestIDs.contains(id)
                || ambiguousRuntimeRequestIDs.contains(id)
        }
        guard let command = record.command else { return false }
        return idlessResponseQuarantine.contains(command)
    }

    func runtimeRequest(
        for record: PiRPCRecord,
        command: String,
        purposes: Set<PuraPiRuntimeRequestPurpose> = []
    ) -> PuraPiRuntimeRequest? {
        guard !shouldIgnoreRuntimeResponse(record) else { return nil }
        let candidates = runtimeRequestCandidates(for: command, purposes: purposes)

        if let responseID = record.id {
            guard !ambiguousRuntimeRequestIDs.contains(responseID) else { return nil }
            return candidates.first(where: { $0.id == responseID })
        }
        guard candidates.count == 1,
              !ambiguousRuntimeRequestIDs.contains(candidates[0].id)
        else { return nil }
        return candidates.first
    }

    func hasRuntimeRequest(
        for command: String,
        purposes: Set<PuraPiRuntimeRequestPurpose> = []
    ) -> Bool {
        runtimeRequests.values.contains { request in
            request.generation == generation
                && request.sessionEpoch == sessionEpoch
                && request.command == command
                && (purposes.isEmpty || purposes.contains(request.purpose))
        }
    }

    @discardableResult
    func settleRuntimeRequest(_ request: PuraPiRuntimeRequest) -> Bool {
        guard runtimeRequests[request.id] == request else { return false }
        runtimeRequests.removeValue(forKey: request.id)
        runtimeRequestTimeoutTasks.removeValue(forKey: request.id)?.cancel()
        // 成功收束也留下 tombstone（墓碑）；同一代再次复用该 id 时必须进入
        // ambiguous 状态，避免迟到的旧 response 被当作新请求。
        retiredRuntimeRequestIDs.insert(request.id)
        trimRetiredRuntimeRequestIDs()
        return true
    }

    @discardableResult
    func settleRuntimeRequest(id: String?) -> Bool {
        guard let id, let request = runtimeRequests[id] else { return false }
        return settleRuntimeRequest(request)
    }

    @discardableResult
    func settleRuntimeRequest(
        for record: PiRPCRecord,
        command: String,
        purposes: Set<PuraPiRuntimeRequestPurpose> = []
    ) -> PuraPiRuntimeRequest? {
        guard let request = runtimeRequest(
            for: record,
            command: command,
            purposes: purposes
        ) else { return nil }
        _ = settleRuntimeRequest(request)
        return request
    }

    func cancelAllRuntimeRequests() {
        for task in runtimeRequestTimeoutTasks.values {
            task.cancel()
        }
        // 被主动取消的请求同样可能留下无 id 迟到响应；在同一 generation
        // 内不能把它误配给随后创建的同命令请求。
        idlessResponseQuarantine.formUnion(runtimeRequests.values.map(\.command))
        retiredRuntimeRequestIDs.formUnion(runtimeRequests.keys)
        trimRetiredRuntimeRequestIDs()
        ambiguousRuntimeRequestIDs.removeAll()
        runtimeRequestTimeoutTasks.removeAll()
        runtimeRequests.removeAll()
    }

    func cancelRuntimeRequests(
        purpose: PuraPiRuntimeRequestPurpose,
        generation: UUID? = nil
    ) {
        let requests = runtimeRequests.values.filter { request in
            request.purpose == purpose
                && (generation == nil || request.generation == generation)
        }
        idlessResponseQuarantine.formUnion(requests.map(\.command))
        retiredRuntimeRequestIDs.formUnion(requests.map(\.id))
        trimRetiredRuntimeRequestIDs()
        for request in requests {
            _ = settleRuntimeRequest(request)
        }
    }

    /// 当前请求超时的统一兜底。各操作的可见状态仍由原有状态字段承载，
    /// 这里只负责解除 in-flight 并给出错误；Runtime 级别的启动请求另行收束。
    func handleRuntimeRequestTimeout(_ request: PuraPiRuntimeRequest) {
        guard runtimeRequests[request.id] == request else { return }
        _ = settleRuntimeRequest(request)
        retiredRuntimeRequestIDs.insert(request.id)
        trimRetiredRuntimeRequestIDs()
        // 当前 generation 内无法再区分迟到的无 id 响应属于旧请求还是重试请求；
        // 宁可要求重连换代，也不能把旧结果写入新操作。
        idlessResponseQuarantine.insert(request.command)
        let message = "Pi RPC 请求超时：\(request.command)"
        let isCurrentSessionOperation = isCurrentSessionOperation(request)

        switch request.command {
        case "set_auto_retry":
            if request.id == activeAutoRetryCommandID {
                activeAutoRetryCommandID = nil
                pendingAutoRetryValue = nil
                runtimeControlError = message
            }
        case "abort_retry":
            if request.id == activeAbortRetryCommandID {
                activeAbortRetryCommandID = nil
                activeAbortRetryWaitID = nil
                runtimeControlError = message
            }
        case "get_messages":
            if request.purpose == .bootstrap || request.purpose == .rebuild {
                if request.purpose == .bootstrap {
                    failRecentSessionRestore(message: message)
                } else {
                    failSessionRebuild(message: message)
                }
                return
            }
        case "get_state", "get_session_stats":
            if request.command == "get_state", request.purpose == .status,
               request.id == activeRuntimeStatusRequestID {
                activeRuntimeStatusRequestID = nil
                runtimeStatusLoading = false
                runtimeStatusPanelError = message
                return
            }
            if request.command == "get_session_stats" {
                activeStatsRequestIDs.remove(request.id)
                statsRequestItemIDs.removeValue(forKey: request.id)
                if activeStatsCommandID == request.id {
                    activeStatsCommandID = nil
                    statsCommandItemID = nil
                }
            }
            if request.purpose == .rebuild {
                failSessionRebuild(message: message)
                return
            }
            if request.purpose == .bootstrap {
                if expectsMessagesResponse {
                    failRecentSessionRestore(message: message)
                } else {
                    failFreshRuntimeBootstrap(message: message)
                }
                return
            }
        case "prompt":
            if request.id == activePromptCommandID {
                if let queuedPrompt = request.queuedPrompt {
                    activeQueuedPrompt = queuedPrompt
                }
                discardActiveMarkdownDiff()
                restoreActivePromptAttachments()
                phase = .failed
                runOutcome = .failed
                terminalRunStatus = .failed
                markCurrentAssistant(status: .failed)
                finalizeCurrentItemsAfterSettled(wasCancelled: false, failed: true)
                setActivity(nil)
            } else if let itemID = request.itemID {
                updateConversation(id: itemID) { item in
                    item.status = .failed
                    item.detail = message
                }
            }
        case "abort":
            if request.id == activeAbortCommandID {
                finishAbortFailure(message: message)
                return
            }
        case "bash":
            finishBashExecution(id: request.id, state: .failed(message: message))
        case "abort_bash":
            bashAbortRequested = false
            activeBashAbortCommandID = nil
        case "export_html":
            if request.id == activeExportCommandID {
                activeExportCommandID = nil
            }
        case "set_auto_compaction":
            if request.id == activeAutoCompactionCommandID {
                activeAutoCompactionCommandID = nil
            }
        case "get_available_models":
            if request.id == activeAvailableModelsCommandID {
                availableModelsRequestInFlight = false
                activeAvailableModelsCommandID = nil
            }
        case "get_available_thinking_levels":
            if request.id == activeAvailableThinkingLevelsCommandID {
                thinkingLevelsRequestInFlight = false
                activeAvailableThinkingLevelsCommandID = nil
            }
        case "set_model", "cycle_model":
            if request.id == activeModelCommandID {
                modelSwitchInFlight = false
                activeModelCommandID = nil
            }
        case "set_thinking_level", "cycle_thinking_level":
            if request.id == activeThinkingLevelCommandID {
                thinkingLevelSwitchInFlight = false
                activeThinkingLevelCommandID = nil
            }
        case "get_commands":
            if request.id == activeCommandsRequestID {
                commandsRequestInFlight = false
                activeCommandsRequestID = nil
            }
        case "fork":
            if request.id == activeForkCommandID { activeForkCommandID = nil }
        case "clone":
            if request.id == activeCloneCommandID { activeCloneCommandID = nil }
        case "switch_session":
            if request.id == activeSessionCommandID {
                activeSessionCommandID = nil
                pendingTurnLocation = nil
            }
        case "set_session_name":
            if request.id == activeRenameCommandID { activeRenameCommandID = nil }
        case "compact":
            if request.id == activeCompactRPCID {
                if let itemID = activeCompactCommandItemID {
                    updateConversation(id: itemID) { item in
                        item.status = .failed
                        item.detail = message
                    }
                }
                activeCompactCommandItemID = nil
                activeCompactRPCID = nil
                runOutcome = .failed
                terminalRunStatus = .failed
                phase = .failed
                runSettlementHandled = true
                setActivity(nil)
            }
        default:
            break
        }

        if isCurrentSessionOperation {
            failAmbiguousSessionOperation(message: message)
        }
        if request.command == "prompt"
            || request.command == "steer"
            || request.command == "follow_up" {
            activeCommandItemIDs.removeValue(forKey: request.id)
            activeCommandSources.removeValue(forKey: request.id)
            commandStartedWhileBusy.removeValue(forKey: request.id)
            // 请求确认超时后，远端可能仍在处理这条消息；在 settled 或换代前
            // 禁止新回合，避免迟到事件被归到用户的重试 Prompt。
            runtimeSettlementQuarantined = true
        }
        if let itemID = request.itemID {
            updateConversation(id: itemID) { item in
                if item.status == .pending || item.status == .streaming {
                    item.status = .failed
                    item.detail = message
                }
            }
        }
        lastError = message
    }

    private func isCurrentSessionOperation(_ request: PuraPiRuntimeRequest) -> Bool {
        switch request.command {
        case "switch_session": return activeSessionCommandID == request.id
        case "fork": return activeForkCommandID == request.id
        case "clone": return activeCloneCommandID == request.id
        case "set_session_name": return activeRenameCommandID == request.id
        default: return false
        }
    }

    private func failAmbiguousSessionOperation(message: String) {
        cancelAllRuntimeRequests()
        activeSessionCommandID = nil
        activeForkCommandID = nil
        activeCloneCommandID = nil
        activeRenameCommandID = nil
        pendingTurnLocation = nil
        runtimeReady = false
        phase = .failed
        runOutcome = .failed
        terminalRunStatus = .failed
        runSettlementHandled = true
        setActivity(nil)
        runtimeStatus = "会话操作响应超时"
        runtimeNotice = "Session 操作未确认完成。请重新连接 Runtime 后再继续。"
        lastError = message
    }

    private func trimRetiredRuntimeRequestIDs() {
        guard retiredRuntimeRequestIDs.count > 2_048 else { return }
        retiredRuntimeRequestIDs.removeAll(keepingCapacity: true)
        // Do not trim command tickets here. A send task may still be queued
        // after its request has settled, and dropping its epoch would make it
        // fall back to the current Session. The whole ticket table is cleared
        // only when the Runtime generation changes.
    }

    /// Fresh Runtime 的握手请求共享一组 received 标记；其中任一请求超时后，
    /// 其余兄弟响应不能再推进半完成握手或改写失败状态。
    func failFreshRuntimeBootstrap(message: String) {
        cancelRuntimeRequests(purpose: .bootstrap, generation: generation)
        runtimeReady = false
        receivedStateResponse = false
        receivedStatsResponse = false
        receivedMessagesResponse = false
        phase = .failed
        runOutcome = .failed
        terminalRunStatus = .failed
        runSettlementHandled = true
        setActivity(nil)
        runtimeStatus = "Pi Runtime 初始化失败"
        lastError = message
    }
}
