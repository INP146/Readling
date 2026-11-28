import UIKit

/// Lays out tables kept as text: one paragraph per row, a tab between cells (see `TableShape`).
///
/// TextKit on iOS has no table blocks (`NSTextTable` is AppKit only), and a table drawn as a picture would lose word
/// lookup, search and its links (Gutenberg tables of contents are tables of links). So the text stays text and the
/// layout is chosen for the width it is shown at, the way narrow screens show tables on the web:
/// - grid: when every cell but each row's last fits on one line, columns are tab stops at the widest cell of each
///   column; the last cell of a row may wrap and its lines hang under its column. Numeric columns align right.
/// - stacked: otherwise each cell starts a line of its own, later cells indented, rows set apart. The row's only tab
///   stop is at the end of the line, so each tab carries the next cell onto a new line at the hanging indent; TextKit
///   on iOS ignores line-break actions for tabs from `NSLayoutManagerDelegate` (it only drops their width).
enum ReaderTables {
    /// Tables bigger than this are stacked without measuring them.
    private static let maximumCells = 3_000

    private struct Cell {
        var range: NSRange
        var row: Int
        var column: Int
        var span: Int
        var isLast: Bool
        var width: CGFloat = 0
        var longestWord: CGFloat = 0
        var isMultiline = false
        var isNumeric = false
        var isEmpty: Bool { range.length == 0 }
    }

    static func apply(_ run: TextStyleRun, to result: NSMutableAttributedString, size: CGFloat, width: CGFloat?, base: NSParagraphStyle) {
        let text = result.string as NSString
        let shape = TableShape(run.value)
        var rows: [(range: NSRange, cells: [Cell])] = []
        var start = run.location
        let end = NSMaxRange(run.range)
        var cellCount = 0
        while start < end {
            let newline = text.range(of: "\n", range: NSRange(location: start, length: end - start))
            let rowEnd = newline.location == NSNotFound ? end : newline.location
            let row = rows.count
            var cells: [Cell] = []
            var cellStart = start
            var column = 0
            for index in start...rowEnd where index == rowEnd || text.character(at: index) == 0x09 {
                let span = shape.span(row: row, cell: cells.count)
                cells.append(Cell(range: NSRange(location: cellStart, length: index - cellStart), row: row, column: column, span: span, isLast: false))
                column += span
                cellStart = index + 1
            }
            cells[cells.count - 1].isLast = true
            cellCount += cells.count
            rows.append((NSRange(location: start, length: rowEnd - start), cells))
            start = rowEnd + 1
        }
        guard !rows.isEmpty else { return }
        let first = rows[0].range.location, last = NSMaxRange(rows[rows.count - 1].range)

        func style(_ row: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.setParagraphStyle(result.attribute(.paragraphStyle, at: row.location, effectiveRange: nil) as? NSParagraphStyle ?? base)
            paragraph.alignment = .left
            paragraph.hyphenationFactor = 0
            paragraph.paragraphSpacingBefore = row.location == first && first > 0 ? size * 0.5 : 0
            change(paragraph)
            if NSMaxRange(row) >= last { paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, base.paragraphSpacing, size * 0.6) }
            // The style covers the row's newline too, which is where TextKit reads it.
            result.addAttribute(.paragraphStyle, value: paragraph, range: text.paragraphRange(for: row))
        }

