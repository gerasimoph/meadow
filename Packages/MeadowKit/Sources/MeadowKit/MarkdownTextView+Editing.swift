import AppKit

/// The structural prefix of a Markdown line: indentation, quote markers, list marker, task box.
struct LinePrefix {
    var indent: String = ""
    var quote: String = ""
    /// `-`, `*`, `+`, or a number followed by `.` / `)`.
    var marker: String = ""
    var markerSpacing: String = ""
    var task: String = ""
    var hasMarker: Bool { !marker.isEmpty }
    var length: Int { (indent + quote + marker + markerSpacing + task as NSString).length }
    var isOrdered: Bool { marker.first?.isNumber ?? false }

    static func parse(_ line: String) -> LinePrefix {
        var p = LinePrefix()
        var s = Substring(line)
        func take(_ pred: (Character) -> Bool) -> String {
            let t = s.prefix(while: pred)
            s = s.dropFirst(t.count)
            return String(t)
        }
        p.indent = take { $0 == " " || $0 == "\t" }
        // Quote markers like "> " or ">> ".
        while s.first == ">" {
            p.quote += take { $0 == ">" }
            p.quote += take { $0 == " " }
        }
        if let c = s.first, "-*+".contains(c), s.dropFirst().first == " " {
            p.marker = String(c)
            s = s.dropFirst()
        } else {
            let digits = s.prefix(while: { $0.isNumber })
            if !digits.isEmpty, digits.count <= 9, let d = s.dropFirst(digits.count).first, d == "." || d == ")",
               s.dropFirst(digits.count + 1).first == " " {
                p.marker = String(digits) + String(d)
                s = s.dropFirst(digits.count + 1)
            }
        }
        if p.hasMarker {
            p.markerSpacing = take { $0 == " " }
            if s.count >= 3, s.first == "[", s.dropFirst(2).first == "]", let m = s.dropFirst().first, " xX".contains(m) {
                p.task = String(s.prefix(3))
                s = s.dropFirst(3)
                p.task += take { $0 == " " }
            }
        }
        return p
    }

    /// Prefix for the line that follows this one.
    func continuation() -> String {
        var marker = self.marker
        if isOrdered, let n = Int(marker.dropLast()) { marker = "\(n + 1)" + String(self.marker.last!) }
        let task = self.task.isEmpty ? "" : "[ ] "
        return indent + quote + marker + (marker.isEmpty ? "" : " ") + task
    }
}

extension MarkdownTextView {
    private var nsString: NSString { (textStorage?.string ?? "") as NSString }

    private func currentLineRange() -> NSRange {
        nsString.lineRange(for: NSRange(location: selectedRange().location, length: 0))
    }

    private func lineContentRange(_ r: NSRange) -> NSRange {
        var r = r
        let s = nsString
        while r.length > 0, s.character(at: NSMaxRange(r) - 1) == 10 || s.character(at: NSMaxRange(r) - 1) == 13 { r.length -= 1 }
        return r
    }

    private var caretIsInCode: Bool {
        if styler.sourceLanguage != nil { return true }
        let a = styler.analysis
        guard a.length == nsString.length, !a.lines.isEmpty else { return false }
        let kind = a.lines[a.lineIndex(at: selectedRange().location)].kind
        return kind == .code || kind == .fence
    }

    // MARK: Return / Tab / Backspace

