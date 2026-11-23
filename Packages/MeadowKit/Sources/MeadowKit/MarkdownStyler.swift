import AppKit

public extension NSAttributedString.Key {
    /// `GlyphAction` raw value: how the layout manager renders the character.
    static let mdGlyph = NSAttributedString.Key("md.glyph")
    /// `NSNumber(bool)` on the `[` of a task box.
    static let mdCheckbox = NSAttributedString.Key("md.checkbox")
    /// `NSNumber(double)`: x offset (from the line fragment origin) where the column after this pipe starts.
    static let mdPipe = NSAttributedString.Key("md.pipe")
    /// Marks list/quote prefix characters (used to compute hanging indents).
    static let mdPrefix = NSAttributedString.Key("md.prefix")
    /// `NSNumber(int)` identifying a fenced/indented code block (background is drawn per block).
    static let mdCodeBlock = NSAttributedString.Key("md.codeblock")
    /// `NSNumber(int)` quote depth.
    static let mdQuote = NSAttributedString.Key("md.quote")
    /// Horizontal rule line.
    static let mdRule = NSAttributedString.Key("md.rule")
    /// `MDTableLineInfo` on table rows that need a separator drawn under them.
    static let mdTableLine = NSAttributedString.Key("md.tableline")
    /// Inline code span (rounded background).
    static let mdInlineCode = NSAttributedString.Key("md.inlinecode")
    /// `String` URL of a link.
    static let mdLink = NSAttributedString.Key("md.link")
    /// `MDImageInfo` on the line of a block image.
    static let mdImage = NSAttributedString.Key("md.image")
}

public enum GlyphAction: Int {
    case hidden = 1, bullet = 2, checkbox = 3, pipe = 4
}

public final class MDTableLineInfo: NSObject {
    public let width: CGFloat
    public let indent: CGFloat
    public let strong: Bool
    init(width: CGFloat, indent: CGFloat, strong: Bool) {
        self.width = width; self.indent = indent; self.strong = strong
    }
}

public final class MDImageInfo: NSObject {
    public let image: NSImage
    public let size: NSSize
    public let indent: CGFloat
    init(image: NSImage, size: NSSize, indent: CGFloat) {
        self.image = image; self.size = size; self.indent = indent
    }
}

/// Turns a `MarkdownAnalysis` into text attributes.
public final class MarkdownStyler {
    public var style: EditorStyle { didSet { rebuildFonts() } }
    public private(set) var analysis: MarkdownAnalysis = .empty
    /// Leaf blocks whose syntax markers are visible (the ones under the caret).
    public var revealed: Set<Int32> = []
    /// Folder used to resolve relative image paths.
    public var baseURL: URL?
    /// Width available for text (used to scale images).
    public var contentWidth: CGFloat = 640
    /// Loads images for block-image lines; nil disables images.
    public var imageLoader: ImageLoader?
    /// When set, the text is source code in this language (e.g. "json"): no Markdown, just
    /// monospaced text with syntax highlighting.
    public var sourceLanguage: String?

    private(set) var baseFont: NSFont = .systemFont(ofSize: 15)
    private var codeFont: NSFont = .systemFont(ofSize: 15)
    private var headingFonts: [NSFont] = []
    private var spaceWidth: CGFloat = 8
    private var traitCache: [FontTraitKey: NSFont] = [:]
    public private(set) var checkboxWidth: CGFloat = 20
    private var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var bodyParagraph = NSParagraphStyle()

    public init(style: EditorStyle) {
        self.style = style
        rebuildFonts()
    }

    public var typingAttributes: [NSAttributedString.Key: Any] { baseAttributes }

    private func rebuildFonts() {
        baseFont = style.baseFont
        codeFont = style.codeFont
        let size = style.fontSize
        let scales: [CGFloat] = [1.6, 1.32, 1.15, 1.05, 1.0, 1.0]
        headingFonts = scales.map { scale in
            let f = NSFont(descriptor: baseFont.fontDescriptor, size: (size * scale).rounded()) ?? baseFont
            return NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        }
        spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
        checkboxWidth = max(spaceWidth * 2, (size * 1.05).rounded()) + spaceWidth * 0.5
        traitCache.removeAll()
        paragraphCache.removeAll()
        widthCache.removeAll()
        advanceCache.removeAll()
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = style.lineHeight
        bodyParagraph = ps
        baseAttributes = [.font: baseFont, .foregroundColor: style.theme.text, .paragraphStyle: ps]
    }

