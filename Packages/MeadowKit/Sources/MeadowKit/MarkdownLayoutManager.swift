import AppKit

/// Hides syntax markers, draws task boxes, bullets, table grids, code block backgrounds,
/// quote bars, rules and block images.
public final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    public var theme: Theme = .moss
    public var checkboxWidth: CGFloat = 20
    public var quoteStep: CGFloat = 20
    private var bulletGlyphs: [NSFont: CGGlyph] = [:]

    public override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
        usesFontLeading = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Glyph generation

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>,
                              font aFont: NSFont,
                              forGlyphRange glyphRange: NSRange) -> Int {
        guard let ts = textStorage, glyphRange.length > 0 else { return 0 }
        let count = glyphRange.length
        let first = charIndexes[0]
        let last = charIndexes[count - 1]
        let charRange = NSRange(location: first, length: last - first + 1)
        var any = false
        ts.enumerateAttribute(.mdGlyph, in: charRange, options: [.longestEffectiveRangeNotRequired]) { v, _, stop in
            if v != nil { any = true; stop.pointee = true }
        }
        guard any else { return 0 }

        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProps = Array(UnsafeBufferPointer(start: props, count: count))
        var effective = NSRange(location: NSNotFound, length: 0)
        var current: Int?
        let str = ts.string as NSString
        for i in 0..<count {
            let ci = charIndexes[i]
            if effective.location == NSNotFound || !NSLocationInRange(ci, effective) {
                current = ts.attribute(.mdGlyph, at: ci, longestEffectiveRange: &effective, in: charRange) as? Int
            }
            guard let raw = current, let action = GlyphAction(rawValue: raw) else { continue }
            switch action {
            case .hidden:
                // A null glyph at the start of a line is attributed to the previous line fragment,
                // which breaks indents and drawing. Use a zero-width control glyph there instead.
                if ci == 0 || str.character(at: ci - 1) == 10 || str.character(at: ci - 1) == 13 {
                    newProps[i] = .controlCharacter
                } else {
                    newProps[i] = .null
                }
            case .bullet:
                newGlyphs[i] = bulletGlyph(aFont)
            case .checkbox, .pipe:
                newProps[i] = .controlCharacter
            }
        }
        newGlyphs.withUnsafeBufferPointer { g in
            newProps.withUnsafeBufferPointer { p in
                setGlyphs(g.baseAddress!, properties: p.baseAddress!, characterIndexes: charIndexes,
                          font: aFont, forGlyphRange: glyphRange)
            }
        }
        return count
    }

    private func bulletGlyph(_ font: NSFont) -> CGGlyph {
        if let g = bulletGlyphs[font] { return g }
        var chars: [UniChar] = [0x2022]
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyph, 1)
        bulletGlyphs[font] = glyph
        return glyph
    }

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldUse action: NSLayoutManager.ControlCharacterAction,
                              forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let raw = textStorage?.attribute(.mdGlyph, at: charIndex, effectiveRange: nil) as? Int,
           raw == GlyphAction.checkbox.rawValue || raw == GlyphAction.pipe.rawValue || raw == GlyphAction.hidden.rawValue {
            return .whitespace
        }
        return action
    }

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              boundingBoxForControlGlyphAt glyphIndex: Int,
                              for textContainer: NSTextContainer,
                              proposedLineFragment proposedRect: NSRect,
                              glyphPosition: NSPoint,
                              characterIndex charIndex: Int) -> NSRect {
        var width: CGFloat = 0
        if let ts = textStorage {
            if let target = ts.attribute(.mdPipe, at: charIndex, effectiveRange: nil) as? NSNumber {
                width = max(CGFloat(target.doubleValue) - glyphPosition.x, 6)
            } else if ts.attribute(.mdCheckbox, at: charIndex, effectiveRange: nil) != nil {
                width = checkboxWidth
            }
        }
        return NSRect(x: glyphPosition.x, y: 0, width: width, height: 1)
    }

    // MARK: Drawing

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let ts = textStorage, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawCodeBlocks(ts, container, charRange, origin)
            drawInlineCode(ts, container, charRange, origin)
            drawQuotes(ts, container, charRange, origin)
            drawLines(ts, container, charRange, origin)
            drawImages(ts, container, charRange, origin)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func lineRects(_ glyphRange: NSRange) -> NSRect {
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphRange) { r, _, _, _, _ in rect = rect.union(r) }
        return rect
    }

    private func drawCodeBlocks(_ ts: NSTextStorage, _ container: NSTextContainer, _ charRange: NSRange, _ origin: NSPoint) {
        var seen = Set<Int>()
        let whole = NSRange(location: 0, length: ts.length)
        ts.enumerateAttribute(.mdCodeBlock, in: charRange) { v, r, _ in
            guard v != nil else { return }
            var full = NSRange()
            _ = ts.attribute(.mdCodeBlock, at: r.location, longestEffectiveRange: &full, in: whole)
            guard seen.insert(full.location).inserted else { return }
            // Exclude the trailing newline so the block does not extend into the next line.
            var block = full
            let str = ts.string as NSString
            if block.length > 0, str.character(at: NSMaxRange(block) - 1) == 10 { block.length -= 1 }
            let gr = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            var rect = lineRects(gr)
            guard !rect.isNull else { return }
            let ps = ts.attribute(.paragraphStyle, at: full.location, effectiveRange: nil) as? NSParagraphStyle
            let indent = max(0, (ps?.firstLineHeadIndent ?? 12) - 12)
            rect.origin.x = indent
            rect.size.width = container.size.width - indent
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            theme.codeBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    private func drawInlineCode(_ ts: NSTextStorage, _ container: NSTextContainer, _ charRange: NSRange, _ origin: NSPoint) {
        ts.enumerateAttribute(.mdInlineCode, in: charRange) { v, r, _ in
            guard v != nil else { return }
            let gr = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let font = ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                var box = rect
                if let font {
                    // Hug the glyphs instead of the whole (tall) line.
                    let h = (font.ascender - font.descender) * 1.15
                    box.origin.y = rect.maxY - h - (rect.height - h) * 0.0
                    box.size.height = h
                    let lineRect = self.lineFragmentUsedRect(forGlyphAt: gr.location, effectiveRange: nil)
                    let baseline = lineRect.minY + self.location(forGlyphAt: gr.location).y
                    box.origin.y = baseline - font.ascender - (h - (font.ascender - font.descender)) / 2
                }
                box = box.insetBy(dx: -3, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                self.theme.codeBackground.setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    private func drawQuotes(_ ts: NSTextStorage, _ container: NSTextContainer, _ charRange: NSRange, _ origin: NSPoint) {
        ts.enumerateAttribute(.mdQuote, in: charRange) { v, r, _ in
            guard let depth = (v as? NSNumber)?.intValue, depth > 0 else { return }
            var rr = r
            let str = ts.string as NSString
            if rr.length > 1, str.character(at: NSMaxRange(rr) - 1) == 10 { rr.length -= 1 }
            let rect = lineRects(glyphRange(forCharacterRange: rr, actualCharacterRange: nil))
            guard !rect.isNull else { return }
            theme.rule.setFill()
            for d in 0..<depth {
                let bar = NSRect(x: CGFloat(d) * quoteStep + 1, y: rect.minY + 2, width: 3, height: rect.height - 4)
                NSBezierPath(roundedRect: bar.offsetBy(dx: origin.x, dy: origin.y), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    private func drawLines(_ ts: NSTextStorage, _ container: NSTextContainer, _ charRange: NSRange, _ origin: NSPoint) {
        ts.enumerateAttribute(.mdRule, in: charRange) { v, r, _ in
            guard v != nil else { return }
            let gr = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let rect = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            theme.rule.setFill()
            NSRect(x: rect.minX + origin.x, y: (rect.midY + origin.y).rounded() - 0.5, width: container.size.width, height: 1).fill()
        }
        ts.enumerateAttribute(.mdTableLine, in: charRange) { v, r, _ in
            guard let info = v as? MDTableLineInfo else { return }
            let gr = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let rect = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let y = info.strong ? rect.midY : rect.minY + 3
            (info.strong ? theme.rule : theme.rule.withAlphaComponent(0.5)).setFill()
            NSRect(x: info.indent + origin.x, y: (y + origin.y).rounded() - 0.5, width: info.width, height: 1).fill()
        }
    }

    private func drawImages(_ ts: NSTextStorage, _ container: NSTextContainer, _ charRange: NSRange, _ origin: NSPoint) {
        ts.enumerateAttribute(.mdImage, in: charRange) { v, r, _ in
            guard let info = v as? MDImageInfo else { return }
            let gr = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let rect = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let dest = NSRect(x: info.indent + origin.x, y: rect.minY + origin.y + 2,
                              width: info.size.width, height: info.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: dest, xRadius: 6, yRadius: 6).addClip()
            info.image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        ts.enumerateAttribute(.mdCheckbox, in: charRange) { v, r, _ in
            guard let checked = (v as? NSNumber)?.boolValue else { return }
            let gi = glyphIndexForCharacter(at: r.location)
            drawCheckbox(at: gi, checked: checked, font: ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont, origin: origin)
        }
    }

    /// Frame of the task box drawn for the glyph at `glyphIndex`, in container coordinates.
    public func checkboxRect(forGlyphAt glyphIndex: Int, font: NSFont?) -> NSRect {
        let line = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let loc = location(forGlyphAt: glyphIndex)
        let f = font ?? NSFont.systemFont(ofSize: 15)
        let d = (f.pointSize * 0.95).rounded()
        let baseline = line.minY + loc.y
        let centerY = baseline - f.capHeight / 2
        return NSRect(x: line.minX + loc.x + 1, y: (centerY - d / 2).rounded(), width: d, height: d)
    }

    private func drawCheckbox(at gi: Int, checked: Bool, font: NSFont?, origin: NSPoint) {
        let rect = checkboxRect(forGlyphAt: gi, font: font).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.75, dy: 0.75)
        let circle = NSBezierPath(ovalIn: rect)
        if checked {
            theme.accent.setFill()
            circle.fill()
            let check = NSBezierPath()
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.34))
            theme.background.setStroke()
            check.stroke()
        } else {
            circle.lineWidth = 1.3
            theme.secondary.setStroke()
            circle.stroke()
        }
    }
}
