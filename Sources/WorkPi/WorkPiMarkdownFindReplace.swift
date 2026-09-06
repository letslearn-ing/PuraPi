import Foundation
import PiDomain
import SwiftUI

@MainActor
final class WorkPiMarkdownFindReplaceState: ObservableObject {
    struct Match: Identifiable, Equatable {
        let blockID: UUID
        let range: NSRange
        var id: String { "\(blockID.uuidString):\(range.location):\(range.length)" }
    }

    @Published var isPresented = false
    @Published var query = "" {
        didSet { if query != oldValue { matches = [] } }
    }
    @Published var replacement = ""
    @Published private(set) var matches: [Match] = []
    @Published private(set) var currentIndex = 0

    private let maximumQueryBytes = 4 * 1024
    private let maximumMatches = 10_000

    var currentMatch: Match? {
        guard matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var summary: String {
        guard !query.isEmpty else { return "" }
        return matches.isEmpty ? "0" : "\(currentIndex + 1)/\(matches.count)"
    }

    func update(blocks: [MarkdownBlock]) {
        guard query.utf8.count <= maximumQueryBytes, !query.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }
        let previous = currentMatch
        var next: [Match] = []
        for block in blocks where block.acceptsCursor {
            let text = block.displayText as NSString
            var searchLocation = 0
            while searchLocation < text.length,
                  next.count < maximumMatches {
                let range = text.range(
                    of: query,
                    options: [.caseInsensitive],
                    range: NSRange(location: searchLocation, length: text.length - searchLocation)
                )
                guard range.location != NSNotFound else { break }
                next.append(Match(blockID: block.id, range: range))
                searchLocation = max(range.location + max(1, range.length), searchLocation + 1)
            }
            if next.count >= maximumMatches { break }
        }
        matches = next
        if let previous, let index = next.firstIndex(of: previous) {
            currentIndex = index
        } else {
            currentIndex = min(currentIndex, max(0, next.count - 1))
        }
    }

    func present(blocks: [MarkdownBlock]) {
        isPresented = true
        update(blocks: blocks)
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    func dismiss() {
        isPresented = false
        query = ""
        replacement = ""
        matches = []
        currentIndex = 0
    }
}

@MainActor
struct WorkPiMarkdownFindReplaceBar: View {
    @ObservedObject var state: WorkPiMarkdownFindReplaceState
    let language: WorkPiInterfaceLanguage
    let onReplaceCurrent: () -> Void
    let onReplaceAll: () -> Void
    let onNavigate: (UUID) -> Void

    @FocusState private var queryFocused: Bool
    private var isEnglish: Bool { language == .english }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                isEnglish ? "Find" : "查找",
                text: $state.query
            )
            .textFieldStyle(.plain)
            .frame(width: 170)
            .focused($queryFocused)
            .onSubmit { state.next(); navigate() }

            TextField(
                isEnglish ? "Replace" : "替换",
                text: $state.replacement
            )
            .textFieldStyle(.plain)
            .frame(width: 150)
            .onSubmit { onReplaceCurrent() }

            Text(state.summary)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 38)

            Button {
                state.previous()
                navigate()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(state.matches.isEmpty)
            .help(isEnglish ? "Previous match" : "上一个匹配")

            Button {
                state.next()
                navigate()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(state.matches.isEmpty)
            .help(isEnglish ? "Next match" : "下一个匹配")

            Button(isEnglish ? "Replace" : "替换当前", action: onReplaceCurrent)
                .controlSize(.small)
                .disabled(state.currentMatch == nil)
            Button(isEnglish ? "All" : "全部", action: onReplaceAll)
                .controlSize(.small)
                .disabled(state.matches.isEmpty)

            Button {
                state.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(isEnglish ? "Close (Esc)" : "关闭（Esc）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .onAppear {
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: state.currentMatch) { _, _ in navigate() }
        .onKeyPress(.escape) {
            state.dismiss()
            return .handled
        }
        .onExitCommand { state.dismiss() }
    }

    private func navigate() {
        if let match = state.currentMatch {
            onNavigate(match.blockID)
        }
    }
}
