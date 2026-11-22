import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// One source line of the document. Offsets are UTF-16 (NSString) offsets.
public struct MDLine {
    public enum Kind: UInt8 {
        case body, heading, setextUnderline, fence, code, tableHeader, tableDelimiter, tableRow, rule, html, image
    }

    /// Offset of the first character of the line.
    public var start: Int
    /// Offset just past the last content character (before the line terminator).
    public var end: Int
    /// Offset of the next line (after the terminator).
    public var next: Int
    public var kind: Kind = .body
    public var headingLevel: UInt8 = 0
    public var quoteDepth: UInt8 = 0
    /// Leaf block this line belongs to (`-1` for blank lines). Markers are revealed per leaf.
    public var leaf: Int32 = -1
    /// End of an always-hidden prefix (quote markers, task box). `-1` when the line has none.
    public var contentStart: Int = -1
    /// Index into `codeBlocks` or `tables`, depending on `kind`.
    public var block: Int32 = -1
    /// Visible width of the list marker that starts on this line, in characters of the base font.
    /// `0` when the line does not start a list item.
    public var markerKind: MarkerKind = .none

    public enum MarkerKind: UInt8 { case none, bullet, ordered, task }

    public var range: NSRange { NSRange(location: start, length: end - start) }
    public var fullRange: NSRange { NSRange(location: start, length: next - start) }
}

public struct MDSpan {
    public enum Kind {
        /// Syntax marker: hidden unless its leaf block is revealed, dimmed otherwise.
        case marker
        /// Always hidden (quote markers, the `- ` before a task box).
        case hidden
        /// Secondary color (ordered list numbers).
        case dim
        case strong, emphasis, strike
        /// Inline code content.
        case code
        case link(String)
        case imageAlt(String)
        /// `-`, `*` or `+` bullet, drawn as a dot.
        case bullet
        /// The `[` of a task box; the `x` and `]` are `.hidden`.
        case checkbox(Bool)
        /// Content of a checked task.
        case done
        /// A table pipe that opens column `n`; `-1` for leading and trailing pipes.
        case tablePipe(Int)
        /// Whitespace padding inside a table cell.
        case tablePad
        case html
    }

    public var range: NSRange
    public var kind: Kind
    public var leaf: Int32
}

public struct MDCodeBlock {
    public var language: String
    /// Line indices of the code itself (without fences).
    public var contentLines: Range<Int>
    public var firstLine: Int
    public var lastLine: Int
}

public struct MDTable {
    public struct Row {
        public var line: Int
        public var isHeader: Bool
        /// Trimmed content range of each cell.
        public var cells: [NSRange]
    }
    public var rows: [Row]
    public var firstLine: Int
    public var lastLine: Int
    public var columnCount: Int { rows.map(\.cells.count).max() ?? 0 }
}

/// Result of parsing a Markdown document into styling information.
public final class MarkdownAnalysis {
    public let length: Int
    public internal(set) var lines: [MDLine] = []
    /// Sorted by `range.location`.
    public internal(set) var spans: [MDSpan] = []
    /// Range of each leaf block (first line start to last line end), indexed by leaf id.
    public internal(set) var leafRanges: [NSRange] = []
    /// Line-aligned ranges of top-level blocks, in document order.
    public internal(set) var topBlocks: [NSRange] = []
    public internal(set) var codeBlocks: [MDCodeBlock] = []
    public internal(set) var tables: [MDTable] = []

    init(length: Int) { self.length = length }

    public static let empty = MarkdownAnalysis(length: 0)

