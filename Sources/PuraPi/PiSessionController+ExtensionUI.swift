import Foundation
import PiRPC

/// Pi Extension UI 请求的生命周期和原生 UI 状态。
///
/// Pi RPC 允许多个扩展对话请求在同一条 Runtime 流上等待；PuraPi 只显示一个
/// 原生面板，其余请求按到达顺序排队。所有回传都经过 request id 去重。
extension PiSessionController {
    func handleExtensionUIRequest(_ record: PiRPCRecord) {
        guard let request = record.extensionUIRequest else { return }

        switch request.method {
        case "select", "confirm", "input", "editor":
            enqueueExtensionUIDialog(request)
        case "notify":
            let notification = PuraPiExtensionNotification(
                kind: .init(rawValue: request.notifyType),
                message: request.message ?? "Pi Extension 通知"
            )
            extensionNotifications.append(notification)
            if extensionNotifications.count > 4 {
                extensionNotifications.removeFirst(extensionNotifications.count - 4)
            }
        case "setStatus":
            guard let key = request.statusKey, !key.isEmpty else { return }
            if let text = request.statusText, !text.isEmpty {
                extensionStatuses[key] = text
            } else {
                extensionStatuses.removeValue(forKey: key)
            }
        case "setWidget":
            guard let key = request.widgetKey, !key.isEmpty else { return }
            if PiSubagentPanelPayload.isWidgetKey(key) {
                _ = consumeSubagentPanelRequest(request)
                return
            }
            if let lines = request.widgetLines, !lines.isEmpty {
                extensionWidgets[key] = PuraPiExtensionWidget(
                    id: key,
                    lines: lines,
                    placement: request.widgetPlacement ?? "aboveEditor"
                )
            } else {
                extensionWidgets.removeValue(forKey: key)
            }
        case "set_editor_text":
            draftPrompt = request.text ?? ""
        case "setTitle":
            // PuraPi 的窗口/项目标签标题由 AppKit 工作区管理；扩展的终端标题
            // 不应覆盖原生窗口标题。
            break
        default:
            // Pi 当前的 `custom()` 在 RPC 中不会发出请求；若未来版本新增了
            // 未知方法，必须回传取消而不是让扩展永久等待。
            lastError = "Pi Extension 请求了 PuraPi 尚未支持的 UI 方法：\(request.method)"
            respondToExtensionUI(requestID: request.id, result: .cancelled)
        }
    }

    func resolveExtensionUI(_ requestID: String, _ result: PuraPiExtensionUIResult) {
        guard let request = extensionUIRequest,
              request.id == requestID
        else { return }
        guard markExtensionUIRequestCompleted(requestID) else { return }

        extensionUITimeoutTask?.cancel()
        extensionUITimeoutTask = nil
        extensionUIRequest = nil

        let command: PiRPCCommand
        switch result {
        case .value(let value):
            command = .extensionUIResponse(requestID: requestID, value: value)
        case .confirmed(let confirmed):
            command = .extensionUIResponse(requestID: requestID, confirmed: confirmed)
        case .cancelled:
            command = .extensionUIResponse(requestID: requestID, cancelled: true)
        }

        let transport = self.transport
        let generation = self.generation
        let sessionEpoch = self.sessionEpoch
        let responseOperationID = UUID()
        extensionUIResponseOperationID = responseOperationID
        extensionUIResponseInFlight = true
        Task { [weak self] in
            defer {
                // The sheet is already gone at this point, but the write is
                // still a lifecycle barrier until send() has completed. A
                // late task must not clear the flag for a newer response.
                if let self,
                   self.extensionUIResponseOperationID == responseOperationID {
                    self.extensionUIResponseInFlight = false
                }
            }
            guard let self else { return }
            guard let transport else {
                self.lastError = "Pi Runtime 不可用，无法回应 Extension UI 请求。"
                self.cancelPendingExtensionUIRequests()
                return
            }

            do {
                try await self.sendRuntimeCommandWithTimeout(
                    command,
                    using: transport,
                    generation: generation,
                    sessionEpoch: sessionEpoch,
                    timeout: .milliseconds(500)
                )
            } catch {
                guard self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                self.lastError = "无法回应 Pi Extension UI 请求：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
                self.cancelPendingExtensionUIRequests()
                return
            }

            guard self.generation == generation,
                  self.extensionUIResponseOperationID == responseOperationID,
                  !self.runtimeTerminationHandled
            else { return }
            self.extensionUIResponseInFlight = false
            self.presentNextExtensionUIDialog(after: generation)
        }
    }

    func dismissExtensionNotification(_ id: UUID) {
        extensionNotifications.removeAll { $0.id == id }
    }

