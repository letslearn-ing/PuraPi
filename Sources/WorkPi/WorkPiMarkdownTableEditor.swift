import PiDomain
import SwiftUI

/// Markdown 表格的单元格编辑器。
///
/// 表格使用独立的焦点网格，避免把整张表当作一段普通文本；用户修改时才把
/// 结构化模型序列化回当前 table block，未修改的表格源码保持不动。
@MainActor
struct WorkPiMarkdownTableEditor: View {
    @Environment(\.workPiTheme) private var theme
    @State private var table: WorkPiMarkdownTableModel
    @FocusState private var focusedCell: WorkPiMarkdownTableModel.CellID?

    let block: MarkdownBlock
    let language: WorkPiInterfaceLanguage
    let onChange: (String) -> Void
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    private var isEnglish: Bool { language == .english }

    init(
        block: MarkdownBlock,
        language: WorkPiInterfaceLanguage,
        onChange: @escaping (String) -> Void,
        onFocus: @escaping () -> Void,
        onBlur: @escaping () -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void
    ) {
        self.block = block
        self.language = language
        self.onChange = onChange
        self.onFocus = onFocus
        self.onBlur = onBlur
        self.onUndo = onUndo
        self.onRedo = onRedo
        _table = State(initialValue: WorkPiMarkdownTableModel(source: block.source))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolbar
            tableGrid
        }
        .onChange(of: block.source) { _, newSource in
            let updated = WorkPiMarkdownTableModel(source: newSource)
            if updated != table {
                table = updated
            }
        }
        .onChange(of: focusedCell) { _, newValue in
            if newValue == nil { onBlur() } else { onFocus() }
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "z"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            if keyPress.modifiers.contains(.shift) {
                onRedo()
            } else {
                onUndo()
            }
            return .handled
        }
        .padding(.horizontal, 2)
    }

    private var toolbar: some View {
        HStack(spacing: 5) {
            Text(isEnglish ? "Table" : "表格")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                table.appendRow()
                publishChange()
                focusedCell = WorkPiMarkdownTableModel.CellID(
                    row: table.rowCountIncludingHeader - 1,
                    column: 0
                )
            } label: {
                Label(
                    isEnglish ? "Add row" : "添加行",
                    systemImage: "plus"
                )
            }
            .help(isEnglish ? "Add row" : "添加行")
            Button {
                guard let row = focusedCell?.row, row > 0 else { return }
                table.removeRow(at: row)
                publishChange()
                focusedCell = nil
            } label: {
                Label(
                    isEnglish ? "Remove row" : "删除行",
                    systemImage: "minus"
                )
            }
            .disabled(table.rows.isEmpty || focusedCell?.row == 0 || focusedCell == nil)
            .help(isEnglish ? "Remove selected row" : "删除当前行")
            Button {
                table.appendColumn()
                publishChange()
                focusedCell = WorkPiMarkdownTableModel.CellID(
                    row: focusedCell?.row ?? 0,
                    column: table.columnCount - 1
                )
            } label: {
                Label(
                    isEnglish ? "Add column" : "添加列",
                    systemImage: "rectangle.split.3x1"
                )
            }
            .help(isEnglish ? "Add column" : "添加列")
            Button {
                guard let column = focusedCell?.column else { return }
                table.removeColumn(at: column)
                publishChange()
                focusedCell = nil
            } label: {
                Label(
                    isEnglish ? "Remove column" : "删除列",
                    systemImage: "rectangle.split.2x1"
                )
            }
            .disabled(table.columnCount <= 1 || focusedCell == nil)
            .help(isEnglish ? "Remove selected column" : "删除当前列")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isEnglish ? "Table controls" : "表格操作")
    }

    private var tableGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    cell(row: 0, column: column, isHeader: true)
                }
            }
            Divider()
            ForEach(1..<table.rowCountIncludingHeader, id: \.self) { row in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(row: row, column: column, isHeader: false)
                    }
                }
                if row < table.rowCountIncludingHeader - 1 {
                    Divider().opacity(0.55)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.contentBackground.opacity(0.28),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(theme.panelBorder.opacity(0.45), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func cell(row: Int, column: Int, isHeader: Bool) -> some View {
        let cellID = WorkPiMarkdownTableModel.CellID(row: row, column: column)
        return WorkPiMarkdownTableCellEditor(
            text: table.value(at: cellID),
            isHeader: isHeader,
            isFocused: focusedCell == cellID,
            onChange: { value in
                guard table.value(at: cellID) != value else { return }
                table.update(value, at: cellID)
                publishChange()
            },
            onFocus: {
                focusedCell = cellID
                onFocus()
            },
            onBlur: onBlur,
            onMove: { forward in
                move(from: cellID, forward: forward)
            },
            onUndo: onUndo,
            onRedo: onRedo
        )
        .padding(.horizontal, 9)
        .padding(.vertical, isHeader ? 7 : 6)
        .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(
            isHeader
                ? (isEnglish ? "Header column \(column + 1)" : "第 \(column + 1) 列表头")
                : (isEnglish ? "Row \(row), column \(column + 1)" : "第 \(row) 行第 \(column + 1) 列")
        )
    }

    private func move(
        from cell: WorkPiMarkdownTableModel.CellID,
        forward: Bool
    ) {
        let totalRows = table.rowCountIncludingHeader
        let totalColumns = table.columnCount
        var row = cell.row
        var column = cell.column
        if forward {
            if column + 1 < totalColumns {
                column += 1
            } else if row + 1 < totalRows {
                row += 1
                column = 0
            } else {
                table.appendRow()
                row += 1
                column = 0
                publishChange()
            }
        } else if column > 0 {
            column -= 1
        } else if row > 0 {
            row -= 1
            column = totalColumns - 1
        }
        focusedCell = WorkPiMarkdownTableModel.CellID(row: row, column: column)
        onFocus()
    }

    private func publishChange() {
        onChange(table.serializedSource)
    }
}
