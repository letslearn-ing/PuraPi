import AppKit
@preconcurrency import Combine
import PiDomain
import PiRPC
import SwiftUI

/// Native 对话区的搜索 overlay（覆盖层）。
///
/// 搜索状态仍由 SwiftUI 管理，但 overlay 独立放在 AppKit viewport 之上；这样
/// `ConversationPane` 移出真实滚动视图后，⌘F 仍能在正确的顶部位置显示搜索栏。
@available(macOS 26.0, *)
@MainActor
struct WorkPiNativeConversationSearchOverlayView: View {
    @ObservedObject var state: WorkPiConversationSearchState
    let language: WorkPiInterfaceLanguage
    let theme: WorkPiTheme

    var body: some View {
        Group {
            if state.isPresented {
                WorkPiConversationSearchBar(state: state, language: language)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(state.isPresented)
        .workPiTheme(theme)
    }
}

/// Native 工作区中的对话容器。
///
/// 顶部真实 `NSScrollView` 必须位于 AppKit 层级，而 Composer/队列等高频状态
/// 仍由 SwiftUI 渲染。把两者拆成上下两个兄弟视图，既保留原有消息 viewport
/// 的性能，也让它成为公开 `NSSplitViewItemAccessoryViewController` 的直接内容，
/// 由系统负责顶部 scroll pocket（滚动口袋）和模糊过渡。
@available(macOS 26.0, *)
@MainActor
final class WorkPiNativeConversationPaneController: NSViewController {
    private let session: PiSessionController
    private var isFileSelected: Bool
    private var language: WorkPiInterfaceLanguage
    private var theme: WorkPiTheme
    private var leadingContentInset: CGFloat
    private let viewport = WorkPiConversationViewportView()
    private let searchState: WorkPiConversationSearchState
    private let bottomController: NSHostingController<WorkPiConversationHostView>
    private let searchController: NSHostingController<WorkPiNativeConversationSearchOverlayView>
    private var sessionCancellable: AnyCancellable?
    private var searchCancellable: AnyCancellable?
    private var sessionRefreshScheduled = false
    private var handledScrollTarget: UUID?
    private var handledSearchTarget: UUID?

    init(
        session: PiSessionController,
        isFileSelected: Bool,
        language: WorkPiInterfaceLanguage,
        theme: WorkPiTheme,
        leadingContentInset: CGFloat
    ) {
        self.session = session
        self.isFileSelected = isFileSelected
        self.language = language
        self.theme = theme
        self.leadingContentInset = leadingContentInset
        let searchState = WorkPiConversationSearchState()
        self.searchState = searchState
        bottomController = NSHostingController(
            rootView: WorkPiConversationHostView(
                session: session,
                isFileSelected: isFileSelected,
                language: language,
                theme: theme,
                leadingContentInset: leadingContentInset,
                usesExternalViewport: true,
                searchState: searchState
            )
        )
        searchController = NSHostingController(
            rootView: WorkPiNativeConversationSearchOverlayView(
                state: searchState,
                language: language,
                theme: theme
            )
        )
        super.init(nibName: nil, bundle: nil)

        bottomController.sizingOptions = [.intrinsicContentSize]
        sessionCancellable = session.objectWillChange.sink { [weak self] _ in
            self?.scheduleSessionRefresh()
        }
        searchCancellable = searchState.objectWillChange.sink { [weak self] _ in
            self?.scheduleSessionRefresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = false

        addChild(bottomController)
        addChild(searchController)
        viewport.translatesAutoresizingMaskIntoConstraints = false
        bottomController.view.translatesAutoresizingMaskIntoConstraints = false
        searchController.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(viewport)
        root.addSubview(bottomController.view)
        root.addSubview(searchController.view)

        viewport.setContentHuggingPriority(.defaultLow, for: .vertical)
        viewport.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // GlassEffectContainer 在未给出垂直提议时可能报告 0 intrinsic height；
        // 给底部控件保留其最小可用高度，仍让它在队列/状态面板出现时按 intrinsic
        // size（固有尺寸）向上扩展。
        bottomController.view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        bottomController.view.setContentCompressionResistancePriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: root.topAnchor),
            viewport.bottomAnchor.constraint(equalTo: bottomController.view.topAnchor),
            bottomController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            searchController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchController.view.topAnchor.constraint(equalTo: root.topAnchor),
            searchController.view.heightAnchor.constraint(equalToConstant: 60),
        ])
        view = root
        refreshFromSession()
    }

    func update(
        isFileSelected: Bool,
        language: WorkPiInterfaceLanguage,
        theme: WorkPiTheme,
        leadingContentInset: CGFloat
    ) {
        let languageChanged = self.language != language
        let themeChanged = self.theme != theme
        let rootNeedsUpdate = self.isFileSelected != isFileSelected
            || languageChanged
            || themeChanged
            || abs(self.leadingContentInset - leadingContentInset) > 0.5
        self.isFileSelected = isFileSelected
        self.language = language
        self.theme = theme
        self.leadingContentInset = leadingContentInset

        if rootNeedsUpdate {
            bottomController.rootView = WorkPiConversationHostView(
                session: session,
                isFileSelected: isFileSelected,
                language: language,
                theme: theme,
                leadingContentInset: leadingContentInset,
                usesExternalViewport: true,
                searchState: searchState
            )
        }
        if languageChanged || themeChanged {
            searchController.rootView = WorkPiNativeConversationSearchOverlayView(
                state: searchState,
                language: language,
                theme: theme
            )
        }
        refreshFromSession()
        viewIfLoaded?.needsLayout = true
    }

    private func refreshFromSession() {
        guard isViewLoaded else { return }
        viewport.update(items: session.conversation, language: language, theme: theme)
        if searchState.isPresented {
            searchState.update(items: session.conversation)
        }
        if let searchTarget = searchState.currentMatch {
            guard handledSearchTarget != searchTarget else { return }
            handledSearchTarget = searchTarget
            viewport.scroll(to: searchTarget, onCompletion: {})
            return
        }
        handledSearchTarget = nil
        guard let target = session.conversationScrollTarget,
              handledScrollTarget != target
        else { return }
        handledScrollTarget = target
        viewport.scroll(to: target) { [weak session] in
            session?.clearConversationScrollTarget()
        }
    }

    private func scheduleSessionRefresh() {
        guard !sessionRefreshScheduled else { return }
        sessionRefreshScheduled = true
        // 会话流式更新或搜索按钮变化可能发生在 SwiftUI 的 body 计算期间；
        // 异步合并刷新 AppKit viewport，避免在发布回调里嵌套布局。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionRefreshScheduled = false
            self.refreshFromSession()
        }
    }
}