    /// 在 Abort、Runtime EOF、切换项目和关闭标签时调用。
    /// 返回值用于让调用方在停止传输前发送取消响应。
    @discardableResult
    func drainPendingExtensionUIRequests() -> [String] {
        var ids: [String] = []
        if let request = extensionUIRequest {
            ids.append(request.id)
        }
        ids.append(contentsOf: queuedExtensionUIRequests.map(\.id))

        extensionUIRequest = nil
        queuedExtensionUIRequests.removeAll()
        extensionUIRequestEnqueueDates.removeAll()
        extensionUITimeoutTask?.cancel()
        extensionUITimeoutTask = nil

        var uniqueIDs: [String] = []
        for id in ids where markExtensionUIRequestCompleted(id) {
            uniqueIDs.append(id)
        }
        return uniqueIDs
    }

    func cancelPendingExtensionUIRequests(reportError: Bool = false) {
        let requestIDs = drainPendingExtensionUIRequests()
        guard !requestIDs.isEmpty, let transport else { return }
        let generation = self.generation
        let sessionEpoch = self.sessionEpoch
        Task { [weak self] in
            await self?.sendExtensionUICancellations(
                requestIDs,
                using: transport,
                generation: generation,
                sessionEpoch: sessionEpoch,
                reportError: reportError
            )
        }
    }

    private func enqueueExtensionUIDialog(_ request: PiExtensionUIRequest) {
        guard request.dialogMethod != nil else {
            lastError = "Pi Extension 对话方法无效：\(request.method)"
            respondToExtensionUI(requestID: request.id, result: .cancelled)
            return
        }

        guard !completedExtensionUIRequestIDs.contains(request.id),
              extensionUIRequest?.id != request.id,
              !queuedExtensionUIRequests.contains(where: { $0.id == request.id })
        else { return }

        if extensionUIRequest == nil, !extensionUIResponseInFlight {
            extensionUIRequest = request
            scheduleExtensionUITimeout(for: request)
        } else if queuedExtensionUIRequests.count < 64 {
            queuedExtensionUIRequests.append(request)
            extensionUIRequestEnqueueDates[request.id] = Date()
            scheduleQueuedExtensionUITimeout(for: request)
        } else {
            // Do not let an extension turn the UI queue into an unbounded
            // memory/lifecycle backlog. A dropped request still receives the
            // protocol-level cancellation so Pi is not left waiting forever.
            rejectOverflowingExtensionUIDialog(request.id)
        }
    }