    public func reparse(_ text: String) {
        analysis = sourceLanguage == nil ? MarkdownAnalyzer.analyze(text) : MarkdownAnalyzer.lines(text)
    }

    /// Replaces the analysis without reparsing (used after an edit computes it).
    func setAnalysis(_ a: MarkdownAnalysis) { analysis = a }

    // MARK: - Apply

    /// Restyles `range` (expanded to whole lines). Call inside an editing transaction.
    public func apply(_ range0: NSRange, to storage: NSTextStorage) {
        let a = analysis
        guard storage.length == a.length else { return }
        guard a.length > 0 else { return }
        let range = a.lineAligned(range0)
        guard range.length > 0 else { return }
        storage.setAttributes(baseAttributes, range: range)

        // Style in ascending chunks of whole lines. NSAttributedString keeps attribute runs in an
        // array, so inserting runs in front of many existing ones is O(n) each; doing every pass
        // per chunk keeps the runs after the insertion point few (1 MB: 710 ms -> tens of ms).
        let firstLine = a.lineIndex(at: range.location)
        let lastLine = a.lineIndex(at: max(range.location, NSMaxRange(range) - 1))
        var chunkStart = firstLine
        while chunkStart <= lastLine {
            var chunkEnd = chunkStart
            var chars = 0
            while chunkEnd < lastLine, chars < 4096 {
                chars += a.lines[chunkEnd].next - a.lines[chunkEnd].start
                chunkEnd += 1
            }
            // Never split a code block or a table between chunks.
            let ln = a.lines[chunkEnd]
            if ln.block >= 0 {
                switch ln.kind {
                case .fence, .code:
                    if Int(ln.block) < a.codeBlocks.count { chunkEnd = max(chunkEnd, min(lastLine, a.codeBlocks[Int(ln.block)].lastLine)) }
                case .tableHeader, .tableDelimiter, .tableRow:
                    if Int(ln.block) < a.tables.count { chunkEnd = max(chunkEnd, min(lastLine, a.tables[Int(ln.block)].lastLine)) }
                default: break
                }
            }
            applyLines(chunkStart...chunkEnd, storage)
            chunkStart = chunkEnd + 1
        }
    }

    private func applyLines(_ lines: ClosedRange<Int>, _ storage: NSTextStorage) {
        let a = analysis
        let firstLine = lines.lowerBound, lastLine = lines.upperBound
        let range = NSRange(location: a.lines[firstLine].start, length: a.lines[lastLine].next - a.lines[firstLine].start)
        let theme = style.theme

        if let language = sourceLanguage {
            applySource(range, language: language, storage)
            for li in firstLine...lastLine { applyParagraphStyle(a.lines[li], storage) }
            return
        }

        // Line-level attributes.
        var touchedCode = Set<Int32>()
        for li in firstLine...lastLine {
            let ln = a.lines[li]
            let full = ln.fullRange
            if ln.quoteDepth > 0 { storage.addAttribute(.mdQuote, value: NSNumber(value: ln.quoteDepth), range: full) }
            switch ln.kind {
            case .heading:
                let f = headingFonts[Int(max(1, min(6, ln.headingLevel))) - 1]
                storage.addAttributes([.font: f, .foregroundColor: theme.heading], range: full)
            case .fence, .code:
                storage.addAttributes([.font: codeFont, .foregroundColor: theme.codeText,
                                       .mdCodeBlock: NSNumber(value: ln.block + 1)], range: full)
                if ln.kind == .code { touchedCode.insert(ln.block) }
            case .html:
                storage.addAttributes([.font: codeFont, .foregroundColor: theme.secondary], range: full)
            case .rule:
                if !isRevealed(ln.leaf) { storage.addAttribute(.mdRule, value: true, range: ln.range) }
            case .tableHeader:
                storage.addAttribute(.font, value: bold(baseFont), range: ln.range)
            default:
                break
            }
        }

        // Spans that start in these lines.
        var i = a.firstSpanIndex(atOrAfter: range.location)
        let end = NSMaxRange(range)
        while i < a.spans.count, a.spans[i].range.location < end {
            applySpan(a.spans[i], storage)
            i += 1
        }

        // Tables (chunks never split them; they are single leaves).
        var doneTables = Set<Int32>()
        for li in firstLine...lastLine {
            let ln = a.lines[li]
            if (ln.kind == .tableHeader || ln.kind == .tableRow || ln.kind == .tableDelimiter), ln.block >= 0,
               !doneTables.contains(ln.block) {
                doneTables.insert(ln.block)
                layoutTable(Int(ln.block), storage)
            }
        }

        // Syntax highlighting.
        for b in touchedCode where b >= 0 && Int(b) < a.codeBlocks.count {
            highlight(a.codeBlocks[Int(b)], storage)
        }

        if let loader = imageLoader { attachImages(in: range, storage, loader: loader) }

        // Paragraph styles last: they depend on the prefix attributes.
        for li in firstLine...lastLine {
            applyParagraphStyle(a.lines[li], storage)
        }
    }

