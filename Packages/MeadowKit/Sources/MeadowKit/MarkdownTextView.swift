import AppKit

/// Live-preview Markdown editor. The text storage always holds the raw Markdown;
/// syntax markers are hidden everywhere except in the blocks under the selection.
open class MarkdownTextView: NSTextView, NSTextStorageDelegate {
    public let styler: MarkdownStyler
    public let markdownLayoutManager: MarkdownLayoutManager
    /// Read-only rendering (Quick Look): markers are never revealed and links open on click.
    public var isPreview = false {
        didSet { isEditable = !isPreview; updateReveal() }
    }
    /// Called when a link is clicked (Cmd-click while editing). Defaults to opening it with NSWorkspace.
    public var openLink: ((URL) -> Void)?

    public var style: EditorStyle {
        get { styler.style }
        set {
            guard newValue != styler.style else { return }
            styler.style = newValue
            applyAppearance()
            restyleAll()
        }
    }

    /// Folder for resolving relative links and images.
    public var baseURL: URL? {
        get { styler.baseURL }
        set { styler.baseURL = newValue }
    }

    public static func scrollable(style: EditorStyle = EditorStyle()) -> (NSScrollView, MarkdownTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let tv = MarkdownTextView(style: style)
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        scroll.documentView = tv
        return (scroll, tv)
    }

    public init(style: EditorStyle) {
        styler = MarkdownStyler(style: style)
        markdownLayoutManager = MarkdownLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(markdownLayoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        markdownLayoutManager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        storage.delegate = self

        let loader = ImageLoader()
        loader.onLoad = { [weak self] in self?.restyleImages() }
        styler.imageLoader = loader

        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFontPanel = false
        drawsBackground = true
        applyAppearance()
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("Use init(style:)")
    }

    private func applyAppearance() {
        let theme = styler.style.theme
        backgroundColor = theme.background
        insertionPointColor = theme.accent
        selectedTextAttributes = [.backgroundColor: theme.selection]
        typingAttributes = styler.typingAttributes
        markdownLayoutManager.theme = theme
        markdownLayoutManager.checkboxWidth = styler.checkboxWidth
        markdownLayoutManager.quoteStep = styler.quoteStep
        appearance = theme.appearance
        updateInsets()
    }

    // MARK: - Content

    /// The raw Markdown text.
    public var markdown: String {
        get { textStorage?.string ?? "" }
        set { setMarkdown(newValue) }
    }

    /// Replaces the whole document (not undoable) and moves the caret to the start.
    public func setMarkdown(_ text: String, selection: NSRange? = nil) {
        guard let ts = textStorage else { return }
        styler.revealed = []
        ts.beginEditing()
        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: text)
        ts.endEditing()
        undoManager?.removeAllActions(withTarget: ts)
        let sel = selection.map { NSRange(location: min($0.location, ts.length), length: 0) } ?? NSRange(location: 0, length: 0)
        setSelectedRange(sel)
        updateReveal()
    }

    /// Re-applies all attributes (after a style change).
    public func restyleAll() {
        guard let ts = textStorage else { return }
        ts.beginEditing()
        styler.apply(NSRange(location: 0, length: ts.length), to: ts)
        ts.endEditing()
    }

    private func restyleImages() {
        guard let ts = textStorage else { return }
        let a = styler.analysis
        ts.beginEditing()
        for ln in a.lines where ln.kind == .image { styler.apply(ln.fullRange, to: ts) }
        ts.endEditing()
    }

    // MARK: - Incremental styling

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let old = styler.analysis
        styler.reparse(textStorage.string)
        let new = styler.analysis