    open override func insertNewline(_ sender: Any?) {
        guard isEditable, selectedRange().length == 0 else { return super.insertNewline(sender) }
        let lineRange = lineContentRange(currentLineRange())
        let line = nsString.substring(with: lineRange)
        let caret = selectedRange().location
        if caretIsInCode {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            insertText("\n" + indent, replacementRange: selectedRange())
            return
        }
        let prefix = LinePrefix.parse(line)
        guard prefix.hasMarker || !prefix.quote.isEmpty, caret >= lineRange.location + prefix.length else {
            return super.insertNewline(sender)
        }
        let content = line.dropFirst(prefix.indent.count + prefix.quote.count + prefix.marker.count
                                     + prefix.markerSpacing.count + prefix.task.count)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: end the list (or quote) instead of continuing it.
            let keep = prefix.hasMarker ? prefix.indent + prefix.quote : ""
            replace(lineRange, with: keep, actionName: "End List",
                    select: NSRange(location: lineRange.location + (keep as NSString).length, length: 0))
            return
        }
        insertText("\n" + prefix.continuation(), replacementRange: selectedRange())
    }

    open override func insertTab(_ sender: Any?) {
        guard isEditable, !caretIsInCode else { return super.insertTab(sender) }
        if shiftListLines(by: 1) { return }
        super.insertTab(sender)
    }

    open override func insertBacktab(_ sender: Any?) {
        guard isEditable, !caretIsInCode else { return super.insertBacktab(sender) }
        if shiftListLines(by: -1) { return }
        super.insertBacktab(sender)
    }

    /// Indents or outdents the list items in the selection. Returns false when there are none.
    private func shiftListLines(by direction: Int) -> Bool {
        let s = nsString
        let sel = selectedRange()
        let block = s.lineRange(for: sel)
        var lines: [NSRange] = []
        s.enumerateSubstrings(in: block, options: [.byLines, .substringNotRequired]) { _, r, _, _ in lines.append(r) }
        let prefixes = lines.map { LinePrefix.parse(s.substring(with: $0)) }
        guard prefixes.contains(where: \.hasMarker) else { return false }
        var result = ""
        for (i, r) in lines.enumerated() {
            let text = s.substring(with: r)
            let p = prefixes[i]
            var newText = text
            if p.hasMarker {
                let width = p.marker.count + 1
                if direction > 0 {
                    newText = p.quote.isEmpty ? String(repeating: " ", count: width) + text
                        : p.indent + p.quote + String(repeating: " ", count: width) + text.dropFirst(p.indent.count + p.quote.count)
                } else {
                    let afterQuote = text.dropFirst(p.indent.count + p.quote.count)
                    let source = p.quote.isEmpty ? Substring(text) : afterQuote
                    let spaces = source.prefix(while: { $0 == " " }).count
                    let remove = min(spaces, width)
                    let tail = source.dropFirst(remove)
                    newText = p.quote.isEmpty ? String(tail) : p.indent + p.quote + tail
                }
            }
            result += newText
            if i < lines.count - 1 {
                let gapStart = NSMaxRange(r)
                let gapEnd = lines[i + 1].location
                result += s.substring(with: NSRange(location: gapStart, length: gapEnd - gapStart))
            }
        }
        let target = NSRange(location: lines.first!.location, length: NSMaxRange(lines.last!) - lines.first!.location)
        let delta = (result as NSString).length - target.length
        let newSel = sel.length == 0
            ? NSRange(location: max(target.location, sel.location + (lines.count == 1 ? delta : 0)), length: 0)
            : NSRange(location: target.location, length: (result as NSString).length)
        replace(target, with: result, actionName: direction > 0 ? "Indent" : "Outdent", select: newSel)
        return true
    }

    open override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard isEditable, sel.length == 0, sel.location > 0, !caretIsInCode else { return super.deleteBackward(sender) }
        let lineRange = lineContentRange(currentLineRange())
        let line = nsString.substring(with: lineRange)
        let p = LinePrefix.parse(line)
        let contentStart = lineRange.location + p.length
        guard sel.location == contentStart, p.length > 0, p.hasMarker || !p.quote.isEmpty else {
            return super.deleteBackward(sender)
        }
        // Backspace right after a list marker or quote removes the marker, not one character.
        let markerStart: Int
        if p.hasMarker {
            markerStart = lineRange.location + (p.indent + p.quote as NSString).length
        } else {
            let trimmedQuote = p.quote.dropLast(p.quote.hasSuffix(" ") ? 2 : 1)
            markerStart = lineRange.location + (p.indent + trimmedQuote as NSString).length
        }
        let r = NSRange(location: markerStart, length: contentStart - markerStart)
        replace(r, with: "", actionName: "Delete", select: NSRange(location: markerStart, length: 0))
    }

    // MARK: Formatting commands

    private func wrap(_ marker: String, name: String) {
        let sel = selectedRange()
        let s = nsString
        let m = (marker as NSString).length
        // Unwrap if the selection is already surrounded by the marker.
        if sel.location >= m, NSMaxRange(sel) + m <= s.length,
           s.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           s.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: s.substring(with: sel), actionName: name,
                    select: NSRange(location: sel.location - m, length: sel.length))
            return
        }
        let inner = s.substring(with: sel)
        replace(sel, with: marker + inner + marker, actionName: name,
                select: NSRange(location: sel.location + m, length: sel.length))
    }

    @objc public func toggleBold(_ sender: Any?) { wrap("**", name: "Bold") }
    @objc public func toggleItalic(_ sender: Any?) { wrap("*", name: "Italic") }
    @objc public func toggleStrikethrough(_ sender: Any?) { wrap("~~", name: "Strikethrough") }
    @objc public func toggleInlineCode(_ sender: Any?) { wrap("`", name: "Code") }

    @objc public func insertLink(_ sender: Any?) {
        let sel = selectedRange()
        let text = nsString.substring(with: sel)
        let looksLikeURL = text.hasPrefix("http://") || text.hasPrefix("https://")
        let replacement = looksLikeURL ? "[](\(text))" : "[\(text)]()"
        let caret = looksLikeURL ? sel.location + 1 : sel.location + (text as NSString).length + 3
        replace(sel, with: replacement, actionName: "Link", select: NSRange(location: caret, length: 0))
    }

    /// Sender's `tag` is the heading level (0 removes the heading).
    @objc public func setHeadingLevel(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 1
        let lineRange = lineContentRange(currentLineRange())
        let line = nsString.substring(with: lineRange)
        let hashes = line.prefix(while: { $0 == "#" })
        var body = Substring(line.dropFirst(hashes.count))
        if !hashes.isEmpty { body = body.drop(while: { $0 == " " }) }
        let newLevel = hashes.count == level ? 0 : level
        let newLine = (newLevel > 0 ? String(repeating: "#", count: newLevel) + " " : "") + body
        let caretOffset = (newLine as NSString).length
        replace(lineRange, with: newLine, actionName: "Heading",
                select: NSRange(location: lineRange.location + caretOffset, length: 0))
    }

    /// Turns the current line into a task, toggles an existing task, or removes nothing else.
    @objc public func toggleTask(_ sender: Any?) {
        let lineRange = lineContentRange(currentLineRange())
        let line = nsString.substring(with: lineRange)
        let p = LinePrefix.parse(line)
        if !p.task.isEmpty {
            let boxStart = lineRange.location + (p.indent + p.quote + p.marker + p.markerSpacing as NSString).length
            toggleCheckbox(at: boxStart)
            return
        }
        let insertAt: Int
        let insertion: String
        if p.hasMarker {
            insertAt = lineRange.location + p.length
            insertion = "[ ] "
        } else {
            insertAt = lineRange.location + (p.indent + p.quote as NSString).length
            insertion = "- [ ] "
        }
        let caret = selectedRange().location
        replace(NSRange(location: insertAt, length: 0), with: insertion, actionName: "Task",
                select: NSRange(location: max(caret, insertAt) + (insertion as NSString).length, length: 0))
    }

    open override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleStrikethrough(_:)),
             #selector(toggleInlineCode(_:)), #selector(insertLink(_:)), #selector(setHeadingLevel(_:)),
             #selector(toggleTask(_:)):
            return isEditable && styler.sourceLanguage == nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