    /// Index of the line containing `offset` (the last line for `offset == length`).
    public func lineIndex(at offset: Int) -> Int {
        var lo = 0, hi = lines.count - 1
        if hi < 0 { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Expands `range` to whole lines, including the terminator of the last line.
    public func lineAligned(_ range: NSRange) -> NSRange {
        guard !lines.isEmpty else { return NSRange(location: 0, length: length) }
        let first = lines[lineIndex(at: range.location)]
        let last = lines[lineIndex(at: max(range.location, NSMaxRange(range) - (range.length > 0 ? 1 : 0)))]
        return NSRange(location: first.start, length: last.next - first.start)
    }

    /// Index of the first span whose location is at or after `offset`.
    public func firstSpanIndex(atOrAfter offset: Int) -> Int {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].range.location < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Leaf ids intersecting `range`. A caret touching the end of a leaf counts as inside.
    public func leaves(touching range: NSRange) -> Set<Int32> {
        var result = Set<Int32>()
        guard !lines.isEmpty else { return result }
        let a = lineIndex(at: range.location)
        let b = lineIndex(at: NSMaxRange(range))
        for i in a...b where lines[i].leaf >= 0 { result.insert(lines[i].leaf) }
        return result
    }
}

// MARK: - Analyzer

public enum MarkdownAnalyzer {
    public static func analyze(_ text: String) -> MarkdownAnalysis {
        var builder = Builder(text: text)
        builder.run()
        return builder.result
    }
}

private let kNewline: UInt16 = 10, kReturn: UInt16 = 13, kSpace: UInt16 = 32, kTab: UInt16 = 9
private let kGreater: UInt16 = 62, kHash: UInt16 = 35, kPipe: UInt16 = 124, kBackslash: UInt16 = 92
private let kBacktick: UInt16 = 96, kTilde: UInt16 = 126, kLBracket: UInt16 = 91, kRBracket: UInt16 = 93
private let kBang: UInt16 = 33, kLess: UInt16 = 60, kEquals: UInt16 = 61, kDash: UInt16 = 45
private let kStar: UInt16 = 42, kPlus: UInt16 = 43, kUnderscore: UInt16 = 95

private struct Builder {
    let bytes: [UInt8]
    let u16: [UInt16]
    let result: MarkdownAnalysis
    var lineStart8: [Int] = []
    var lineAscii: [Bool] = []
    var nextLeaf: Int32 = 0

    init(text: String) {
        // Copy straight out of the (usually NSString-backed) storage: iterating a bridged
        // String's views is several times slower than these bulk copies.
        let ns = text as NSString
        let length = ns.length
        var units = [UInt16](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
        var utf8 = [UInt8]()
        if length > 0 {
            let cf = ns as CFString
            var needed: CFIndex = 0
            CFStringGetBytes(cf, CFRange(location: 0, length: length), CFStringBuiltInEncodings.UTF8.rawValue, 0x3F, false, nil, 0, &needed)
            utf8 = [UInt8](repeating: 0, count: needed)
            _ = utf8.withUnsafeMutableBufferPointer { buf in
                CFStringGetBytes(cf, CFRange(location: 0, length: length), CFStringBuiltInEncodings.UTF8.rawValue, 0x3F, false,
                                 buf.baseAddress, needed, nil)
            }
        }
        bytes = utf8
        u16 = units
        result = MarkdownAnalysis(length: length)
    }

    // MARK: Lines

    mutating func buildLines() {
        var lines: [MDLine] = []
        lines.reserveCapacity(u16.count / 30 + 1)
        var s16 = 0, i16 = 0, i8 = 0, s8 = 0
        var ascii = true
        let n8 = bytes.count
        while i8 < n8 {
            let b = bytes[i8]
            if b == 10 || b == 13 {
                let end16 = i16
                var nextB = i8 + 1
                if b == 13, nextB < n8, bytes[nextB] == 10 { nextB += 1 }
                let next16 = i16 + (nextB - i8)
                lines.append(MDLine(start: s16, end: end16, next: next16))
                lineStart8.append(s8); lineAscii.append(ascii)
                i16 = next16; i8 = nextB; s16 = i16; s8 = i8; ascii = true
                continue
            }
            if b < 0x80 { i16 += 1 } else {
                ascii = false
                if b >= 0xF0 { i16 += 2 } else if b >= 0xC0 { i16 += 1 }
            }
            i8 += 1
        }
        lines.append(MDLine(start: s16, end: i16, next: i16))
        lineStart8.append(s8); lineAscii.append(ascii)
        result.lines = lines
    }

    /// Converts a cmark 1-based (line, byte column) to a UTF-16 offset.
    func offset(line: Int32, column: Int32) -> Int {
        let li = min(max(Int(line) - 1, 0), result.lines.count - 1)
        let col = max(Int(column) - 1, 0)
        let ln = result.lines[li]
        if lineAscii[li] { return min(ln.start + col, ln.next) }
        var i8 = lineStart8[li], o = ln.start
        let stop = min(lineStart8[li] + col, bytes.count)
        while i8 < stop {
            let b = bytes[i8]
            if b < 0x80 || (b >= 0xC0 && b < 0xF0) { o += 1 } else if b >= 0xF0 { o += 2 }
            i8 += 1
        }
        return min(o, ln.next)
    }

    func startOffset(_ n: UnsafeMutablePointer<cmark_node>) -> Int {
        offset(line: cmark_node_get_start_line(n), column: cmark_node_get_start_column(n))
    }

    /// Exclusive end offset (cmark end columns are inclusive).
    func endOffset(_ n: UnsafeMutablePointer<cmark_node>) -> Int {
        offset(line: cmark_node_get_end_line(n), column: cmark_node_get_end_column(n) + 1)
    }

    func lineRange(_ n: UnsafeMutablePointer<cmark_node>) -> ClosedRange<Int> {
        let count = result.lines.count
        let a = min(max(Int(cmark_node_get_start_line(n)) - 1, 0), count - 1)
        let b = min(max(Int(cmark_node_get_end_line(n)) - 1, a), count - 1)
        return a...b
    }

    func char(_ i: Int) -> UInt16 { i >= 0 && i < u16.count ? u16[i] : 0 }

    mutating func span(_ loc: Int, _ end: Int, _ kind: MDSpan.Kind, _ leaf: Int32) {
        guard end > loc, loc >= 0, end <= u16.count else { return }
        result.spans.append(MDSpan(range: NSRange(location: loc, length: end - loc), kind: kind, leaf: leaf))
    }

    mutating func newLeaf(_ lines: ClosedRange<Int>) -> Int32 {
        let id = nextLeaf
        nextLeaf += 1
        for i in lines { result.lines[i].leaf = id }
        let r = NSRange(location: result.lines[lines.lowerBound].start,
                        length: result.lines[lines.upperBound].end - result.lines[lines.lowerBound].start)
        result.leafRanges.append(r)
        return id
    }

    // MARK: Run

    mutating func run() {
        buildLines()
        guard !bytes.isEmpty else { return }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return }
        for ext in ["table", "strikethrough", "tasklist"] {
            if let e = cmark_find_syntax_extension(ext) { cmark_parser_attach_syntax_extension(parser, e) }
        }
        bytes.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                cmark_parser_feed(parser, $0, bytes.count)
            }
        }
        guard let root = cmark_parser_finish(parser) else { cmark_parser_free(parser); return }
        var child = cmark_node_first_child(root)
        while let c = child {
            guard let lr = block(c, quoteDepth: 0) else { child = cmark_node_next(c); continue }
            let first = result.lines[lr.lowerBound], last = result.lines[lr.upperBound]
            result.topBlocks.append(NSRange(location: first.start, length: last.next - first.start))
            child = cmark_node_next(c)
        }
        cmark_node_free(root)
        cmark_parser_free(parser)
        finishQuotes()
        result.spans.sort { $0.range.location < $1.range.location }
    }