        if let width, cellCount <= maximumCells, let grid = grid(rows: rows.map(\.cells), in: result, size: size, width: width) {
            for row in rows {
                style(row.range) { paragraph in
                    paragraph.firstLineHeadIndent = 0
                    paragraph.headIndent = grid.x[row.cells[row.cells.count - 1].column]
                    paragraph.tabStops = row.cells.dropFirst().map { cell in
                        grid.numeric[cell.column] && cell.span == 1
                            ? NSTextTab(textAlignment: .right, location: grid.x[cell.column] + grid.widths[cell.column])
                            : NSTextTab(textAlignment: .left, location: grid.x[cell.column])
                    }
                    paragraph.defaultTabInterval = 0
                    paragraph.paragraphSpacing = size * 0.35
                }
            }
        } else {
            for row in rows {
                style(row.range) { paragraph in
                    paragraph.firstLineHeadIndent = 0
                    paragraph.headIndent = row.cells.count > 1 ? size * 1.2 : 0
                    paragraph.paragraphSpacing = size * 0.6
                    if let width {
                        // Just short of the edge: past it, TextKit would leave an empty line before the next cell.
                        let end = max(1, width - 1)
                        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: end)]
                        paragraph.defaultTabInterval = end
                    }
                }
            }
        }
    }

    /// Column positions for a grid, or nil when the table doesn't fit one at this width.
    private static func grid(rows: [[Cell]], in result: NSAttributedString, size: CGFloat, width: CGFloat) -> (x: [CGFloat], widths: [CGFloat], numeric: [Bool])? {
        let columns = rows.map { $0.last.map { $0.column + $0.span } ?? 0 }.max() ?? 0
        guard columns > 1 else { return ([0], [width], [false]) }
        var rows = rows
        for r in rows.indices {
            for c in rows[r].indices {
                measure(&rows[r][c], in: result)
                // Only a row's last cell may wrap.
                if !rows[r][c].isLast && rows[r][c].isMultiline { return nil }
            }
        }
        let cells = rows.flatMap { $0 }
        var numeric = [Bool](repeating: false, count: columns)
        // A first row above others is usually headings ("Cost" over prices), so it doesn't decide.
        let body = rows.count > 1 ? cells.filter { $0.row > 0 } : cells
        for column in 1..<columns {
            let own = body.filter { $0.column == column && $0.span == 1 && !$0.isEmpty }
            numeric[column] = !own.isEmpty && own.allSatisfy(\.isNumeric)
        }
        // Column widths come from cells that must stay on one line; a row's last cell takes what is left of the line.
        var widths = [CGFloat](repeating: 0, count: columns)
        for cell in cells where cell.span == 1 && (!cell.isLast || numeric[cell.column] || cell.column == columns - 1) {
            widths[cell.column] = max(widths[cell.column], cell.width)
        }
        let gap = size * 1.2
        for cell in cells where cell.span > 1 && !cell.isLast {
            let covered = (cell.column..<cell.column + cell.span).reduce(0) { $0 + widths[$1] } + gap * CGFloat(cell.span - 1)
            if covered < cell.width { widths[cell.column + cell.span - 1] += cell.width - covered }
        }
        var x = [CGFloat](repeating: 0, count: columns)
        for column in 1..<columns { x[column] = x[column - 1] + widths[column - 1] + gap }
        for cell in cells {
            let room = width - x[cell.column]
            if cell.isLast {
                // A wrapping cell needs room for its longest word, and enough not to read as a narrow strip.
                let needed = numeric[cell.column] && cell.span == 1 ? widths[cell.column] : min(cell.width, max(cell.longestWord, size * 5))
                if needed > room + 0.5 { return nil }
            } else {
                let span = (cell.column..<cell.column + cell.span).reduce(0) { $0 + widths[$1] } + gap * CGFloat(cell.span - 1)
                if cell.width > span + 0.5 || x[cell.column] + span > width + 0.5 { return nil }
            }
        }
        return (x, widths, numeric)
    }

    private static let numeral = try! NSRegularExpression(pattern: #"^[\s(]*[-+−–$€£¥]?\d[\d.,:/\s]*[%)]?\s*$|^\s*[ivxlcdm]+\.?\s*$"#, options: .caseInsensitive)

    private static func measure(_ cell: inout Cell, in result: NSAttributedString) {
        guard cell.range.length > 0 else { return }
        let string = (result.string as NSString).substring(with: cell.range)
        cell.isMultiline = string.contains(ChapterTextBuilder.lineSeparator)
        cell.isNumeric = numeral.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
        // Each line on its own, as a single unwrapped line; attachments are measured by what they draw.
        var widest: CGFloat = 0
        var location = cell.range.location
        for line in string.components(separatedBy: ChapterTextBuilder.lineSeparator) {
            let length = (line as NSString).length
            widest = max(widest, lineWidth(NSRange(location: location, length: length), in: result))
            location += length + 1
        }
        cell.width = ceil(widest)
        var longest: CGFloat = 0
        location = cell.range.location
        for word in string.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\u{2028}" }) {
            let length = (String(word) as NSString).length
            if length > 0 { longest = max(longest, lineWidth(NSRange(location: location, length: length), in: result)) }
            location += length + 1
        }
        cell.longestWord = ceil(longest)
    }

    private static func lineWidth(_ range: NSRange, in result: NSAttributedString) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let line = NSMutableAttributedString(attributedString: result.attributedSubstring(from: range))
        var attachments: CGFloat = 0
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length), options: .reverse) { value, part, _ in
            guard let value else { return }
            switch value {
            case let math as ReaderMathAttachment: attachments += math.naturalSize.width
            case let image as ReaderImageAttachment: attachments += ReaderImages.pixelSize(of: image.url)?.width ?? 0
            default: break
            }
            line.deleteCharacters(in: part)
        }
        let plain = NSMutableParagraphStyle()
        plain.lineBreakMode = .byClipping
        line.addAttribute(.paragraphStyle, value: plain, range: NSRange(location: 0, length: line.length))
        let bounds = line.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin], context: nil)
        return bounds.width + attachments
    }
}
