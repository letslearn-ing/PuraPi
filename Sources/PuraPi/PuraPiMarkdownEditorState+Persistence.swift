import Foundation
import PiDomain
import WorkspaceKit

/// Serializes detached saves for one editor state. A previous save may finish
/// after the user edits again; the locked coordinator remembers that previous
/// write so the next snapshot can safely use it as its own baseline instead of
/// reporting a false external conflict.
final class PuraPiMarkdownSaveCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var lastWrittenHashes: [URL: String] = [:]

    func save(
        _ document: MarkdownDocument,
        store: MarkdownDocumentStore,
        force: Bool
    ) throws -> MarkdownDocumentStore.SaveOutcome {
        lock.lock()
        defer { lock.unlock() }
        let key = document.url.standardizedFileURL
        let knownOwnHash = lastWrittenHashes[key]
        let outcome = try store.save(
            document,
            force: force,
            expectedCurrentHash: knownOwnHash
        )
        switch outcome {
        case .saved(let hash, _):
            lastWrittenHashes[key] = hash
        case .conflict, .deleted, .unreadable:
            lastWrittenHashes.removeValue(forKey: key)
        }
        return outcome
    }

    func rememberSavedHash(_ hash: String, for url: URL) {
        lock.lock()
        lastWrittenHashes[url.standardizedFileURL] = hash
        lock.unlock()
    }

    func forgetHash(for url: URL) {
        lock.lock()
        lastWrittenHashes.removeValue(forKey: url.standardizedFileURL)
        lock.unlock()
    }
}

/// Background persistence entry points for the Markdown editor.
///
/// The synchronous methods on `PuraPiMarkdownEditorState` remain available to
/// existing callers. These overloads are used by UI paths that can await and
/// keep MarkdownDocumentStore I/O off MainActor. `documentOperationID` is
/// advanced by every document edit, so an old completion cannot replace newer
/// text or conflict state.
@MainActor
extension PuraPiMarkdownEditorState {
    /// 重新打开此前已保存、但尚未发送给 Agent 的文件时恢复协作基线。
    @discardableResult
    func restorePendingCollaborationSnapshot(
        _ snapshot: PuraPiMarkdownChangeSnapshot
    ) -> Bool {
        guard let document,
              document.url.standardizedFileURL == snapshot.url.standardizedFileURL,
              serializedText(for: document) == snapshot.currentText,
              changeBuffer.restore(snapshot)
        else { return false }
        collaborationRevision &+= 1
        return true
    }

    private enum BackgroundSaveResult: Sendable {
        case outcome(MarkdownDocumentStore.SaveOutcome)
        case deleted
        case saveFailure(MarkdownDocumentStore.SaveFailure)
        case failure(String)
    }