    // MARK: Blocks

    /// Walks a block node; returns the (corrected) line range it covers.
    @discardableResult
    mutating func block(_ n: UnsafeMutablePointer<cmark_node>, quoteDepth: UInt8) -> ClosedRange<Int>? {
        // cmark leaves some nodes without positions (e.g. what remains of a paragraph after a
        // table took its last line); there is nothing reliable to style for them.
        guard cmark_node_get_start_line(n) > 0, cmark_node_get_end_line(n) > 0 else { return nil }
        var lr = lineRange(n)
        let type = cmark_node_get_type(n)
        switch type {
        case CMARK_NODE_BLOCK_QUOTE:
            for i in lr { result.lines[i].quoteDepth = max(result.lines[i].quoteDepth, quoteDepth + 1) }
            if let c = children(n, quoteDepth: quoteDepth + 1) { lr = min(lr.lowerBound, c.lowerBound)...max(lr.upperBound, c.upperBound) }
        case CMARK_NODE_ITEM:
            listItem(n)
            if let c = children(n, quoteDepth: quoteDepth) { lr = min(lr.lowerBound, c.lowerBound)...max(lr.upperBound, c.upperBound) }
        case CMARK_NODE_PARAGRAPH:
            let leaf = newLeaf(lr)
            // Reset: cmark sometimes reports a preceding code block ending on these lines.
            let image = isBlockImage(n)
            for i in lr {
                result.lines[i].kind = image ? .image : .body
                result.lines[i].block = -1
            }
            inlines(n, leaf: leaf)
            autolinks(in: lr, leaf: leaf)
        case CMARK_NODE_HEADING:
            lr = heading(n, lr)
        case CMARK_NODE_CODE_BLOCK:
            codeBlock(n, lr)
        case CMARK_NODE_HTML_BLOCK:
            let leaf = newLeaf(lr)
            for i in lr {
                result.lines[i].block = -1
                result.lines[i].kind = .html
                span(result.lines[i].start, result.lines[i].end, .html, leaf)
            }
        case CMARK_NODE_THEMATIC_BREAK:
            let leaf = newLeaf(lr)
            let ln = result.lines[lr.lowerBound]
            result.lines[lr.lowerBound].kind = .rule
            result.lines[lr.lowerBound].block = -1
            var s = startOffset(n)
            while s < ln.end, char(s) == kSpace || char(s) == kGreater { s += 1 }
            span(s, ln.end, .marker, leaf)
        default:
            let name = String(cString: cmark_node_get_type_string(n))
            if name == "table" {
                lr = table(n, lr)
            } else if let c = children(n, quoteDepth: quoteDepth) {
                lr = min(lr.lowerBound, c.lowerBound)...max(lr.upperBound, c.upperBound)
            }
        }
        return lr
    }