    private func isRevealed(_ leaf: Int32) -> Bool { leaf >= 0 && revealed.contains(leaf) }

    private func applySpan(_ sp: MDSpan, _ s: NSTextStorage) {
        let r = sp.range
        let theme = style.theme
        switch sp.kind {
        case .marker:
            if isRevealed(sp.leaf) {
                s.addAttribute(.foregroundColor, value: theme.secondary, range: r)
            } else {
                s.addAttribute(.mdGlyph, value: GlyphAction.hidden.rawValue, range: r)
            }
        case .hidden:
            s.addAttributes([.mdGlyph: GlyphAction.hidden.rawValue, .mdPrefix: true], range: r)
        case .dim:
            s.addAttributes([.foregroundColor: theme.secondary, .mdPrefix: true], range: r)
        case .strong:
            convertFonts(in: r, s, trait: .boldFontMask)
        case .emphasis:
            convertFonts(in: r, s, trait: .italicFontMask)
        case .strike:
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                             .foregroundColor: theme.secondary], range: r)
        case .code:
            let size = (s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)?.pointSize ?? style.fontSize
            let f = size == codeFont.pointSize ? codeFont : (NSFont(descriptor: codeFont.fontDescriptor, size: size) ?? codeFont)
            s.addAttributes([.font: f, .foregroundColor: theme.codeText, .mdInlineCode: true], range: r)
        case .link(let url):
            s.addAttributes([.foregroundColor: theme.accent, .mdLink: url,
                             .underlineStyle: NSUnderlineStyle.single.rawValue,
                             .underlineColor: theme.accent.withAlphaComponent(0.35)], range: r)
        case .imageAlt(let url):
            s.addAttributes([.foregroundColor: theme.secondary, .mdLink: url], range: r)
            convertFonts(in: r, s, trait: .italicFontMask)
        case .bullet:
            s.addAttributes([.mdGlyph: GlyphAction.bullet.rawValue, .mdPrefix: true,
                             .foregroundColor: theme.secondary], range: r)
        case .checkbox(let checked):
            s.addAttributes([.mdGlyph: GlyphAction.checkbox.rawValue, .mdPrefix: true,
                             .mdCheckbox: NSNumber(value: checked)], range: r)
        case .done:
            s.addAttributes([.foregroundColor: theme.secondary,
                             .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                             .strikethroughColor: theme.secondary.withAlphaComponent(0.6)], range: r)
        case .tablePipe(let column):
            if isRevealed(sp.leaf) {
                s.addAttribute(.foregroundColor, value: theme.secondary, range: r)
            } else if column < 0 {
                s.addAttribute(.mdGlyph, value: GlyphAction.hidden.rawValue, range: r)
            } else {
                s.addAttribute(.mdGlyph, value: GlyphAction.pipe.rawValue, range: r)
            }
        case .tablePad:
            if !isRevealed(sp.leaf) { s.addAttribute(.mdGlyph, value: GlyphAction.hidden.rawValue, range: r) }
        case .html:
            s.addAttribute(.foregroundColor, value: theme.secondary, range: r)
        }
    }

    // MARK: Fonts

    private struct FontTraitKey: Hashable { let font: NSFont; let trait: UInt }

    private func bold(_ f: NSFont) -> NSFont { converted(f, .boldFontMask) }

    private func converted(_ f: NSFont, _ trait: NSFontTraitMask) -> NSFont {
        let key = FontTraitKey(font: f, trait: trait.rawValue)
        if let c = traitCache[key] { return c }
        var c = NSFontManager.shared.convert(f, toHaveTrait: trait)
        if trait == .italicFontMask, !NSFontManager.shared.traits(of: c).contains(.italicFontMask) {
            // Fonts without an italic face: synthesize an oblique.
            let matrix = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
            c = NSFont(descriptor: f.fontDescriptor.withMatrix(matrix), size: f.pointSize) ?? f
        }
        traitCache[key] = c
        return c
    }

    private func convertFonts(in r: NSRange, _ s: NSTextStorage, trait: NSFontTraitMask) {
        s.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let f = value as? NSFont else { return }
            s.addAttribute(.font, value: converted(f, trait), range: sub)
        }
    }

    // MARK: Paragraphs

    /// Horizontal space taken by one level of block quote.
    public var quoteStep: CGFloat { spaceWidth * 2 + 4 }

    private func quoteIndent(_ depth: UInt8) -> CGFloat { CGFloat(depth) * quoteStep }

    /// Everything that determines a line's paragraph style; equal keys share one style object
    /// (fewer allocations, and equal neighbours merge into one attribute run).
    private struct ParagraphKey: Hashable {
        var kind: MDLine.Kind
        var level: UInt8
        var quote: UInt8
        var indent: CGFloat
        var revealed: Bool
        var blank: Bool
        var imageHeight: CGFloat
    }

    private var paragraphCache: [ParagraphKey: NSParagraphStyle] = [:]

    private func applyParagraphStyle(_ ln: MDLine, _ s: NSTextStorage) {
        let revealedLeaf = isRevealed(ln.leaf)
        var key = ParagraphKey(kind: ln.kind, level: ln.headingLevel, quote: ln.quoteDepth, indent: 0,
                               revealed: false, blank: ln.end == ln.start, imageHeight: 0)
        switch ln.kind {
        case .fence, .setextUnderline, .tableDelimiter: key.revealed = revealedLeaf
        case .body: key.revealed = key.blank && revealedLeaf
        default: break
        }
        if ln.kind == .body || ln.kind == .heading || ln.kind == .image {
            key.indent = prefixWidth(ln, s)
        }
        if ln.kind == .image, let info = s.attribute(.mdImage, at: ln.start, effectiveRange: nil) as? MDImageInfo {
            key.imageHeight = info.size.height
        }
        let ps: NSParagraphStyle
        if let cached = paragraphCache[key] {
            ps = cached
        } else {
            ps = makeParagraphStyle(key)
            paragraphCache[key] = ps
        }
        s.addAttribute(.paragraphStyle, value: ps, range: ln.fullRange)
    }

    /// Width of the visible line prefix (indentation, bullets, task boxes) for the hanging indent.
    private func prefixWidth(_ ln: MDLine, _ s: NSTextStorage) -> CGFloat {
        guard ln.end > ln.start else { return 0 }
        let str = s.string as NSString
        let first = str.character(at: ln.start)
        // Fast path for ordinary lines: no leading whitespace and no marker.
        if first != 32, first != 9, s.attribute(.mdPrefix, at: ln.start, effectiveRange: nil) == nil,
           s.attribute(.mdGlyph, at: ln.start, effectiveRange: nil) == nil {
            return 0
        }
        var x: CGFloat = 0
        var p = ln.start
        var runStart = -1
        func flushRun(_ upTo: Int) {
            if runStart >= 0, upTo > runStart {
                let sub = str.substring(with: NSRange(location: runStart, length: upTo - runStart))
                let f = (s.attribute(.font, at: runStart, effectiveRange: nil) as? NSFont) ?? baseFont
                x += width(of: sub, font: f)
            }
            runStart = -1
        }
        while p < ln.end {
            let c = str.character(at: p)
            let action = (s.attribute(.mdGlyph, at: p, effectiveRange: nil) as? Int).flatMap(GlyphAction.init)
            let isPrefix = s.attribute(.mdPrefix, at: p, effectiveRange: nil) != nil
            if action == .hidden { flushRun(p); p += 1; continue }
            if action == .checkbox { flushRun(p); x += checkboxWidth; p += 1; continue }
            if isPrefix || c == 32 || c == 9 {
                if runStart < 0 { runStart = p }
                p += 1
                continue
            }
            break
        }
        flushRun(p)
        return x
    }

    private func makeParagraphStyle(_ key: ParagraphKey) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.setParagraphStyle(bodyParagraph)
        let qi = quoteIndent(key.quote)
        ps.firstLineHeadIndent = qi
        ps.headIndent = qi + key.indent
        switch key.kind {
        case .heading:
            ps.lineHeightMultiple = 1.2
            ps.paragraphSpacingBefore = style.fontSize * (key.level <= 2 ? 0.7 : 0.4)
        case .fence:
            ps.firstLineHeadIndent = qi + 12
            ps.headIndent = qi + 12
            ps.lineHeightMultiple = 1.2
            if !key.revealed { collapse(ps, to: style.fontSize * 0.55) }
        case .code:
            ps.firstLineHeadIndent = qi + 12
            ps.headIndent = qi + 12
            ps.tailIndent = -12
            ps.lineHeightMultiple = 1.3
        case .setextUnderline:
            if !key.revealed { collapse(ps, to: 2) }
        case .tableDelimiter:
            if !key.revealed { collapse(ps, to: style.fontSize * 0.5) }
        case .tableHeader, .tableRow:
            ps.lineHeightMultiple = max(1.4, style.lineHeight)
        case .rule:
            break
        case .image:
            if key.imageHeight > 0 { ps.paragraphSpacingBefore = key.imageHeight + 6 }
        default:
            // Blank lines separate blocks; keep them shorter than text lines.
            if key.blank, !key.revealed { collapse(ps, to: (style.fontSize * style.lineHeight * 0.7).rounded()) }
        }
        return ps.copy() as! NSParagraphStyle
    }

    // MARK: Text measurement

    private struct WidthKey: Hashable { let text: String; let font: NSFont }
    private var widthCache: [WidthKey: CGFloat] = [:]
    private var advanceCache: [NSFont: CGFloat] = [:]

    /// Width of `text` in `font`; ASCII in a fixed-pitch font is computed from the advance.
    private func width(of text: String, font: NSFont) -> CGFloat {
        if font.isFixedPitch, text.utf16.allSatisfy({ $0 < 0x80 && $0 != 9 }) {
            let advance: CGFloat
            if let a = advanceCache[font] { advance = a } else {
                advance = ("0" as NSString).size(withAttributes: [.font: font]).width
                advanceCache[font] = advance
            }
            return advance * CGFloat(text.utf16.count)
        }
        let key = WidthKey(text: text, font: font)
        if let w = widthCache[key] { return w }
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        if widthCache.count > 4096 { widthCache.removeAll() }
        widthCache[key] = w
        return w
    }

    private func collapse(_ ps: NSMutableParagraphStyle, to height: CGFloat) {
        ps.lineHeightMultiple = 0
        ps.minimumLineHeight = height
        ps.maximumLineHeight = height
        ps.paragraphSpacing = 0
        ps.paragraphSpacingBefore = 0
    }

    // MARK: Tables

    private func layoutTable(_ index: Int, _ s: NSTextStorage) {
        let a = analysis
        guard index < a.tables.count else { return }
        let table = a.tables[index]
        let leaf = a.lines[table.firstLine].leaf
        let str = s.string as NSString
        let qi = quoteIndent(a.lines[table.firstLine].quoteDepth)
        let columns = table.columnCount
        guard columns > 0 else { return }
        var widths = [CGFloat](repeating: spaceWidth * 3, count: columns)
        for row in table.rows {
            for (c, cell) in row.cells.enumerated() where c < columns && cell.length > 0 {
                let w = measureVisible(cell, s, str)
                widths[c] = max(widths[c], w)
            }
        }
        let gap = spaceWidth * 3
        var starts = [CGFloat](repeating: 0, count: columns + 1)
        for c in 1...columns { starts[c] = starts[c - 1] + widths[c - 1] + gap }
        let total = starts[columns] - gap
        if isRevealed(leaf) { return }

        for li in table.firstLine...table.lastLine {
            let ln = a.lines[li]
            var i = a.firstSpanIndex(atOrAfter: ln.start)
            while i < a.spans.count, a.spans[i].range.location < ln.end {
                if case .tablePipe(let c) = a.spans[i].kind, c > 0, c <= columns {
                    s.addAttribute(.mdPipe, value: NSNumber(value: Double(qi + starts[c])), range: a.spans[i].range)
                }
                i += 1
            }
            if ln.kind == .tableDelimiter {
                s.addAttribute(.mdTableLine, value: MDTableLineInfo(width: total, indent: qi, strong: true), range: ln.range)
            } else if ln.kind == .tableRow, li > table.firstLine + 2 {
                s.addAttribute(.mdTableLine, value: MDTableLineInfo(width: total, indent: qi, strong: false), range: ln.range)
            }
        }
    }

    /// Width of a cell's visible text (hidden markers excluded).
    private func measureVisible(_ r: NSRange, _ s: NSTextStorage, _ str: NSString) -> CGFloat {
        var w: CGFloat = 0
        s.enumerateAttribute(.font, in: r) { value, fontRun, _ in
            let f = (value as? NSFont) ?? baseFont
            s.enumerateAttribute(.mdGlyph, in: fontRun) { glyph, sub, _ in
                if (glyph as? Int) == GlyphAction.hidden.rawValue { return }
                w += width(of: str.substring(with: sub), font: f)
            }
        }
        return ceil(w)
    }

    // MARK: Code

    /// Source files: whole lines in the code font, highlighted line by line. Tokens never span
    /// lines in JSON (strings can't hold newlines), so restyling only the edited lines stays exact;
    /// a `/* */` comment across lines in JSONC is the one case that may color a bit late.
    private func applySource(_ r: NSRange, language: String, _ s: NSTextStorage) {
        s.addAttribute(.font, value: codeFont, range: r)
        guard r.length > 0 else { return }
        let code = (s.string as NSString).substring(with: r)
        let colors = style.theme.syntax
        for token in SyntaxHighlighter.tokens(in: code, language: language) {
            let tr = NSRange(location: r.location + token.range.location, length: token.range.length)
            guard NSMaxRange(tr) <= NSMaxRange(r) else { continue }
            s.addAttribute(.foregroundColor, value: color(for: token.kind, colors), range: tr)
        }
    }

    private func color(for kind: CodeToken.Kind, _ colors: Theme.SyntaxColors) -> NSColor {
        switch kind {
        case .keyword: return colors.keyword
        case .string: return colors.string
        case .comment: return colors.comment
        case .number: return colors.number
        case .type: return colors.type
        case .function: return colors.function
        }
    }

    private func highlight(_ block: MDCodeBlock, _ s: NSTextStorage) {
        let a = analysis
        guard !block.contentLines.isEmpty, !block.language.isEmpty else { return }
        let first = a.lines[block.contentLines.lowerBound]
        // Only lines that are still code (a later block may have claimed cmark's overshoot).
        var lastIndex = block.contentLines.lowerBound
        while lastIndex + 1 < block.contentLines.upperBound, a.lines[lastIndex + 1].kind == .code,
              a.lines[lastIndex + 1].block == first.block { lastIndex += 1 }
        let last = a.lines[lastIndex]
        let r = NSRange(location: first.start, length: last.end - first.start)
        guard r.length > 0 else { return }
        let code = (s.string as NSString).substring(with: r)
        let colors = style.theme.syntax
        for token in SyntaxHighlighter.tokens(in: code, language: block.language) {
            let tr = NSRange(location: r.location + token.range.location, length: token.range.length)
            guard NSMaxRange(tr) <= NSMaxRange(r) else { continue }
            s.addAttribute(.foregroundColor, value: color(for: token.kind, colors), range: tr)
        }
    }

    // MARK: Images

    /// Attaches loaded images to block-image lines in `range`. Returns true if any image is still loading.
    @discardableResult
    private func attachImages(in range: NSRange, _ s: NSTextStorage, loader: ImageLoader) -> Bool {
        let a = analysis
        guard a.length == s.length, a.length > 0 else { return false }
        var pending = false
        let firstLine = a.lineIndex(at: range.location)
        let lastLine = a.lineIndex(at: max(range.location, NSMaxRange(range) - 1))
        for li in firstLine...lastLine where a.lines[li].kind == .image {
            let ln = a.lines[li]
            var i = a.firstSpanIndex(atOrAfter: ln.start)
            var src: String?
            while i < a.spans.count, a.spans[i].range.location < ln.end {
                if case .imageAlt(let u) = a.spans[i].kind { src = u; break }
                i += 1
            }
            guard let src, let url = ImageLoader.resolve(src, base: baseURL) else { continue }
            if let image = loader.image(for: url) {
                let qi = quoteIndent(ln.quoteDepth)
                let maxW = max(40, contentWidth - qi)
                var size = image.size
                if size.width > maxW { size = NSSize(width: maxW, height: (size.height * maxW / size.width).rounded()) }
                size.height = min(size.height, 900)
                s.addAttribute(.mdImage, value: MDImageInfo(image: image, size: size, indent: qi), range: ln.range)
            } else {
                pending = true
            }
        }
        return pending
    }
}