        // Start: earliest block (old or new) touching the edit. End: the first top-level block
        // boundary after the edit that exists in both parses; the text after it is unchanged,
        // so its styling is too.
        var dirty = editedRange
        let oldEnd = NSMaxRange(editedRange) - delta
        var oldStarts = Set<Int>()
        for b in old.topBlocks {
            if b.location <= oldEnd && NSMaxRange(b) >= editedRange.location {
                dirty = NSUnionRange(dirty, NSRange(location: min(b.location, editedRange.location), length: 0))
            }
            if b.location >= oldEnd { oldStarts.insert(b.location + delta) }
        }
        var minEnd = NSMaxRange(editedRange)
        for b in new.topBlocks where b.location <= NSMaxRange(editedRange) && NSMaxRange(b) >= editedRange.location {
            dirty = NSUnionRange(dirty, b)
            minEnd = max(minEnd, NSMaxRange(b))
        }
        var end = textStorage.length
        for b in new.topBlocks where b.location >= minEnd && oldStarts.contains(b.location) {
            end = b.location
            break
        }
        dirty = NSUnionRange(dirty, NSRange(location: dirty.location, length: max(0, end - dirty.location)))
        dirty = NSIntersectionRange(dirty, NSRange(location: 0, length: textStorage.length))
        if wantsReveal {
            styler.revealed = new.leaves(touching: editedRange)
        } else {
            styler.revealed = []
        }
        styler.apply(dirty, to: textStorage)
    }

    private var wantsReveal: Bool { !isPreview && window?.firstResponder === self }

    /// Shows markers in the leaf blocks under the selection and hides them elsewhere.
    public func updateReveal() {
        guard let ts = textStorage else { return }
        let a = styler.analysis
        guard a.length == ts.length else {
            DispatchQueue.main.async { [weak self] in self?.updateReveal() }
            return
        }
        var desired = Set<Int32>()
        if wantsReveal {
            for v in selectedRanges { desired.formUnion(a.leaves(touching: v.rangeValue)) }
        }
        guard desired != styler.revealed else { return }
        let changed = desired.symmetricDifference(styler.revealed)
        styler.revealed = desired
        ts.beginEditing()
        for leaf in changed where Int(leaf) < a.leafRanges.count {
            styler.apply(a.leafRanges[Int(leaf)], to: ts)
        }
        ts.endEditing()
    }

    open override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let previous = selectedRange()
        var ranges = ranges
        if ranges.count == 1, ranges[0].rangeValue.length == 0 {
            ranges = [NSValue(range: snapped(ranges[0].rangeValue.location, from: previous.location))]
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateReveal()
    }

    /// Keeps the caret out of always-hidden line prefixes (quote markers, task boxes).
    private func snapped(_ loc: Int, from old: Int) -> NSRange {
        let a = styler.analysis
        guard let ts = textStorage, a.length == ts.length, !a.lines.isEmpty else { return NSRange(location: loc, length: 0) }
        let ln = a.lines[a.lineIndex(at: loc)]
        guard ln.contentStart > ln.start, loc >= ln.start, loc < ln.contentStart else { return NSRange(location: loc, length: 0) }
        if old == ln.contentStart, loc < old {
            return NSRange(location: ln.start > 0 ? ln.start - 1 : ln.contentStart, length: 0)
        }
        return NSRange(location: ln.contentStart, length: 0)
    }

    open override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateReveal() }
        return ok
    }

    open override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateReveal() }
        return ok
    }

    // MARK: - Layout

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let width = bounds.width
        let maxWidth = styler.style.maxWidth
        let side = max(28, ((width - maxWidth) / 2).rounded(.down))
        let inset = NSSize(width: side, height: 36)
        if textContainerInset != inset {
            textContainerInset = inset
            let content = max(100, width - side * 2)
            if abs(styler.contentWidth - content) > 1 {
                styler.contentWidth = content
                if styler.analysis.lines.contains(where: { $0.kind == .image }) {
                    DispatchQueue.main.async { [weak self] in self?.restyleImages() }
                }
            }
        }
    }

    // MARK: - Mouse

    private func characterIndex(at event: NSEvent) -> (Int, NSPoint)? {
        guard let container = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        var p = convert(event.locationInWindow, from: nil)
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let gi = markdownLayoutManager.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let ci = markdownLayoutManager.characterIndexForGlyph(at: gi)
        return ci < ts.length ? (ci, p) : nil
    }

    private func checkbox(at event: NSEvent) -> Int? {
        guard let (ci, p) = characterIndex(at: event), let ts = textStorage else { return nil }
        for c in [ci, ci - 1, ci + 1] where c >= 0 && c < ts.length {
            guard ts.attribute(.mdCheckbox, at: c, effectiveRange: nil) != nil else { continue }
            let gi = markdownLayoutManager.glyphIndexForCharacter(at: c)
            let font = ts.attribute(.font, at: c, effectiveRange: nil) as? NSFont
            let rect = markdownLayoutManager.checkboxRect(forGlyphAt: gi, font: font).insetBy(dx: -4, dy: -4)
            if rect.contains(p) { return c }
        }
        return nil
    }

    private func link(at event: NSEvent) -> URL? {
        guard let (ci, p) = characterIndex(at: event), let ts = textStorage,
              let s = ts.attribute(.mdLink, at: ci, effectiveRange: nil) as? String else { return nil }
        let gi = markdownLayoutManager.glyphIndexForCharacter(at: ci)
        let rect = markdownLayoutManager.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: textContainer!)
        guard rect.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        if s.hasPrefix("#") { return nil }
        return ImageLoader.resolve(s, base: baseURL)
    }

    open override func mouseDown(with event: NSEvent) {
        if isEditable, event.clickCount == 1, let c = checkbox(at: event) {
            toggleCheckbox(at: c)
            return
        }
        if isPreview || event.modifierFlags.contains(.command), let url = link(at: event) {
            if let openLink { openLink(url) } else { NSWorkspace.shared.open(url) }
            return
        }
        super.mouseDown(with: event)
    }

    open override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if (isEditable && checkbox(at: event) != nil) ||
            ((isPreview || event.modifierFlags.contains(.command)) && link(at: event) != nil) {
            NSCursor.pointingHand.set()
        }
    }

    /// Toggles the task box whose `[` is at `index`.
    public func toggleCheckbox(at index: Int) {
        guard let ts = textStorage, index + 1 < ts.length else { return }
        let str = ts.string as NSString
        let r = NSRange(location: index + 1, length: 1)
        let current = str.substring(with: r)
        let replacement = current == " " ? "x" : " "
        replace(r, with: replacement, actionName: "Toggle Task")
    }

    /// Undoable replacement that keeps the selection where it was when possible.
    public func replace(_ range: NSRange, with string: String, actionName: String? = nil, select: NSRange? = nil) {
        guard let ts = textStorage else { return }
        let keep = selectedRanges
        guard shouldChangeText(in: range, replacementString: string) else { return }
        ts.replaceCharacters(in: range, with: string)
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
        if let select {
            setSelectedRange(select)
        } else {
            let delta = (string as NSString).length - range.length
            let adjusted = keep.map { v -> NSValue in
                var r = v.rangeValue
                if r.location >= NSMaxRange(range) { r.location += delta }
                r.location = min(r.location, ts.length)
                r.length = min(r.length, ts.length - r.location)
                return NSValue(range: r)
            }
            selectedRanges = adjusted
        }
    }
}