    /// Walks child blocks; returns the union of their line ranges (cmark parents can be shorter than children).
    @discardableResult
    mutating func children(_ n: UnsafeMutablePointer<cmark_node>, quoteDepth: UInt8) -> ClosedRange<Int>? {
        var c = cmark_node_first_child(n)
        var union: ClosedRange<Int>?
        while let ch = c {
            if let r = block(ch, quoteDepth: quoteDepth) {
                union = union.map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r
            }
            c = cmark_node_next(ch)
        }
        return union
    }

    func isBlockImage(_ n: UnsafeMutablePointer<cmark_node>) -> Bool {
        guard let c = cmark_node_first_child(n), cmark_node_next(c) == nil else { return false }
        return cmark_node_get_type(c) == CMARK_NODE_IMAGE
    }

    mutating func listItem(_ n: UnsafeMutablePointer<cmark_node>) {
        var p = startOffset(n)
        let li = result.lineIndex(at: p)
        let ln = result.lines[li]
        while p < ln.end, char(p) == kSpace || char(p) == kTab { p += 1 }
        let c = char(p)
        let leafPlaceholder: Int32 = -1
        if c == kDash || c == kStar || c == kPlus {
            let markerEnd = p + 1
            var q = markerEnd
            while q < ln.end, char(q) == kSpace { q += 1 }
            // Detected textually: cmark-gfm misses task items inside block quotes.
            let state = char(q + 1)
            let isTask = q > markerEnd && char(q) == kLBracket && char(q + 2) == kRBracket
                && (state == kSpace || state == 120 || state == 88)
                && (q + 3 >= ln.end || char(q + 3) == kSpace || char(q + 3) == kTab)
            if isTask {
                let checked = state != kSpace
                span(p, q, .hidden, leafPlaceholder)
                span(q, q + 1, .checkbox(checked), leafPlaceholder)
                span(q + 1, q + 3, .hidden, leafPlaceholder)
                var content = q + 3
                if char(content) == kSpace { content += 1 }
                result.lines[li].contentStart = content
                result.lines[li].markerKind = .task
                if checked {
                    let end = endOffset(n)
                    span(content, max(content, min(end, u16.count)), .done, leafPlaceholder)
                }
            } else {
                span(p, markerEnd, .bullet, leafPlaceholder)
                result.lines[li].markerKind = .bullet
            }
        } else {
            var q = p
            while q < ln.end, char(q) >= 48, char(q) <= 57 { q += 1 }
            if q > p, q < ln.end, char(q) == 46 || char(q) == 41 {
                span(p, q + 1, .dim, leafPlaceholder)
                result.lines[li].markerKind = .ordered
            }
        }
    }

