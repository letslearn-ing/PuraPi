import Foundation

/// 可编辑 Markdown 表格的轻量模型。
///
/// 表格块在磁盘上仍以原始源码保存；只有用户修改单元格或结构时才序列化为
/// 稳定的 pipe-table 形式。未触碰的表格不会被重新格式化。
struct WorkPiMarkdownTableModel: Equatable {
    enum Alignment: Equatable {
        case none
        case left
        case center
        case right
    }

    struct CellID: Hashable, Equatable {
        /// 0 是表头，1... 是数据行。
        let row: Int
        let column: Int
    }

    var headers: [String]
    var rows: [[String]]
    var alignments: [Alignment]

    init(source: String) {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let headerValues = lines.first.map(Self.cells(in:)) ?? []
        let delimiterValues = lines.dropFirst().first.map(Self.cells(in:)) ?? []
        let width = max(1, max(headerValues.count, delimiterValues.count))

        headers = Self.padded(headerValues, to: width)
        alignments = Self.padded(delimiterValues, to: width).map(Self.alignment(from:))
        rows = lines.dropFirst(2).map { Self.padded(Self.cells(in: $0), to: width) }
    }

    var columnCount: Int { max(1, headers.count) }
    var rowCountIncludingHeader: Int { rows.count + 1 }

    func value(at cell: CellID) -> String {
        guard cell.column >= 0, cell.column < columnCount else { return "" }
        if cell.row == 0 {
            return headers[cell.column]
        }
        let dataIndex = cell.row - 1
        guard rows.indices.contains(dataIndex) else { return "" }
        return rows[dataIndex][cell.column]
    }

    mutating func update(_ value: String, at cell: CellID) {
        guard cell.column >= 0, cell.column < columnCount else { return }
        if cell.row == 0 {
            headers[cell.column] = value
        } else if rows.indices.contains(cell.row - 1) {
            rows[cell.row - 1][cell.column] = value
        }
    }

    mutating func appendRow() {
        rows.append(Array(repeating: "", count: columnCount))
    }

    mutating func removeRow(at row: Int) {
        let dataIndex = row - 1
        guard rows.indices.contains(dataIndex) else { return }
        rows.remove(at: dataIndex)
    }

    mutating func appendColumn() {
        headers.append("")
        alignments.append(.none)
        for index in rows.indices { rows[index].append("") }
    }

    mutating func removeColumn(at column: Int) {
        guard columnCount > 1, headers.indices.contains(column) else { return }
        headers.remove(at: column)
        if alignments.indices.contains(column) { alignments.remove(at: column) }
        for index in rows.indices where rows[index].indices.contains(column) {
            rows[index].remove(at: column)
        }
    }

    /// 将用户已修改的模型写回表格块源码，不带块末尾换行。
    var serializedSource: String {
        let delimiter = alignments.map(Self.delimiter(for:))
        var lines = [rowLine(headers), rowLine(delimiter)]
        lines.append(contentsOf: rows.map(rowLine))
        return lines.joined(separator: "\n")
    }

    private func rowLine(_ values: [String]) -> String {
        "| " + values.map(escapeCell).joined(separator: " | ") + " |"
    }

    private func escapeCell(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value.replacingOccurrences(of: "\n", with: " ") {
            if character == "|", !escaped {
                result.append("\\|")
                escaped = false
            } else {
                result.append(character)
                escaped = character == "\\" && !escaped
            }
        }
        return result
    }

    private static func cells(in line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.first == "|" { value.removeFirst() }
        if value.last == "|" { value.removeLast() }

        var result: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "`" {
                inCode.toggle()
                current.append(character)
                continue
            }
            if character == "|", !inCode {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func alignment(from value: String) -> Alignment {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let starts = trimmed.hasPrefix(":")
        let ends = trimmed.hasSuffix(":")
        switch (starts, ends) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    private static func delimiter(for alignment: Alignment) -> String {
        switch alignment {
        case .none: return "---"
        case .left: return ":---"
        case .center: return ":---:"
        case .right: return "---:"
        }
    }

    private static func padded(_ values: [String], to count: Int) -> [String] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: "", count: count - values.count)
    }
}