    func presentNextExtensionUIDialog(after generation: UUID) {
        guard !extensionUIResponseInFlight,
              !sessionRebuildInFlight,
              extensionUIRequest == nil,
              !queuedExtensionUIRequests.isEmpty
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.generation == generation,
                  !self.extensionUIResponseInFlight,
                  !self.sessionRebuildInFlight,
                  self.extensionUIRequest == nil,
                  !self.queuedExtensionUIRequests.isEmpty
            else { return }
            let next = self.queuedExtensionUIRequests.removeFirst()
            let enqueuedAt = self.extensionUIRequestEnqueueDates.removeValue(forKey: next.id)
            self.extensionUIRequest = next
            self.scheduleExtensionUITimeout(for: next, enqueuedAt: enqueuedAt)
        }
    }

    private func scheduleQueuedExtensionUITimeout(for request: PiExtensionUIRequest) {
        guard let timeout = request.timeoutMilliseconds, timeout > 0 else { return }
        let requestID = request.id
        let generation = self.generation
        let epoch = self.sessionEpoch
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(timeout))
            } catch {
                return
            }
            guard let self,
                  self.generation == generation,
                  self.sessionEpoch == epoch,
                  let index = self.queuedExtensionUIRequests.firstIndex(where: { $0.id == requestID })
            else { return }
            self.queuedExtensionUIRequests.remove(at: index)
            self.extensionUIRequestEnqueueDates.removeValue(forKey: requestID)
            guard self.markExtensionUIRequestCompleted(requestID) else { return }
            guard let transport = self.transport else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sendRuntimeCommandWithTimeout(
                        .extensionUIResponse(requestID: requestID, cancelled: true),
                        using: transport,
                        generation: generation,
                        sessionEpoch: epoch,
                        timeout: .milliseconds(500)
                    )
                } catch {
                    guard self.generation == generation,
                          self.sessionEpoch == epoch,
                          !self.runtimeTerminationHandled
                    else { return }
                    if self.handleTerminalTransportSendFailure(error, generation: generation) {
                        return
                    }
                    self.lastError = "无法取消 Pi Extension UI 请求：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
                }
            }
        }
    }

    private func scheduleExtensionUITimeout(
        for request: PiExtensionUIRequest,
        enqueuedAt: Date? = nil
    ) {
        extensionUITimeoutTask?.cancel()
        guard let timeout = request.timeoutMilliseconds, timeout > 0 else { return }

        let requestID = request.id
        let generation = self.generation
        let elapsed = enqueuedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remainingMilliseconds = max(
            1,
            timeout - Int(elapsed * 1_000)
        )
        let epoch = self.sessionEpoch
        extensionUITimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(remainingMilliseconds))
            } catch {
                return
            }
            guard let self,
                  self.generation == generation,
                  self.sessionEpoch == epoch,
                  self.extensionUIRequest?.id == requestID
            else { return }
            self.resolveExtensionUI(requestID, .cancelled)
        }
    }

    private func rejectOverflowingExtensionUIDialog(_ requestID: String) {
        guard markExtensionUIRequestCompleted(requestID),
              let transport else { return }
        let generation = self.generation
        let sessionEpoch = self.sessionEpoch
        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.sendRuntimeCommandWithTimeout(
                    .extensionUIResponse(requestID: requestID, cancelled: true),
                    using: transport,
                    generation: generation,
                    sessionEpoch: sessionEpoch,
                    timeout: .milliseconds(500)
                )
            } catch {
                guard let self,
                      self.generation == generation,
                      self.sessionEpoch == sessionEpoch,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                self.lastError = "无法取消超出的 Pi Extension UI 请求：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    private func respondToExtensionUI(requestID: String, result: PuraPiExtensionUIResult) {
        guard markExtensionUIRequestCompleted(requestID) else { return }
        let command: PiRPCCommand
        switch result {
        case .value(let value):
            command = .extensionUIResponse(requestID: requestID, value: value)
        case .confirmed(let confirmed):
            command = .extensionUIResponse(requestID: requestID, confirmed: confirmed)
        case .cancelled:
            command = .extensionUIResponse(requestID: requestID, cancelled: true)
        }
        guard let transport else { return }
        let generation = self.generation
        let sessionEpoch = self.sessionEpoch
        let responseOperationID = UUID()
        extensionUIResponseOperationID = responseOperationID
        extensionUIResponseInFlight = true
        Task { [weak self] in
            defer {
                if let self,
                   self.extensionUIResponseOperationID == responseOperationID {
                    self.extensionUIResponseInFlight = false
                }
            }
            do {
                guard let self else { return }
                try await self.sendRuntimeCommandWithTimeout(
                    command,
                    using: transport,
                    generation: generation,
                    sessionEpoch: sessionEpoch,
                    timeout: .milliseconds(500)
                )
            } catch {
                guard let self,
                      self.generation == generation,
                      !self.runtimeTerminationHandled
                else { return }
                if self.handleTerminalTransportSendFailure(error, generation: generation) {
                    return
                }
                self.lastError = "无法回应 Pi Extension UI 请求：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
            }
        }
    }

    private enum ExtensionUISendFailure: Error {
        case timeout
    }

    private func sendRuntimeCommandWithTimeout(
        _ command: PiRPCCommand,
        using transport: any PiRPCTransport,
        generation: UUID,
        sessionEpoch: UUID? = nil,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw PiRPCError.notRunning }
                try await self.sendRuntimeCommand(
                    command,
                    using: transport,
                    generation: generation,
                    sessionEpoch: sessionEpoch
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ExtensionUISendFailure.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ExtensionUISendFailure.timeout
            }
            result
        }
    }

    private func markExtensionUIRequestCompleted(_ id: String) -> Bool {
        guard !completedExtensionUIRequestIDs.contains(id) else { return false }
        completedExtensionUIRequestIDs.insert(id)
        completedExtensionUIRequestOrder.append(id)

        // Pi 为请求生成 UUID；按完成顺序淘汰，而不是从 Set 中任意取值，
        // 保证最近的 256 个 request id 始终具有确定性的 exactly-once 保护。
        while completedExtensionUIRequestOrder.count > 256 {
            let oldest = completedExtensionUIRequestOrder.removeFirst()
            completedExtensionUIRequestIDs.remove(oldest)
        }
        return true
    }

    /// Stop/rebuild must wait for the response bytes already handed to the
    /// transport.  Polling is intentionally bounded to the transport's own
    /// cancellable send; no state queue or MainActor lock is held while waiting.
    func waitForExtensionUIResponseBarrier(
        timeout: Duration = .milliseconds(250)
    ) async {
        let attempts = max(1, Int(timeout / .milliseconds(5)))
        for _ in 0..<attempts where extensionUIResponseInFlight {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return
            }
        }
    }

    func sendExtensionUICancellations(
        _ requestIDs: [String],
        using transport: any PiRPCTransport,
        generation: UUID? = nil,
        sessionEpoch: UUID? = nil,
        reportError: Bool = false
    ) async {
        guard !requestIDs.isEmpty else { return }
        let expectedGeneration = generation ?? self.generation
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                for requestID in requestIDs {
                    do {
                        try await self.sendRuntimeCommandWithTimeout(
                            .extensionUIResponse(requestID: requestID, cancelled: true),
                            using: transport,
                            generation: expectedGeneration,
                            sessionEpoch: sessionEpoch,
                            timeout: .milliseconds(500)
                        )
                    } catch {
                        guard reportError else { return }
                        await MainActor.run {
                            guard self.generation == expectedGeneration,
                                  sessionEpoch == nil || self.sessionEpoch == sessionEpoch
                            else { return }
                            self.lastError = "无法取消 Pi Extension UI 请求：\(PuraPiSensitiveText.redacted(error.localizedDescription))"
                        }
                        return
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