    mutating func heading(_ n: UnsafeMutablePointer<cmark_node>, _ lr0: ClosedRange<Int>) -> ClosedRange<Int> {
        let level = UInt8(cmark_node_get_heading_level(n))
        var p = startOffset(n)
        let first = lr0.lowerBound
        let ln = result.lines[first]
        while p < ln.end, char(p) == kSpace { p += 1 }
        if char(p) == kHash {
            let lr = first...first
            let leaf = newLeaf(lr)
            result.lines[first].kind = .heading
            result.lines[first].headingLevel = level
            result.lines[first].block = -1
            var q = p
            while q < ln.end, char(q) == kHash { q += 1 }
            while q < ln.end, char(q) == kSpace || char(q) == kTab { q += 1 }
            span(p, q, .marker, leaf)
            // Optional closing sequence: " ##"
            var e = ln.end
            while e > q, char(e - 1) == kSpace { e -= 1 }
            var h = e
            while h > q, char(h - 1) == kHash { h -= 1 }
            if h < e, h > q, char(h - 1) == kSpace { span(h - 1, ln.end, .marker, leaf) }
            inlines(n, leaf: leaf)
            return lr
        }
        // Setext: find the underline (cmark's end line is unreliable here).
        var underline = first
        for i in first...min(first + 64, result.lines.count - 1) where i > first {
            if isSetextUnderline(i) { underline = i; break }
        }
        if underline == first { underline = min(first + 1, result.lines.count - 1) }
        let lr = first...underline
        let leaf = newLeaf(lr)
        result.lines[underline].block = -1
        for i in first..<underline {
            result.lines[i].block = -1
            result.lines[i].kind = .heading
            result.lines[i].headingLevel = level
        }
        result.lines[underline].kind = .setextUnderline
        let u = result.lines[underline]
        span(u.start, u.end, .marker, leaf)
        inlines(n, leaf: leaf)
        return lr
    }

    func isSetextUnderline(_ i: Int) -> Bool {
        let ln = result.lines[i]
        var p = ln.start
        while p < ln.end, char(p) == kSpace || char(p) == kGreater { p += 1 }
        let c = char(p)
        guard c == kEquals || c == kDash else { return false }
        while p < ln.end, char(p) == c { p += 1 }
        while p < ln.end, char(p) == kSpace { p += 1 }
        return p == ln.end
    }

