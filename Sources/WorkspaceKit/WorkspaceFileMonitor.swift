import Foundation
import CoreServices

public enum WorkspaceFileChangeKind: Sendable, Equatable {
    case created
    case modified
    case removed
    case renamed
    case unknown
}

public struct WorkspaceFileChange: Sendable, Equatable {
    public let url: URL
    public let kind: WorkspaceFileChangeKind

    public init(url: URL, kind: WorkspaceFileChangeKind) {
        self.url = url.standardizedFileURL
        self.kind = kind
    }
}

public protocol WorkspaceFileMonitor: AnyObject, Sendable {
    func start() -> AsyncStream<WorkspaceFileChange>
    func stop()
}

/// 基于 macOS FSEvents 的工作区监视器。
/// 只发布路径和粗粒度变化类型，不读取或记录文件内容。
public final class FSEventsWorkspaceFileMonitor: WorkspaceFileMonitor, @unchecked Sendable {
    private final class CallbackContext {
        weak var owner: FSEventsWorkspaceFileMonitor?
    }

    private let rootURL: URL
    private let queue = DispatchQueue(label: "PuraPi.WorkspaceFileMonitor")
    private var stream: FSEventStreamRef?
    private var callbackContext: CallbackContext?
    private var continuation: AsyncStream<WorkspaceFileChange>.Continuation?
    private var activeStream: AsyncStream<WorkspaceFileChange>?
    private var started = false

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    deinit {
        // 不能调用 `stop()`：它用 `queue.sync`，而 deinit 可能已经在 `queue` 上。
        //
        // 实测的死锁路径（堆栈来自 xctest 崩溃报告）：
        //     stopAsynchronously → queue.async 里释放最后一个引用
        //       → deinit → stop() → queue.sync（已在同一串行队列上）→ 永久等待
        //
        // deinit 时已经不可能有其他线程持有自己，不需要串行队列保护，
        // 因此直接执行清理。
        stopLocked()
    }

    public func start() -> AsyncStream<WorkspaceFileChange> {
        queue.sync {
            // 0.1 只允许一个订阅者；重复调用返回同一个生命周期对应的流。
            if let activeStream {
                return activeStream
            }

            var capturedContinuation: AsyncStream<WorkspaceFileChange>.Continuation?
            let result = AsyncStream<WorkspaceFileChange> { newContinuation in
                capturedContinuation = newContinuation
            }
            guard let capturedContinuation else {
                let empty = AsyncStream<WorkspaceFileChange> { $0.finish() }
                activeStream = empty
                return empty
            }
            continuation = capturedContinuation
            activeStream = result
            capturedContinuation.onTermination = { @Sendable [weak self] _ in
                // AsyncStream 的终止回调可能在监视队列上触发；不要在这里同步回到同一队列。
                self?.stopAsynchronously()
            }

            let context = CallbackContext()
            context.owner = self
            callbackContext = context

            var streamContext = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(context).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagNoDefer
            )
            stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.fseventsCallback,
                &streamContext,
                [rootURL.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.15,
                flags
            )

            if let stream {
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
                started = true
            } else {
                capturedContinuation.finish()
                continuation = nil
            }
            return result
        }
    }

    public func stop() {
        queue.sync {
            stopLocked()
        }
    }

    private func stopAsynchronously() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        guard started || stream != nil || continuation != nil else { return }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        started = false
        continuation?.finish()
        continuation = nil
        activeStream = nil
        callbackContext = nil
    }

    private func publish(path: String, flags: FSEventStreamEventFlags) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let kind: WorkspaceFileChangeKind
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
            kind = .created
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
            kind = .removed
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
            kind = .renamed
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
            kind = .modified
        } else {
            kind = .unknown
        }
        continuation?.yield(WorkspaceFileChange(url: url, kind: kind))
    }

    private static let fseventsCallback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
        guard let info else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
        guard let owner = context.owner else { return }
        let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let flags = rawFlags
        for index in 0..<count {
            owner.publish(path: String(cString: paths[index]), flags: flags[index])
        }
    }
}