    private func scheduleBackgroundAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            _ = await self?.save()
        }
    }

    @discardableResult
    func close() async -> Bool {
        await close(preservingPendingCollaboration: false)
    }

    @discardableResult
    func close(preservingPendingCollaboration: Bool) async -> Bool {
        imageDropTask?.cancel()
        imageDropTask = nil
        autosaveTask?.cancel()
        guard conflict == nil else { return false }
        if document?.isDirty == true {
            guard await save(force: false) else { return false }
        }
        if !preservingPendingCollaboration,
           let document,
           changeBuffer.hasPendingChanges(currentText: serializedText(for: document)) {
            return false
        }
        documentOperationID = UUID()
        document = nil
        baselineText = nil
        emptyDocumentPlaceholderID = UUID()
        collaborationRevision &+= 1
        changeBuffer.clear()
        loadError = nil
        saveState = .clean
        focusedBlockID = nil
        selection = nil
        cursorRequest = nil
        clearHistory()
        return true
    }

    @discardableResult
    func open(url: URL, workspaceRoot: URL) async -> Bool {
        imageDropTask?.cancel()
        imageDropTask = nil
        let targetURL = url.standardizedFileURL
        guard conflict == nil else { return false }
        if let current = document, current.url != targetURL, current.isDirty {
            guard await close() else { return false }
        }
        if let current = document, current.url == targetURL, current.isDirty { return false }

        autosaveTask?.cancel()
        let operation = UUID()
        documentOperationID = operation
        self.workspaceRoot = workspaceRoot
        conflict = nil
        loadError = nil
        let store = self.store
        let loaded = await Task.detached(priority: .userInitiated) {
            Result { try store.load(url: targetURL, workspaceRoot: workspaceRoot) }
        }.value
        guard documentOperationID == operation else { return false }
        emptyDocumentPlaceholderID = UUID()
        guard case .success(let loaded) = loaded else {
            document = nil
            baselineText = nil
            changeBuffer.clear()
            clearHistory()
            focusedBlockID = nil
            cursorRequest = nil
            selection = nil
            if case .failure(let error) = loaded {
                loadError = Self.describe(error)
            } else {
                loadError = "无法读取 Markdown 文件。"
            }
            saveState = .clean
            collaborationRevision &+= 1
            return false
        }
        document = loaded
        let loadedText = serializedText(for: loaded)
        baselineText = loadedText
        changeBuffer.reset(url: loaded.url, text: loadedText, hash: loaded.baselineHash)
        clearHistory()
        saveState = .clean
        focusedBlockID = loaded.blocks.first {
            $0.acceptsCursor && !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.id ?? loaded.blocks.first(where: { $0.acceptsCursor })?.id
        cursorRequest = nil
        selection = nil
        collaborationRevision &+= 1
        return true
    }

    @discardableResult
    func save(force: Bool = false) async -> Bool {
        guard let current = document else { return true }
        guard conflict == nil else { return false }
        guard current.isDirty || force else { return true }
        autosaveTask?.cancel()
        saveState = .saving
        let operation = documentOperationID
        let store = self.store
        let coordinator = self.backgroundSaveCoordinator
        let result = await Task.detached(priority: .utility) {
            do {
                return BackgroundSaveResult.outcome(
                    try coordinator.save(current, store: store, force: force)
                )
            } catch let failure as MarkdownDocumentStore.SaveFailure {
                if case .deleted = failure { return BackgroundSaveResult.deleted }
                return BackgroundSaveResult.saveFailure(failure)
            } catch {
                return BackgroundSaveResult.failure(error.localizedDescription)
            }
        }.value
        guard operation == documentOperationID,
              document?.url.standardizedFileURL == current.url.standardizedFileURL
        else {
            // The old snapshot may already have been committed by the actor.
            // Never apply its baseline to the newer document, but ensure that
            // the newer dirty snapshot gets another serialized save attempt.
            if document?.isDirty == true {
                scheduleBackgroundAutosave()
            }
            return false
        }

        switch result {
        case .outcome(let outcome):
            switch outcome {
            case .saved(let hash, let date):
                var updated = current
                updated.resetBaseline(hash: hash, modificationDate: date)
                document = updated
                baselineText = serializedText(for: updated)
                saveState = .saved
                return true
            case .conflict(let diskHash, let diskText):
                conflict = Conflict(kind: .modified, diskText: diskText, diskHash: diskHash)
                saveState = .dirty
                return false
            case .deleted:
                conflict = Conflict(kind: .deleted, diskText: "", diskHash: "")
                saveState = .dirty
                return false
            case .unreadable:
                conflict = Conflict(kind: .unreadable, diskText: "", diskHash: "")
                saveState = .dirty
                return false
            }
        case .deleted:
            conflict = Conflict(kind: .deleted, diskText: "", diskHash: "")
            saveState = .dirty
            return false
        case .saveFailure(let failure):
            saveState = .failed(Self.describe(failure))
            return false
        case .failure(let message):
            saveState = .failed(message)
            return false
        }
    }

    func resolveConflictByReloadingAsync() async {
        guard conflict != nil,
              let url = document?.url,
              let root = workspaceRoot
        else { return }
        conflict = nil
        documentOperationID = UUID()
        document = nil
        baselineText = nil
        changeBuffer.clear()
        clearHistory()
        _ = await open(url: url, workspaceRoot: root)
    }

    func resolveConflictByOverwritingAsync() async {
        guard conflict != nil, document != nil else { return }
        conflict = nil
        _ = await save(force: true)
    }
}