    mutating func codeBlock(_ n: UnsafeMutablePointer<cmark_node>, _ lr: ClosedRange<Int>) {
        let leaf = newLeaf(lr)
        let index = Int32(result.codeBlocks.count)
        var length: Int32 = 0, off: Int32 = 0
        var fenceChar: CChar = 0
        let fenced = cmark_node_get_fenced(n, &length, &off, &fenceChar) != 0
        var info = ""
        if let i = cmark_node_get_fence_info(n) { info = String(cString: i) }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "{" }).first.map(String.init) ?? ""
        var content = lr.lowerBound..<(lr.upperBound + 1)
        if fenced {
            content = (lr.lowerBound + 1)..<(lr.upperBound + 1)
            result.lines[lr.lowerBound].kind = .fence
            let open = result.lines[lr.lowerBound]
            span(open.start, open.end, .marker, leaf)
            if lr.upperBound > lr.lowerBound, isClosingFence(lr.upperBound, char: UInt16(UInt8(bitPattern: fenceChar)), length: Int(length)) {
                content = (lr.lowerBound + 1)..<lr.upperBound
                result.lines[lr.upperBound].kind = .fence
                let close = result.lines[lr.upperBound]
                span(close.start, close.end, .marker, leaf)
            }
        }
        for i in content { result.lines[i].kind = .code }
        for i in lr { result.lines[i].block = index }
        result.codeBlocks.append(MDCodeBlock(language: language.lowercased(), contentLines: content,
                                             firstLine: lr.lowerBound, lastLine: lr.upperBound))
    }

    func isClosingFence(_ i: Int, char c: UInt16, length: Int) -> Bool {
        let ln = result.lines[i]
        var p = ln.start
        while p < ln.end, char(p) == kSpace || char(p) == kGreater { p += 1 }
        var count = 0
        while p < ln.end, char(p) == c { p += 1; count += 1 }
        while p < ln.end, char(p) == kSpace { p += 1 }
        return count >= length && p == ln.end
    }

    func isDelimiterRow(_ i: Int) -> Bool {
        let ln = result.lines[i]
        var p = ln.start
        var dashes = 0
        while p < ln.end {
            let c = char(p)
            if c == kDash { dashes += 1 } else if c != kPipe && c != kSpace && c != 58 && c != kTab && c != kGreater { return false }
            p += 1
        }
        return dashes > 0
    }

    @discardableResult
    mutating func table(_ n: UnsafeMutablePointer<cmark_node>, _ lr0: ClosedRange<Int>) -> ClosedRange<Int> {
        // cmark's table start line can be off when the header was taken from a paragraph:
        // locate the delimiter row in the text instead.
        var header = lr0.lowerBound
        let searchEnd = min(lr0.upperBound + 1, result.lines.count - 1)
        if !(header + 1 <= searchEnd && isDelimiterRow(header + 1)) {
            for i in lr0.lowerBound...searchEnd where i > lr0.lowerBound && isDelimiterRow(i) { header = i - 1; break }
        }
        let end = max(header + 1, min(searchEnd, lr0.upperBound + (header - lr0.lowerBound)))
        var lastRow = header + 1
        while lastRow < end, result.lines[lastRow + 1].end > result.lines[lastRow + 1].start { lastRow += 1 }
        let lr = header...min(lastRow, result.lines.count - 1)
        if header > lr0.lowerBound {
            let before = lr0.lowerBound...(header - 1)
            _ = newLeaf(before)
            for i in before { result.lines[i].kind = .body; result.lines[i].block = -1 }
        }
        let leaf = newLeaf(lr)
        let index = Int32(result.tables.count)
        var rows: [MDTable.Row] = []
        for i in lr {
            result.lines[i].block = index
            let isDelimiter = i == lr.lowerBound + 1
            result.lines[i].kind = i == lr.lowerBound ? .tableHeader : (isDelimiter ? .tableDelimiter : .tableRow)
            let ln = result.lines[i]
            if isDelimiter {
                span(ln.start, ln.end, .marker, leaf)
                continue
            }
            // Split on unescaped pipes.
            var p = ln.start
            while p < ln.end, char(p) == kSpace || char(p) == kGreater { p += 1 }
            var pipes: [Int] = []
            var q = p
            var inCode = false
            while q < ln.end {
                let c = char(q)
                if c == kBackslash { q += 2; continue }
                if c == kBacktick { inCode.toggle() }
                if c == kPipe, !inCode { pipes.append(q) }
                q += 1
            }
            var e = ln.end
            while e > p, char(e - 1) == kSpace { e -= 1 }
            let leading = pipes.first == p
            let trailing = pipes.last.map { $0 == e - 1 } ?? false
            var cellStart = leading ? p + 1 : p
            var cells: [NSRange] = []
            var column = 0
            if leading { span(p, p + 1, .tablePipe(-1), leaf) }
            for (k, pipe) in pipes.enumerated() {
                if k == 0, leading { continue }
                cells.append(trimmedCell(cellStart, pipe, leaf: leaf))
                column += 1
                let isTrailing = trailing && k == pipes.count - 1
                span(pipe, pipe + 1, .tablePipe(isTrailing ? -1 : column), leaf)
                cellStart = pipe + 1
            }
            if !trailing, cellStart < e { cells.append(trimmedCell(cellStart, e, leaf: leaf)) }
            rows.append(MDTable.Row(line: i, isHeader: i == lr.lowerBound, cells: cells))
        }
        result.tables.append(MDTable(rows: rows, firstLine: lr.lowerBound, lastLine: lr.upperBound))
        // Inline formatting inside cells.
        var row = cmark_node_first_child(n)
        while let r = row {
            var cell = cmark_node_first_child(r)
            while let c = cell { inlines(c, leaf: leaf); cell = cmark_node_next(c) }
            row = cmark_node_next(r)
        }
        return lr0.lowerBound...lr.upperBound
    }

    mutating func trimmedCell(_ a: Int, _ b: Int, leaf: Int32) -> NSRange {
        var s = a, e = b
        while s < e, char(s) == kSpace || char(s) == kTab { s += 1 }
        while e > s, char(e - 1) == kSpace || char(e - 1) == kTab { e -= 1 }
        span(a, s, .tablePad, leaf)
        span(e, b, .tablePad, leaf)
        return NSRange(location: s, length: e - s)
    }

    /// Quote markers are hidden on every quoted line; the bar is drawn instead.
    mutating func finishQuotes() {
        for i in result.lines.indices where result.lines[i].quoteDepth > 0 {
            let ln = result.lines[i]
            var p = ln.start
            var found = 0
            while found < Int(ln.quoteDepth) {
                var q = p
                var spaces = 0
                while q < ln.end, char(q) == kSpace, spaces < 3 { q += 1; spaces += 1 }
                guard char(q) == kGreater, q < ln.end else { break }
                q += 1
                if char(q) == kSpace, q < ln.end { q += 1 }
                p = q
                found += 1
            }
            guard p > ln.start else { continue }
            span(ln.start, p, .hidden, -1)
            if result.lines[i].contentStart < 0 { result.lines[i].contentStart = p }
        }
    }

    // MARK: Inlines

    mutating func inlines(_ n: UnsafeMutablePointer<cmark_node>, leaf: Int32) {
        var c = cmark_node_first_child(n)
        while let ch = c {
            inline(ch, leaf: leaf)
            c = cmark_node_next(ch)
        }
    }

    /// Range of a node's children, or nil when it has none with positions.
    func childRange(_ n: UnsafeMutablePointer<cmark_node>) -> (Int, Int)? {
        guard let first = cmark_node_first_child(n), let last = cmark_node_last_child(n),
              cmark_node_get_start_line(first) > 0, cmark_node_get_end_line(last) > 0 else { return nil }
        return (startOffset(first), endOffset(last))
    }

    mutating func inline(_ n: UnsafeMutablePointer<cmark_node>, leaf: Int32) {
        guard cmark_node_get_start_line(n) > 0 else { return }
        let type = cmark_node_get_type(n)
        let s = startOffset(n), e = endOffset(n)
        switch type {
        case CMARK_NODE_EMPH, CMARK_NODE_STRONG:
            guard let (cs, ce) = childRange(n), cs > s, ce < e,
                  isAll(s, cs, [kStar, kUnderscore]), isAll(ce, e, [kStar, kUnderscore]) else {
                inlines(n, leaf: leaf); return
            }
            span(s, cs, .marker, leaf)
            span(ce, e, .marker, leaf)
            span(cs, ce, type == CMARK_NODE_STRONG ? .strong : .emphasis, leaf)
            inlines(n, leaf: leaf)
        case CMARK_NODE_CODE:
            // cmark reports the content; widen to the backticks (and the optional padding space).
            let count = Int(cmark_node_get_backtick_count(n))
            var a = s, b = e
            if char(a - 1) == kSpace, char(a - 2) == kBacktick { a -= 1 }
            if char(b) == kSpace, char(b + 1) == kBacktick { b += 1 }
            guard count > 0, isAll(a - count, a, [kBacktick]), isAll(b, b + count, [kBacktick]) else { return }
            span(a - count, s, .marker, leaf)
            span(e, b + count, .marker, leaf)
            span(s, e, .code, leaf)
        case CMARK_NODE_LINK, CMARK_NODE_IMAGE:
            let url = cmark_node_get_url(n).map { String(cString: $0) } ?? ""
            let isImage = type == CMARK_NODE_IMAGE
            let open = char(s)
            guard open == kLBracket || open == kLess || (isImage && open == kBang) else { return }
            if let (cs, ce) = childRange(n), cs > s, ce < e {
                span(s, cs, .marker, leaf)
                span(ce, e, .marker, leaf)
                span(cs, ce, isImage ? .imageAlt(url) : .link(url), leaf)
                if !isImage { inlines(n, leaf: leaf) }
            } else if open == kLess {
                span(s, s + 1, .marker, leaf)
                span(e - 1, e, .marker, leaf)
                span(s + 1, e - 1, .link(url), leaf)
            } else {
                span(s, e, .marker, leaf)
            }
        case CMARK_NODE_HTML_INLINE:
            span(s, e, .html, leaf)
        default:
            if String(cString: cmark_node_get_type_string(n)) == "strikethrough" {
                if let (cs, ce) = childRange(n), cs > s, ce < e, isAll(s, cs, [kTilde]), isAll(ce, e, [kTilde]) {
                    span(s, cs, .marker, leaf)
                    span(ce, e, .marker, leaf)
                    span(cs, ce, .strike, leaf)
                }
            }
            inlines(n, leaf: leaf)
        }
    }

    func isAll(_ a: Int, _ b: Int, _ set: [UInt16]) -> Bool {
        guard a < b else { return false }
        for i in a..<b where !set.contains(char(i)) { return false }
        return true
    }

    /// Bare `http(s)://` URLs (cmark's autolink extension reports wrong positions).
    mutating func autolinks(in lr: ClosedRange<Int>, leaf: Int32) {
        let h: UInt16 = 104, t: UInt16 = 116, p: UInt16 = 112, colon: UInt16 = 58, slash: UInt16 = 47
        for li in lr {
            let ln = result.lines[li]
            var i = ln.start
            while i + 8 < ln.end {
                guard char(i) == h, char(i + 1) == t, char(i + 2) == t, char(i + 3) == p,
                      i == ln.start || !isWordChar(char(i - 1)) && char(i - 1) != kLess && char(i - 1) != 40 else { i += 1; continue }
                var j = i + 4
                if char(j) == 115 { j += 1 }
                guard char(j) == colon, char(j + 1) == slash, char(j + 2) == slash else { i += 1; continue }
                var k = j + 3
                while k < ln.end, !isURLStop(char(k)) { k += 1 }
                while k > j + 3, [46, 44, 59, 58, 33, 63, 39, 34, 41].contains(char(k - 1)) { k -= 1 }
                if k > j + 3 {
                    let url = String(utf16CodeUnits: Array(u16[i..<k]), count: k - i)
                    // Skip URLs already inside a link or code span.
                    if !overlapsExisting(i, k) { span(i, k, .link(url), leaf) }
                }
                i = max(k, i + 1)
            }
        }
    }

    func isWordChar(_ c: UInt16) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    func isURLStop(_ c: UInt16) -> Bool { c == kSpace || c == kTab || c == kLess || c == kGreater || c == 34 || c == kBacktick }

    func overlapsExisting(_ a: Int, _ b: Int) -> Bool {
        for sp in result.spans.reversed() {
            if NSMaxRange(sp.range) <= a { if sp.range.location < a - 2000 { break } else { continue } }
            switch sp.kind {
            case .link, .code, .imageAlt, .html, .marker:
                if sp.range.location < b && NSMaxRange(sp.range) > a { return true }
            default: break
            }
        }
        return false
    }
}
